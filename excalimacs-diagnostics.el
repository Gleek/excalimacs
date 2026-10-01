;;; excalimacs-diagnostics.el --- Excalimacs diagnostics and traffic logs -*- lexical-binding: t; -*-

;;; Commentary:
;; Display drawing sessions, server controls, and bounded HTTP traffic logs.
;; Loaded by excalimacs.el after its server and session definitions.

;;; Code:

(require 'cl-lib)
(require 'simple-httpd)
(require 'tabulated-list)
(require 'subr-x)

(defvar excalimacs--sessions)
(defvar excalimacs--owns-server)
(defvar excalimacs-allow-remote)
(declare-function excalimacs--remote-session-p "excalimacs" (session))
(declare-function excalimacs--remote-enabled-p "excalimacs" ())
(declare-function excalimacs--clear-drawing "excalimacs" (path))
(declare-function excalimacs--revoke-session "excalimacs" (token))
(declare-function excalimacs--start "excalimacs" (&optional network))
(declare-function excalimacs-stop "excalimacs" ())

(defcustom excalimacs-debug t
  "Log HTTP traffic and drawing bridge activity in diagnostics.
Logs contain request paths, status codes and byte counts, without tokens
or drawing contents.  Only the latest 300 entries are retained."
  :type 'boolean)

(defvar excalimacs--logs nil)
(defvar excalimacs--diagnostics-timer nil)
(defvar excalimacs--request nil)
(defvar excalimacs--remote-request-p nil)

(defun excalimacs--diagnostics-schedule-refresh ()
  "Refresh an open diagnostics buffer after pending events settle."
  (when (and (get-buffer "*Excalimacs Diagnostics*")
             (not excalimacs--diagnostics-timer))
    (setq excalimacs--diagnostics-timer
          (run-at-time
           0.2 nil
           (lambda ()
             (setq excalimacs--diagnostics-timer nil)
             (when-let* ((buffer (get-buffer "*Excalimacs Diagnostics*")))
               (with-current-buffer buffer
                 (excalimacs--diagnostics-refresh))))))))

(defun excalimacs--log (format-string &rest args)
  "Record a bounded diagnostic event using FORMAT-STRING and ARGS."
  (when excalimacs-debug
    (push (concat (format-time-string "%H:%M:%S ")
                  (when excalimacs--remote-request-p "[Remote] ")
                  (apply #'format format-string args)) excalimacs--logs)
    (when (> (length excalimacs--logs) 300)
      (setcdr (nthcdr 299 excalimacs--logs) nil))
    (excalimacs--diagnostics-schedule-refresh)))

(defun excalimacs--httpd-log (log item)
  "Capture simple-httpd ITEM safely while Excalimacs owns the server."
  (if (not excalimacs--owns-server)
      (funcall log item)
    (pcase (car item)
      ((or 'connection 'close 'start 'stop)
       (excalimacs--log "HTTP %s %s" (car item) (cadr item)))
      ((or 'error 'hard-error)
       ;; Error objects can contain request bodies, URLs or credentials.
       (excalimacs--log "HTTP error %s" (if (numberp (cadr item)) (cadr item) "internal"))))))

(defun excalimacs--log-response (send proc mime status &rest headers)
  "Log the status and byte count of a response sent by SEND."
  (let ((bytes (httpd--buffer-size))
        (request excalimacs--request))
    (prog1 (apply send proc mime status headers)
      (when request
        (excalimacs--log "HTTP -> %s %s | %s | %s bytes"
                        (caar request) (car (split-string (cadar request) "[?#]"))
                        status bytes)))))

(advice-add 'httpd--log :around #'excalimacs--httpd-log)
(advice-add 'httpd-send-header :around #'excalimacs--log-response)

(defun excalimacs--isolate-request (handle &rest args)
  "Run HANDLE with ARGS outside any pending HTTP response buffer.
Sending large assets can run another request's timer.  simple-httpd
otherwise reuses the interrupted response buffer, corrupting both replies."
  (if excalimacs--owns-server
      (let* ((excalimacs--request (cadr args))
             ;; Live edits arrive several times a second while drawing.
             (excalimacs-debug (and excalimacs-debug
                                    (not (equal (cadar excalimacs--request) "/api/broadcast"))))
             (body (cadr (assoc "Content" excalimacs--request)))
             (proc (car args))
             (host (and (processp proc) (car (process-contact proc))))
             (session (gethash (cadr (assoc "X-Editor-Token" excalimacs--request))
                               excalimacs--sessions))
             (origin (or (if (stringp session) "http://127.0.0.1:"
                           (plist-get session :origin))
                         (cadr (assoc "Origin" excalimacs--request))))
             (excalimacs--remote-request-p
              (if origin
                  (not (string-match-p
                        "\\`https?://\\(?:127\\.[0-9.]+\\|localhost\\|\\[::1\\]\\)\\(?::\\|/\\|\\'\\)"
                        origin))
                (and host (not (or (string-prefix-p "127." host)
                                  (member host '("::1" "localhost"))))))))
        (excalimacs--log "HTTP <- %s %s | %s | %s bytes"
                        (caar excalimacs--request)
                        (car (split-string (or (cadar excalimacs--request) "") "[?#]"))
                        (or host "internal")
                        (if (stringp body) (string-bytes body) 0))
        (with-temp-buffer (apply handle args)))
    (apply handle args)))

(advice-add 'httpd--handle-request :around #'excalimacs--isolate-request)

(define-derived-mode excalimacs-diagnostics-mode tabulated-list-mode "Excalimacs"
  "Inspect drawing sessions and control the Excalimacs server.
Press g to refresh or d to revoke the session at point."
  (setq tabulated-list-format [("Drawing" 28 t) ("Access" 14 t)
                               ("Sessions" 8 t) ("" 8 nil) ("Path" 0 t)]
        tabulated-list-use-header-line nil
        tabulated-list-padding 2
        tabulated-list-sort-key '("Drawing" . nil)
        revert-buffer-function #'excalimacs--diagnostics-refresh)
  (tabulated-list-init-header)
  (setq header-line-format '(:eval (excalimacs--diagnostics-header))))

(define-key excalimacs-diagnostics-mode-map (kbd "d") #'excalimacs-diagnostics-revoke)

(defun excalimacs--header-toggle (enabled command)
  "Make an ENABLED status clickable to run COMMAND in this buffer."
  (let ((map (make-mode-line-mouse-map 'mouse-1 command)))
    (define-key map [header-line mouse-1] (lookup-key map [mode-line mouse-1]))
    (propertize (if enabled "on" "off") 'face 'link 'mouse-face 'highlight
                'help-echo "mouse-1: toggle" 'local-map map)))

(defun excalimacs--diagnostics-header ()
  "Return clickable remote and server status for the header line."
  (list " Remote: "
        (excalimacs--header-toggle (excalimacs--remote-enabled-p)
                                  #'excalimacs-diagnostics-toggle-remote)
        ", Server: "
        (excalimacs--header-toggle (and excalimacs--owns-server (httpd-running-p))
                                  #'excalimacs-diagnostics-toggle-server)))

(defun excalimacs--diagnostics-refresh (&rest _ignored)
  "Refresh the drawings table and bounded traffic log."
  (setq tabulated-list-entries
        (let ((drawings (make-hash-table :test #'equal)) rows)
          (maphash
           (lambda (_token session)
             (let* ((path (if (stringp session) session (plist-get session :path)))
                    (counts (or (gethash path drawings) (cons 0 0))))
               (if (excalimacs--remote-session-p session)
                   (cl-incf (cdr counts)) (cl-incf (car counts)))
               (puthash path counts drawings)))
           excalimacs--sessions)
          (maphash
           (lambda (path counts)
             (push (list path
                         (vector (propertize
                                  (truncate-string-to-width (file-name-nondirectory path)
                                                            27 nil nil "...")
                                  'help-echo (file-name-nondirectory path))
                                 (cond ((zerop (car counts)) "Remote")
                                       ((zerop (cdr counts)) "Local")
                                       (t "Local + Remote"))
                                 (number-to-string (+ (car counts) (cdr counts)))
                                 (list "Clear" 'action #'excalimacs--diagnostics-clear-button
                                       'excalimacs-path path 'follow-link t)
                                 (abbreviate-file-name path))) rows))
           drawings)
          rows))
  (tabulated-list-print t)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert "\nLogs\n-------\n")
      (cond ((not excalimacs-debug) (insert "Logging disabled (excalimacs-debug).\n"))
            (excalimacs--logs (insert (mapconcat #'identity (reverse excalimacs--logs) "\n") "\n"))
            (t (insert "No activity recorded yet.\n")))
      (insert "\ng: refresh    d: clear drawing access    q: close\n")))
  (force-mode-line-update))

(defun excalimacs--diagnostics-clear-button (button)
  "Clear all sessions for the drawing identified by BUTTON."
  (excalimacs--clear-drawing (button-get button 'excalimacs-path))
  (excalimacs--diagnostics-refresh))

(defun excalimacs-diagnostics-toggle-server ()
  "Toggle the server, starting on loopback or stopping all sessions."
  (interactive)
  (if (and excalimacs--owns-server (httpd-running-p))
      (excalimacs-stop)
    (excalimacs--start))
  (excalimacs--diagnostics-refresh))

(defun excalimacs-diagnostics-toggle-remote ()
  "Toggle remote access, revoking remote sessions when disabling it.
Enabling permits subsequent QR or copy-url actions to start LAN listening."
  (interactive)
  (setq excalimacs-allow-remote (not (excalimacs--remote-enabled-p)))
  (unless excalimacs-allow-remote
    (let (tokens)
      (maphash (lambda (token session)
                 (when (excalimacs--remote-session-p session) (push token tokens)))
               excalimacs--sessions)
      (mapc #'excalimacs--revoke-session tokens)
      ;; Restrict an existing LAN listener even if no remote grants remain.
      (excalimacs--revoke-session nil)))
  (excalimacs--log "Remote access %s" (if excalimacs-allow-remote "enabled" "disabled"))
  (excalimacs--diagnostics-refresh))

(defun excalimacs-diagnostics-revoke ()
  "Clear all access to the drawing at point, keeping its file."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No drawing on this row"))
    (excalimacs--clear-drawing path)
    (excalimacs--diagnostics-refresh)))

;;;###autoload
(defun excalimacs-diagnostics ()
  "Show drawing sessions, paths, and server controls."
  (interactive)
  (require 'excalimacs)
  (with-current-buffer (get-buffer-create "*Excalimacs Diagnostics*")
    (excalimacs-diagnostics-mode)
    (excalimacs--diagnostics-refresh)
    (pop-to-buffer (current-buffer))))

(provide 'excalimacs-diagnostics)
;;; excalimacs-diagnostics.el ends here
