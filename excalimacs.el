;;; excalimacs.el --- Edit local Excalidraw files from Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1") (simple-httpd "1.7"))

;;; Commentary:
;; Edit Excalidraw drawings in Emacs with the bundled browser application.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'excalimacs-httpd)
(require 'subr-x)
(require 'url)
(require 'org-id)

(defvar url-http-response-status)

(defgroup excalimacs nil "Local Excalidraw editor." :group 'applications)

(defcustom excalimacs-plugins nil
  "Optional browser plugins to enable.  Reload editor tabs after changing this.
Currently available: `pens' (normal, highlighter, and thick-to-thin pens)."
  :type '(set (const pens)))

(defcustom excalimacs-dist-directory
  (expand-file-name "dist" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing the built browser application."
  :type 'directory)

(defcustom excalimacs-directory "~/org-excalidraw"
  "Directory or function used by `excalimacs-create-drawing'.
A function is called without arguments in the buffer creating the drawing
and must return a directory string.  Relative directories are resolved
against that buffer's `default-directory'."
  :type '(choice directory function))

(defcustom excalimacs-library-directory
  (expand-file-name "excalimacs" user-emacs-directory)
  "Directory containing Excalidraw library files."
  :type 'directory)

(defcustom excalimacs-library-file "library.excalidrawlib"
  "Name of the Excalidraw library file in `excalimacs-library-directory'."
  :type 'string)

(defcustom excalimacs-preview-width 320
  "Maximum width in pixels for Excalidraw previews in Org buffers."
  :type 'integer)

(defcustom excalimacs-delete-file 'ask
  "Whether deleting a displayed drawing permanently deletes its PNG file.
The value `ask' prompts before deleting; nil keeps the file."
  :type '(choice (const :tag "Ask" ask)
                 (const :tag "Delete automatically" t)
                 (const :tag "Keep file" nil)))

(defcustom excalimacs-open-action 'browser
  "Default action for opening drawings.
With a prefix argument, choose an action instead."
  :type '(choice (const browser) (const copy-url) (const qr-code)))

(defcustom excalimacs-allow-remote nil
  "Allow QR and copied URLs to enable LAN access.
The server still starts on loopback until a remote open action is used.
After changing this option on a running server, restart Excalimacs with
`excalimacs-stop' to apply the new policy."
  :type 'boolean)

(defcustom excalimacs-network-address nil
  "IPv4 address advertised by network open actions.
Nil selects a non-loopback, non-tunnel network interface automatically."
  :type '(choice (const :tag "Automatic" nil) string))

(defcustom excalimacs-agent-drawing-speed 500
  "Speed in pixels per second at which editor tabs draw agent edits.
Shapes grow from their corner and arrows extend along their path at this
speed, as if drawn with a mouse."
  :type 'number)

(defcustom excalimacs-agent-typing-speed 20
  "Characters per second at which editor tabs type agent labels and text."
  :type 'number)

(defcustom excalimacs-agent-drawing-limit 8
  "Maximum seconds to draw one agent operation.
Larger operations are drawn faster to fit.  The agent's command returns
when the drawing finishes, so this also bounds how long it waits."
  :type 'number)

(defvar excalimacs--sessions (make-hash-table :test #'equal))
(declare-function excalimacs--log-request "excalimacs-diagnostics" (handle &rest args))

(defvar excalimacs--server nil)
(defvar-local excalimacs--overlays nil)
(defvar-local excalimacs--refresh-timer nil)
(defvar excalimacs-minor-mode)
(defvar excalimacs-block-map)

(defcustom excalimacs-templates
  '((org-mode :begin "#+begin_excalimacs :file {file}" :end "#+end_excalimacs")
    (markdown-mode :begin "<!-- excalidraw: {file}" :end "-->")
    (agent-shell-mode :begin "@{file}" :text nil)
    (prog-mode :comment t)
    (default :begin "excalidraw: {file}" :end "end-excalidraw"))
  "Templates used to insert and find drawings in major modes.
Each entry is (MODE . PROPERTIES).  :begin contains one {file}
placeholder; :end is optional.  :text defaults to t and may be nil.
:comment uses the current buffer's comment syntax instead of strings.
More specific major modes take precedence over their parents."
  :type 'sexp)

(defconst excalimacs--empty-drawing
  "{\"type\":\"excalidraw\",\"version\":2,\"elements\":[],\"appState\":{\"viewBackgroundColor\":\"#ffffff\"},\"files\":{}}")

(defun excalimacs--token ()
  "Return a random token for one drawing session."
  (unless (file-readable-p "/dev/urandom")
    (error "Excalimacs needs /dev/urandom for session tokens"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally "/dev/urandom" nil nil 32)
    (mapconcat (lambda (byte) (format "%02x" byte)) (string-to-list (buffer-string)) "")))

(defun excalimacs--read (path)
  "Read UTF-8 text at PATH."
  (decode-coding-string (excalimacs--read-bytes path) 'utf-8))

(defun excalimacs--read-bytes (path)
  "Read PATH without decoding it."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun excalimacs--hash (text)
  "Hash UTF-8 TEXT like the browser editor."
  (secure-hash 'sha256 (encode-coding-string text 'utf-8)))

(defun excalimacs--hash-bytes (bytes)
  "Return the SHA-256 hash of unibyte BYTES."
  (secure-hash 'sha256 bytes))

(defvar excalimacs--hash-cache (make-hash-table :test #'equal))
(defvar excalimacs--sockets nil "Editor WebSockets as (PROCESS TOKEN TAB PATH).")
(defvar excalimacs--agent-queue (make-hash-table :test #'equal))
(defvar excalimacs--agent-results (make-hash-table :test #'equal))
(defvar excalimacs--agent-operations (make-hash-table :test #'equal)
  "Active agent operations as ID -> (PATH . STATE).
STATE is pending, running, or abandoned after a running command times out.")

(defun excalimacs--file-hash (path)
  "Return PATH's hash, or nil when it is missing, cached by mtime and size."
  (when-let* ((attributes (file-attributes path)))
    (let ((key (list (file-attribute-modification-time attributes)
                     (file-attribute-size attributes)))
          (cached (gethash path excalimacs--hash-cache)))
      (if (equal (car cached) key)
          (cdr cached)
        (cdr (puthash path (cons key (excalimacs--hash-bytes (excalimacs--read-bytes path)))
                      excalimacs--hash-cache))))))

(defun excalimacs--png-p (bytes)
  "Return non-nil when BYTES starts with the PNG signature."
  (and (stringp bytes)
       (string-prefix-p (unibyte-string 137 80 78 71 13 10 26 10) bytes)))

(defun excalimacs--valid-drawing-p (text)
  "Return non-nil when TEXT is a usable Excalidraw document."
  (condition-case nil
      (let ((drawing (json-parse-string text :object-type 'hash-table :array-type 'array)))
        (and (equal (gethash "type" drawing) "excalidraw")
             (vectorp (gethash "elements" drawing))
             (hash-table-p (gethash "appState" drawing))
             (hash-table-p (gethash "files" drawing))))
    (error nil)))

(defun excalimacs--library-path ()
  "Return the configured library path."
  (unless (and (string-suffix-p ".excalidrawlib" excalimacs-library-file)
               (equal excalimacs-library-file
                      (file-name-nondirectory excalimacs-library-file)))
    (error "Library file must be a .excalidrawlib filename"))
  (expand-file-name excalimacs-library-file excalimacs-library-directory))

(defun excalimacs--parse-library (text)
  "Parse TEXT as an Excalidraw library or signal an error."
  (let ((library (json-parse-string text :object-type 'hash-table)))
    (unless (and (equal (gethash "type" library) "excalidrawlib")
                 (vectorp (or (gethash "libraryItems" library)
                              (gethash "library" library))))
      (error "Invalid Excalidraw library"))
    library))

(defun excalimacs--valid-library-p (text)
  "Return non-nil if TEXT is an Excalidraw library."
  (condition-case nil
      (progn (excalimacs--parse-library text) t)
    (error nil)))

(defun excalimacs--library-files ()
  "Return the configured library files."
  (when (file-directory-p excalimacs-library-directory)
    (directory-files excalimacs-library-directory t "\\.excalidrawlib\\'")))

(defun excalimacs--file-library-items (file)
  "Return FILE's items in the current Excalidraw library format."
  (condition-case nil
    (let* ((library (excalimacs--parse-library (excalimacs--read file)))
           (items (or (gethash "libraryItems" library) (gethash "library" library))))
      (vconcat
       (cl-loop for item across items
                for index from 0
                collect (if (vectorp item)
                            (let ((converted (make-hash-table :test #'equal)))
                              (puthash "id" (secure-hash 'sha256
                                                          (format "%s:%s" file index)) converted)
                              (puthash "status" "published" converted)
                              (puthash "created" 0 converted)
                              (puthash "elements" item converted)
                              converted)
                          item))))
    (error (error "Invalid Excalidraw library: %s" file))))

(defun excalimacs--combined-library ()
  "Return all library items from the configured directory."
  (let ((items nil))
    (dolist (file (excalimacs--library-files))
      (setq items (append items (append (excalimacs--file-library-items file) nil))))
    (vconcat items)))

(defun excalimacs--download-library (address)
  "Download an Excalidraw library from ADDRESS and return its text."
  (unless (and (stringp address)
               (string-match-p
                "\\`https://libraries\\.excalidraw\\.com/libraries/[[:alnum:]_-]+/[[:alnum:]_.-]+\\.excalidrawlib\\'"
                address))
    (error "Invalid library URL"))
  (let ((buffer (url-retrieve-synchronously address t t 15)))
    (unless buffer (error "Library download failed"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (equal url-http-response-status 200)
            (error "Library download returned HTTP %s" url-http-response-status))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Invalid library response"))
          (decode-coding-string (buffer-substring-no-properties (point) (point-max)) 'utf-8))
      (kill-buffer buffer))))

(defun excalimacs--library-import-session (request)
  "Return the session authorized to import a library from REQUEST."
  (or (excalimacs--session-path request)
      (let ((library-token (cadr (assoc "X-Library-Token" request)))
            found)
        (when (stringp library-token)
          (maphash (lambda (token session)
                     (when (equal library-token
                                  (secure-hash 'sha256
                                               (concat "excalimacs-library:" token)))
                       (setq found session)))
                   excalimacs--sessions))
        found)))

(httpd-servlet api/library application/json (_path _query request)
  (let ((method (caar request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("GET" "POST" "PUT") t))
         ((equal method "GET")
          (let* ((path (excalimacs--library-path))
                 (contents (and (file-exists-p path) (excalimacs--read path)))
                 (library (json-parse-string
                           "{\"type\":\"excalidrawlib\",\"version\":2,\"libraryItems\":[]}"
                           :object-type 'hash-table)))
            (puthash "libraryItems" (excalimacs--combined-library) library)
            (excalimacs--json-reply
             200 `(("library" . ,library)
                   ("hash" . ,(if contents (excalimacs--hash contents) :null))))))
         ((equal method "POST")
          (let* ((data (excalimacs--request-json request))
                 (name (gethash "name" data))
                 (address (gethash "url" data))
                 (contents (if address (excalimacs--download-library address)
                             (gethash "text" data))))
            (when address
              (setq name (replace-regexp-in-string
                          "/" "-" (string-remove-prefix
                                   "/libraries/" (url-filename (url-generic-parse-url address))))))
            (unless (and (stringp name) (string-match-p "\\`[[:alnum:]_-]+\\.excalidrawlib\\'" name)
                         (not (equal name excalimacs-library-file))
                         (stringp contents) (excalimacs--valid-library-p contents))
              (error "Invalid library import"))
            (make-directory excalimacs-library-directory t)
            (excalimacs--atomic-write
             (expand-file-name name excalimacs-library-directory)
             (encode-coding-string contents 'utf-8))
            (excalimacs--json-reply 200 '(("ok" . t)))))
         (t
          (let* ((data (excalimacs--request-json request))
                 (base (gethash "baseHash" data))
                 (contents (gethash "text" data))
                 (path (excalimacs--library-path)))
            (when (eq base :null) (setq base nil))
            (unless (and (or (null base) (stringp base))
                         (stringp contents) (excalimacs--valid-library-p contents))
              (error "Invalid library save request"))
            (let ((previous (and (file-exists-p path) (excalimacs--read path)))
                  (imported (make-hash-table :test #'equal)))
              (unless (equal (and previous (excalimacs--hash previous)) base)
                (signal 'file-already-exists '("Library changed on disk")))
              (dolist (file (excalimacs--library-files))
                (unless (equal file path)
                  (dolist (item (append (excalimacs--file-library-items file) nil))
                    (puthash (gethash "id" item) t imported))))
              (when (> (hash-table-count imported) 0)
                (let* ((library (json-parse-string contents :object-type 'hash-table))
                       (items (gethash "libraryItems" library)))
                  (puthash "libraryItems"
                           (vconcat (cl-remove-if (lambda (item)
                                                    (gethash (gethash "id" item) imported))
                                                  (append items nil)))
                           library)
                  (setq contents (json-serialize library))))
              (make-directory (file-name-directory path) t)
              (unless (equal previous contents)
                (excalimacs--atomic-write path (encode-coding-string contents 'utf-8)))
              (excalimacs--json-reply 200 `(("hash" . ,(excalimacs--hash contents))))))))
      (file-already-exists
       (excalimacs--json-reply 409 `(("error" . ,(error-message-string err)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(defun excalimacs--atomic-write (path bytes)
  "Atomically replace PATH with unibyte BYTES."
  (let ((temporary (make-temp-file (concat path ".") nil ".tmp")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region bytes nil temporary nil 'silent))
          (when (file-exists-p path)
            (set-file-modes temporary (file-modes path)))
          (rename-file temporary path t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun excalimacs--save (path base-hash text)
  "Save TEXT to PATH when BASE-HASH still matches."
  (unless (excalimacs--valid-drawing-p text)
    (error "Invalid Excalidraw drawing"))
  (let ((previous (excalimacs--read path)))
    (unless (equal (excalimacs--hash previous) base-hash)
      (signal 'file-already-exists '("Drawing changed on disk")))
    (unless (equal previous text)
      (excalimacs--atomic-write path (encode-coding-string text 'utf-8)))
    (excalimacs--hash text)))

(defun excalimacs--write-png (path bytes base-hash)
  "Atomically write BYTES to PATH if BASE-HASH still matches.
BASE-HASH is nil only when creating a new file."
  (let ((previous (and (file-exists-p path) (excalimacs--read-bytes path))))
    (if previous
        (unless (equal (excalimacs--hash-bytes previous) base-hash)
          (signal 'file-already-exists '("Drawing changed on disk")))
      (when base-hash (signal 'file-already-exists '("Drawing was removed"))))
    (excalimacs--atomic-write path bytes)
    (excalimacs--hash-bytes bytes)))

(defun excalimacs--json-reply (status data)
  "Respond with JSON DATA and HTTP STATUS in a simple-httpd servlet."
  (let ((object (make-hash-table :test #'equal)))
    (dolist (entry data) (puthash (car entry) (cdr entry) object))
    (insert (json-serialize object)))
  (httpd-send-header t "application/json" status :Cache-Control "no-store"))

(defun excalimacs--request-json (request &optional limit list-arrays)
  "Parse REQUEST's UTF-8 JSON body, enforcing byte LIMIT when provided.
LIST-ARRAYS requests lists instead of vectors for JSON arrays."
  (let ((body (cadr (assoc "Content" request))))
    (when (and limit (> (string-bytes body) limit))
      (error "Request body too large"))
    (json-parse-string (decode-coding-string body 'utf-8)
                       :object-type 'hash-table
                       :array-type (if list-arrays 'list 'array))))

(defun excalimacs--reject-request (request methods &optional library-import)
  "Reply to an unauthorized REQUEST or a method outside METHODS.
Return non-nil if rejected.  LIBRARY-IMPORT permits scoped import tokens."
  (let* ((method (caar request))
         (session (if (and library-import (equal method "POST"))
                      (excalimacs--library-import-session request)
                    (excalimacs--session-path request)))
         (failure (cond ((not session) '(403 "Forbidden"))
                        ((not (member method methods)) '(405 "Method not allowed"))
                        ((and (not (equal method "GET"))
                              (not (excalimacs--allowed-origin-p request)))
                         '(403 "Forbidden")))))
    (when failure
      (excalimacs--json-reply (car failure) `(("error" . ,(cadr failure))))
      t)))

(defun excalimacs--revalidate-files (send proc mime status &rest headers)
  "Call SEND with PROC, MIME, STATUS and HEADERS, marking files no-cache.
Bundle names carry no content hash, so browsers must revalidate them."
  (apply send proc mime status
         (if (and (excalimacs--serving-p) (plist-member headers :ETag))
             (append headers '(:Cache-Control "no-cache"))
           headers)))

(advice-add 'httpd-send-header :around #'excalimacs--revalidate-files)

(defun excalimacs--session-path (request)
  "Return the drawing path authorized by REQUEST."
  (let ((session (gethash (cadr (assoc "X-Editor-Token" request))
                          excalimacs--sessions)))
    (if (stringp session) session (plist-get session :path))))

(defun excalimacs--allowed-origin-p (request)
  "Return non-nil if REQUEST uses an authorized server origin."
  (let ((origin (cadr (assoc "Origin" request)))
        (session (or (gethash (cadr (assoc "X-Editor-Token" request))
                             excalimacs--sessions)
                     (excalimacs--library-import-session request))))
    (or (not origin)
        (equal origin (if (stringp session)
                          (format "http://127.0.0.1:%s"
                                  (process-contact excalimacs--server :service))
                        (plist-get session :origin))))))

(httpd-servlet api/library-token application/json (_path _query request)
  (cond
   ((excalimacs--reject-request request '("GET")))
   (t
    (excalimacs--json-reply
     200 `(("token" . ,(secure-hash 'sha256
                                  (concat "excalimacs-library:"
                                          (cadr (assoc "X-Editor-Token" request))))))))))

(httpd-servlet api/plugins application/json (_path _query request)
  (condition-case err
      (let* ((path (expand-file-name "plugin-settings.json" excalimacs-library-directory))
             (method (caar request))
             (settings (if (file-exists-p path)
                           (json-parse-string (excalimacs--read path))
                         (make-hash-table :test #'equal))))
        (cond
         ((excalimacs--reject-request request '("GET" "PUT")))
         ((equal method "GET")
          (excalimacs--json-reply
           200 `(("plugins" . ,(vconcat (mapcar #'symbol-name excalimacs-plugins)))
                 ("settings" . ,settings))))
         (t
          (let* ((data (excalimacs--request-json request 16384))
                 (name (gethash "name" data))
                 (value (gethash "settings" data)))
            (unless (and (equal name "pens") (hash-table-p value))
              (error "Invalid plugin settings"))
            (puthash name value settings)
            (make-directory excalimacs-library-directory t)
            (excalimacs--atomic-write path (encode-coding-string (json-serialize settings) 'utf-8))
            (excalimacs--json-reply 200 '(("ok" . t)))))))
    (error (excalimacs--json-reply 400 `(("error" . ,(error-message-string err)))))))

(httpd-servlet api/drawing application/json (_path query request)
  (let ((path (excalimacs--session-path request))
        (method (caar request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("GET" "PUT")))
         ((and (equal method "GET") (assoc "hash" query))
          (excalimacs--json-reply 200 `(("hash" . ,(or (excalimacs--file-hash path) :null)))))
         ((equal method "GET")
          (cond
           ((not (file-exists-p path))
            (let ((drawing (json-parse-string excalimacs--empty-drawing)))
              (excalimacs--json-reply
               200 `(("drawing" . ,drawing) ("hash" . :null)
                     ("name" . ,(file-name-nondirectory path)) ("format" . "png")))))
           ((string-suffix-p ".png" path)
            (let ((bytes (excalimacs--read-bytes path)))
              (unless (excalimacs--png-p bytes) (error "Invalid PNG"))
              (insert bytes)
              (httpd-send-header t "image/png" 200 :Cache-Control "no-store"
                                 :X-Drawing-Hash (excalimacs--hash-bytes bytes)
                                 :X-Drawing-Name (file-name-nondirectory path))))
           (t
            (let ((text (excalimacs--read path)))
              (insert (format "{\"drawing\":%s,\"hash\":%s,\"name\":%s,\"format\":\"json\"}"
                              text (json-serialize (excalimacs--hash text))
                              (json-serialize (file-name-nondirectory path))))
              (httpd-send-header t "application/json" 200 :Cache-Control "no-store")))))
         ((string-suffix-p ".png" path)
          (let ((bytes (cadr (assoc "Content" request)))
                (base (cadr (assoc "X-Base-Hash" request))))
            (unless (excalimacs--png-p bytes) (error "Invalid PNG"))
            (let ((hash (excalimacs--write-png path bytes base)))
              (excalimacs--refresh-images path)
              (excalimacs--notify path)
              (excalimacs--json-reply 200 `(("hash" . ,hash))))))
         (t
          (let* ((data (excalimacs--request-json request))
                 (base (gethash "baseHash" data))
                 (text (gethash "text" data)))
            (unless (and (stringp base) (stringp text))
              (error "Invalid save request"))
            (let ((hash (excalimacs--save path base text)))
              (excalimacs--notify path)
              (excalimacs--json-reply 200 `(("hash" . ,hash)))))))
      (file-already-exists
       (excalimacs--json-reply 409 `(("error" . ,(error-message-string err)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(httpd-servlet api/open-in-app application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("POST")))
         (t
          (when (string-suffix-p ".png" path)
            (let* ((data (excalimacs--request-json request))
                   (text (gethash "text" data)))
              (unless text
                (error "Refresh the editor tab to load the updated app opener"))
              (unless (excalimacs--valid-drawing-p text)
                (error "Invalid drawing"))
              (setq path (make-temp-file "excalimacs-app-" nil ".excalidraw"))
              (excalimacs--atomic-write path text)))
          (let ((program (if (eq system-type 'darwin) "open" "xdg-open")))
            (unless (zerop (apply #'call-process program nil nil nil
                                 (if (eq system-type 'darwin)
                                     (list "-a" "Excalidraw" path)
                                   (list path))))
              (error "Could not open drawing with %s" program)))
          (excalimacs--json-reply 200 '(("opened" . t)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(httpd-servlet api/link application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (cond
     ((excalimacs--reject-request request '("GET")))
     (t (excalimacs--json-reply
         200 `(("link" . ,(concat "excalimacs:" (url-hexify-string path)))))))))

(httpd-servlet api/open-link application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("POST")))
         (t
          (let* ((data (excalimacs--request-json request))
                 (link (gethash "link" data)))
            (unless (and (stringp link) (not (string-empty-p link)))
              (error "Invalid link"))
            (setq link (string-trim link))
            ;; Link handlers need the user's buffer, not the HTTP response buffer.
            (with-current-buffer (window-buffer (selected-window))
              (let ((default-directory (file-name-directory path)))
                (org-link-open-from-string
                 (if (string-prefix-p "[[" link)
                     link
                   (concat "[[" (org-link-escape link) "]]"))))))
          (excalimacs--json-reply 200 '(("opened" . t)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(defun excalimacs--template ()
  "Return the template for the current major mode."
  (let ((entry (seq-find (lambda (item) (eq (car item) major-mode)) excalimacs-templates)))
    (unless entry
      (setq entry (or (seq-find (lambda (item)
                                  (and (not (eq (car item) 'default))
                                       (derived-mode-p (car item))))
                                excalimacs-templates)
                      (assq 'default excalimacs-templates))))
    (when entry
      (let ((template (cdr entry)))
        (if (plist-get template :comment)
            (let ((start (string-trim (or comment-start "")))
                  (end (string-trim (or comment-end ""))))
              (if (string-empty-p start)
                  (cdr (assq 'default excalimacs-templates))
                (list :begin (format "%s excalidraw: {file}%s" start
                                     (if (string-empty-p end) "" (concat " " end)))
                      :end (format "%s /excalidraw%s" start
                                   (if (string-empty-p end) "" (concat " " end)))
                      :text-prefix (concat start " ")
                      :text-suffix (if (string-empty-p end) "" (concat " " end))
                      :comment-end end)))
          template)))))

(defun excalimacs--text-p (template)
  "Return non-nil when TEMPLATE keeps searchable text between its lines."
  (and (plist-get template :end)
       (or (not (plist-member template :text))
           (plist-get template :text))))

(defun excalimacs--body (template lines)
  "Return LINES formatted as TEMPLATE's searchable text."
  (if (excalimacs--text-p template)
      (let ((prefix (or (plist-get template :text-prefix) ""))
            (suffix (or (plist-get template :text-suffix) ""))
            (closing (or (plist-get template :comment-end)
                         (and (equal (plist-get template :end) "-->") "-->"))))
        (mapconcat (lambda (line)
                     ;; Colon-prefixed lines are Org fixed-width text, which
                     ;; hides links from Org's parser and org-roam.
                     (when (derived-mode-p 'org-mode)
                       (setq line (string-remove-prefix ": " line))
                       (when (string-match-p "\\`[ \t]*\\(?:#\\+\\|\\*\\)" line)
                         (setq line (concat "," line))))
                     (when (and closing (> (length closing) 1))
                       (setq line (replace-regexp-in-string
                                   (regexp-quote closing)
                                   (concat (substring closing 0 -1) " " (substring closing -1))
                                   line t t)))
                     (when (equal (concat prefix line suffix) (plist-get template :end))
                       (setq line (concat "," line)))
                     (concat prefix line suffix "\n"))
                   (mapcan (lambda (line) (split-string line "\n")) lines) ""))
    ""))

(defun excalimacs--block-string (template path &optional lines)
  "Return TEMPLATE filled in for PATH with searchable LINES."
  (let ((begin (plist-get template :begin))
        (end (plist-get template :end)))
    (unless (string-match "{file}" begin)
      (error "Excalimacs template :begin needs {file}"))
    (concat (replace-match (prin1-to-string path) t t begin)
            (when end (concat "\n" (excalimacs--body template lines) end)))))

(defun excalimacs--block-lines (template begin end)
  "Return the searchable text lines of TEMPLATE's block from BEGIN to END."
  (when (excalimacs--text-p template)
    (let ((prefix (or (plist-get template :text-prefix) ""))
          (suffix (or (plist-get template :text-suffix) "")))
      (save-excursion
        (goto-char begin)
        (forward-line 1)
        (let ((body (point)))
          (goto-char end)
          (forward-line 0)
          (when (< body (point))
            (mapcar (lambda (line)
                      (string-remove-suffix suffix (string-remove-prefix prefix line)))
                    (split-string (buffer-substring-no-properties body (point)) "\n" t))))))))

(defun excalimacs--template-regexp (begin)
  "Return a regexp matching BEGIN's file placeholder."
  (unless (and (stringp begin) (string-match "{file}" begin))
    (error "Excalimacs template :begin needs {file}"))
  (concat (regexp-quote (substring begin 0 (match-beginning 0)))
          "\\(\"\\(?:\\\\.\\|[^\"\\\\]\\)*\"\\|[^[:space:]]+\\)"
          (regexp-quote (substring begin (match-end 0)))))

(defun excalimacs--blocks (&optional wanted-path)
  "Find drawing templates in this buffer, optionally for WANTED-PATH."
  (when-let* ((template (excalimacs--template))
              (begin (plist-get template :begin)))
    (let ((regexp (excalimacs--template-regexp begin))
          (end-line (plist-get template :end))
          blocks)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (let* ((start (match-beginning 0))
                 (inline-end (match-end 0))
                 (literal (match-string-no-properties 1))
                 (path (condition-case nil
                           (let ((value (if (string-prefix-p "\"" literal)
                                            (car (read-from-string literal))
                                          literal)))
                             (and (stringp value)
                                  (expand-file-name value
                                                    (or (and buffer-file-name
                                                             (file-name-directory buffer-file-name))
                                                        default-directory))))
                         (error nil)))
                 (end (if end-line
                          (and (re-search-forward (concat "^" (regexp-quote end-line) "$") nil t)
                               (line-end-position))
                        inline-end)))
            (when (and path end
                       (string-suffix-p ".excalidraw.png" path)
                       (or (not wanted-path)
                           (equal (file-truename path) (file-truename wanted-path))))
              (push (list start end path) blocks))))
      (nreverse blocks)))))

(defun excalimacs-refresh (&optional path)
  "Display drawing templates, optionally refreshing only PATH."
  (interactive)
  (when path (setq path (file-truename path)))
  (setq excalimacs--overlays
        (seq-filter
         (lambda (overlay)
           (if (or (not path)
                   (equal (file-truename (overlay-get overlay 'excalimacs-path)) path))
               (progn (delete-overlay overlay) nil)
             t))
         excalimacs--overlays))
  (when excalimacs-minor-mode
    (dolist (block (excalimacs--blocks path))
      (pcase-let ((`(,begin ,end ,file) block))
        (when (file-readable-p file)
          (clear-image-cache file)
          (let ((overlay (make-overlay begin end nil t nil)))
            (overlay-put overlay 'display
                         (create-image file nil nil :width excalimacs-preview-width))
            (overlay-put overlay 'excalimacs-path file)
            (overlay-put overlay 'excalimacs-inline
                         (not (plist-get (excalimacs--template) :end)))
            (overlay-put overlay 'read-only 'excalimacs)
            (overlay-put overlay 'mouse-face 'highlight)
            (overlay-put overlay 'help-echo "RET or mouse-1: edit drawing")
            (overlay-put overlay 'keymap excalimacs-block-map)
            (push overlay excalimacs--overlays)))))))

(defalias 'excalimacs-org-refresh #'excalimacs-refresh)

(defun excalimacs--refresh-images (&optional path)
  "Refresh PATH's displayed drawings in open buffers, or all when nil."
  (when path (setq path (file-truename path)))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p excalimacs-minor-mode)
        (excalimacs-refresh path)))))

(defun excalimacs--refresh-after-change (begin end _old-length)
  "Display inserted drawings and restore overlays displaced by edits."
  (when (and excalimacs-minor-mode
             (not excalimacs--refresh-timer)
             (or (seq-some (lambda (overlay)
                             (or (not (overlay-buffer overlay))
                                 (<= (overlay-end overlay) (overlay-start overlay))))
                           excalimacs--overlays)
                 (when-let* ((template (excalimacs--template))
                             (opening (plist-get template :begin)))
                   (save-match-data
                     (save-excursion
                       (goto-char begin)
                       (re-search-forward (excalimacs--template-regexp opening) end t))))))
    (setq excalimacs--refresh-timer
          (run-at-time 0 nil
                       (lambda (buffer)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq excalimacs--refresh-timer nil)
                             (when excalimacs-minor-mode
                               (excalimacs-refresh)))))
                       (current-buffer)))))

(defun excalimacs-open-at-point (&optional event)
  "Open the displayed drawing at point."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (when event (mouse-set-point event))
  (let ((overlay (excalimacs--drawing-at (point))))
    (unless overlay (user-error "No Excalidraw drawing at point"))
    (excalimacs-open
     (overlay-get overlay 'excalimacs-path)
     (when current-prefix-arg
       (intern (completing-read "Open action: "
                                '("browser" "copy-url" "qr-code") nil t))))))

(defun excalimacs--drawing-at (position)
  "Return the drawing overlay covering POSITION, if any."
  (seq-find (lambda (overlay) (overlay-get overlay 'excalimacs-path))
            (overlays-at position)))

(defun excalimacs--drawing-before-point ()
  "Return the displayed drawing directly before point."
  (or (excalimacs--drawing-at (point))
      (seq-find (lambda (overlay) (equal (overlay-end overlay) (point)))
                excalimacs--overlays)
      (and (> (point) (point-min))
           (eq (char-before) ?\n)
           (seq-find (lambda (overlay) (equal (overlay-end overlay) (1- (point))))
                     excalimacs--overlays))))

(defun excalimacs-delete-backward ()
  "Delete the displayed drawing before point."
  (interactive)
  (excalimacs--delete-drawing (excalimacs--drawing-before-point)))

(defun excalimacs-delete-forward ()
  "Delete the displayed drawing at point."
  (interactive)
  (excalimacs--delete-drawing (excalimacs--drawing-at (point))))

(defun excalimacs--delete-drawing (overlay)
  "Delete the block represented by OVERLAY and optionally its PNG."
  (unless overlay (user-error "No Excalidraw drawing at point"))
  (let* ((file (overlay-get overlay 'excalimacs-path))
         (begin (overlay-start overlay))
         (end (overlay-end overlay))
         (delete-file-p (and (file-exists-p file)
                             (pcase excalimacs-delete-file
                               ('ask (y-or-n-p (format "Permanently delete drawing file %s? " file)))
                               ('nil nil)
                               (_ t)))))
    (let ((inhibit-read-only '(excalimacs)))
      (delete-region begin (if (and (not (overlay-get overlay 'excalimacs-inline))
                                    (eq (char-after end) ?\n))
                               (1+ end)
                             end)))
    (when delete-file-p (delete-file file))
    (excalimacs-refresh)))

(defvar excalimacs-block-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'excalimacs-open-at-point)
    (define-key map [mouse-1] #'excalimacs-open-at-point)
    (define-key map (kbd "DEL") #'excalimacs-delete-backward)
    (define-key map (kbd "<backspace>") #'excalimacs-delete-backward)
    (define-key map (kbd "<delete>") #'excalimacs-delete-forward)
    (define-key map (kbd "C-d") #'excalimacs-delete-forward)
    map))

(defvar excalimacs-minor-mode-map (make-sparse-keymap))
;; Keep the map object on reload: enabled buffers already refer to it.
(setcdr excalimacs-minor-mode-map nil)
(dolist (key '("DEL" "<backspace>"))
  (define-key excalimacs-minor-mode-map (kbd key)
    '(menu-item "Excalimacs delete" excalimacs-delete-backward
                :filter (lambda (command)
                          (when (excalimacs--drawing-before-point) command)))))
(dolist (key '("<delete>" "C-d"))
  (define-key excalimacs-minor-mode-map (kbd key)
    '(menu-item "Excalimacs delete" excalimacs-delete-forward
                :filter (lambda (command)
                          (when (excalimacs--drawing-at (point)) command)))))

(defun excalimacs--filter-buffer-substring (orig begin end &optional delete)
  "Call ORIG on BEGIN, END and DELETE, tagging copied drawings with their path."
  (let* ((from (min begin end))
         (to (max begin end))
         (template (excalimacs--template))
         (drawings
          (delq nil
                (mapcar (lambda (overlay)
                          (let ((start (overlay-start overlay))
                                (stop (overlay-end overlay)))
                            (when (and (overlay-get overlay 'excalimacs-path)
                                       (<= from start) (<= stop to))
                              (list (- start from) (- stop from)
                                    (cons (overlay-get overlay 'excalimacs-path)
                                          (excalimacs--block-lines template start stop))))))
                        (overlays-in from to))))
         (string (funcall orig begin end delete)))
    ;; Another filter may have changed the text, which would shift offsets.
    (when (= (length string) (- to from))
      (pcase-dolist (`(,start ,stop ,drawing) drawings)
        (put-text-property start stop 'excalimacs-drawing drawing string)))
    string))

(defun excalimacs--yank-transform (string)
  "Rewrite drawings copied from any Excalimacs buffer in STRING for this buffer."
  (let ((template (excalimacs--template))
        (position 0)
        parts)
    (if (not (and template (text-property-not-all 0 (length string)
                                                  'excalimacs-drawing nil string)))
        string
      (while (< position (length string))
        (let ((next (next-single-property-change position 'excalimacs-drawing
                                                 string (length string)))
              (drawing (get-text-property position 'excalimacs-drawing string)))
          (push (if (not drawing)
                    (substring string position next)
                  ;; Block templates only match when they own their lines.
                  (let ((multiline (plist-get template :end)))
                    (concat (when (and multiline (> position 0)
                                       (/= (aref string (1- position)) ?\n))
                              "\n")
                            (excalimacs--block-string template (car drawing) (cdr drawing))
                            (when (and multiline (< next (length string))
                                       (/= (aref string next) ?\n))
                              "\n"))))
                parts)
          (setq position next)))
      (apply #'concat (nreverse parts)))))

;;;###autoload
(define-minor-mode excalimacs-minor-mode
  "Display drawing templates as images in the current buffer."
  :lighter " Excali"
  (if excalimacs-minor-mode
      (progn
        (add-hook 'after-save-hook #'excalimacs-refresh nil t)
        (add-hook 'after-change-functions #'excalimacs--refresh-after-change nil t)
        (add-hook 'yank-transform-functions #'excalimacs--yank-transform nil t)
        (add-function :around (local 'filter-buffer-substring-function)
                      #'excalimacs--filter-buffer-substring)
        (excalimacs-refresh))
    (remove-hook 'after-save-hook #'excalimacs-refresh t)
    (remove-hook 'after-change-functions #'excalimacs--refresh-after-change t)
    (remove-hook 'yank-transform-functions #'excalimacs--yank-transform t)
    (remove-function (local 'filter-buffer-substring-function)
                     #'excalimacs--filter-buffer-substring)
    (when excalimacs--refresh-timer
      (cancel-timer excalimacs--refresh-timer)
      (setq excalimacs--refresh-timer nil))
    (excalimacs-refresh)))

(defun excalimacs--replace-block-text (path lines)
  "Replace searchable text in open templates for PATH with LINES without saving."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((template (excalimacs--template))
                  ((excalimacs--text-p template))
                  (blocks (reverse (excalimacs--blocks path))))
        (let ((body (excalimacs--body template lines)) changed)
          (dolist (block blocks)
            (pcase-let ((`(,begin ,end ,_file) block))
              (let ((inhibit-read-only '(excalimacs)))
                (save-excursion
                  (goto-char begin)
                  (forward-line 1)
                  (let ((body-begin (point)))
                    (goto-char end)
                    (forward-line 0)
                    (unless (equal body (buffer-substring-no-properties body-begin (point)))
                      (delete-region body-begin (point))
                      (goto-char body-begin)
                      (insert body)
                      (setq changed t)))))))
          (when (and changed (bound-and-true-p excalimacs-minor-mode))
            (excalimacs-refresh (file-truename path))))))))

(httpd-servlet api/text application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("POST")))
         (t
          (let* ((data (excalimacs--request-json request nil t))
                 (hash (gethash "hash" data))
                 (lines (gethash "lines" data)))
            (unless (and (file-exists-p path)
                         (equal hash (excalimacs--hash-bytes (excalimacs--read-bytes path))))
              (signal 'file-already-exists '("Drawing changed before text arrived")))
            (unless (and (listp lines) (cl-every #'stringp lines))
              (error "Invalid text projection"))
            (excalimacs--replace-block-text path lines)
            (excalimacs--json-reply 200 '(("updated" . t))))))
      (file-already-exists
       (excalimacs--json-reply 409 `(("error" . ,(error-message-string err)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(httpd-servlet api/preview application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("POST")))
         ((not (equal (cadr (assoc "X-Drawing-Hash" request))
                      (excalimacs--hash (excalimacs--read path))))
          (excalimacs--json-reply 409 '(("error" . "Drawing changed before preview arrived"))))
         (t
          (let ((png (cadr (assoc "Content" request))))
            (unless (excalimacs--png-p png)
              (error "Invalid PNG"))
            (excalimacs--atomic-write (concat path ".png") png)
            (excalimacs--refresh-images (concat path ".png"))
            (excalimacs--json-reply 200 '(("updated" . t))))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(httpd-servlet api/agent application/json (_path _query request)
  (condition-case err
      (cond
       ((excalimacs--reject-request request '("POST")))
       (t
        (let* ((data (excalimacs--request-json request))
               (id (gethash "id" data))
               (operation (gethash id excalimacs--agent-operations)))
          (unless (stringp id) (error "Invalid agent result"))
          (cond
           ((and operation (not (equal (car operation) (excalimacs--session-path request))))
            (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
           ((eq (gethash "start" data) t)
            ;; Claim immediately before execution, including work already sent to a tab.
            (let ((run (eq (cdr operation) 'pending)))
              (when run (setcdr operation 'running))
              (excalimacs--json-reply 200 `(("run" . ,(if run t :false))))))
           ((memq (cdr operation) '(running abandoned))
            (when (eq (cdr operation) 'running)
              (puthash id (json-serialize data) excalimacs--agent-results))
            (remhash id excalimacs--agent-operations)
            (excalimacs--json-reply 200 '(("ok" . t))))
           (t (excalimacs--json-reply 409 '(("error" . "Operation is no longer active"))))))))
    (error
     (excalimacs--json-reply 400 `(("error" . ,(error-message-string err)))))))

(defun excalimacs--socket-send (process text)
  "Send TEXT to WebSocket PROCESS as one unmasked text frame.
Return non-nil on success; a socket that fails is closed."
  (let* ((bytes (encode-coding-string text 'utf-8))
         (size (length bytes)))
    (condition-case nil
        (progn
          (process-send-string
           process
           (concat (unibyte-string #x81)
                   (cond ((< size 126) (unibyte-string size))
                         ((< size 65536) (unibyte-string 126 (ash size -8) (logand size 255)))
                         (t (apply #'unibyte-string 127
                                   (mapcar (lambda (shift) (logand (ash size (- shift)) 255))
                                           '(56 48 40 32 24 16 8 0)))))
                   bytes))
          t)
      (error (delete-process process) nil))))

(defun excalimacs--live-sockets (path)
  "Return open editor sockets for PATH, oldest first."
  (setq excalimacs--sockets
        (seq-filter (lambda (socket) (process-live-p (car socket))) excalimacs--sockets))
  (reverse (seq-filter (lambda (socket) (equal (nth 3 socket) path)) excalimacs--sockets)))

(defun excalimacs--notify (path)
  "Tell every editor of PATH to fetch the latest drawing."
  (dolist (socket (excalimacs--live-sockets path))
    (excalimacs--socket-send (car socket) "{\"changed\":true}")))

(defun excalimacs--flush-agent-queue (path)
  "Send queued agent operations for PATH to its oldest open editor."
  ;; One tab runs all operations so agents read what they wrote.
  (when-let* ((socket (car (excalimacs--live-sockets path)))
              (ops (gethash path excalimacs--agent-queue)))
    (when (excalimacs--socket-send (car socket) (json-serialize `((ops . ,(vconcat ops)))))
      (remhash path excalimacs--agent-queue))))

(defun httpd/api/events (proc _path query request)
  "Upgrade PROC to a WebSocket that pushes drawing changes for REQUEST's token."
  (let* ((token (cadr (assoc "token" query)))
         (tab (cadr (assoc "tab" query)))
         (session (gethash token excalimacs--sessions))
         (path (if (stringp session) session (plist-get session :path)))
         (key (cadr (assoc "Sec-Websocket-Key" request))))
    (if (not (and path key
                  (excalimacs--allowed-origin-p (cons (list "X-Editor-Token" token) request))))
        (httpd-error proc 403)
      ;; The server only pushes, so client frames such as close are ignored.
      (set-process-filter proc #'ignore)
      (set-process-coding-system proc 'binary 'binary)
      (process-send-string
       proc (format "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"
                    (base64-encode-string
                     (secure-hash 'sha1 (concat key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                                  nil nil t))))
      (push (list proc token tab path) excalimacs--sockets)
      (excalimacs--flush-agent-queue path))))

(httpd-servlet api/broadcast application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((excalimacs--reject-request request '("POST")))
         (t
          (let* ((text (decode-coding-string (cadr (assoc "Content" request)) 'utf-8))
                 (data (json-parse-string text)))
            (unless (and (vectorp (gethash "elements" data)) (stringp (gethash "tab" data)))
              (error "Invalid broadcast"))
            ;; Live edits skip the PNG round trip; the editing tab still saves them.
            (dolist (socket (excalimacs--live-sockets path))
              (unless (equal (nth 2 socket) (gethash "tab" data))
                (excalimacs--socket-send (car socket) text)))
            (excalimacs--json-reply 200 '(("ok" . t))))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(defun excalimacs-agent-submit (request-file &optional immediate)
  "Queue the agent operation in REQUEST-FILE and return its id.
The file holds the operation on line 1, the drawing path on line 2 and
the payload after that.  Opens the drawing when no editor is connected.
IMMEDIATE applies the edit without drawing it gradually."
  (pcase-let* ((`(,op ,path . ,payload)
                (split-string (excalimacs--read request-file) "\n"))
               (path (file-truename path))
               (id (substring (excalimacs--token) 0 16)))
    (unless (member op '("add" "mermaid" "update" "delete" "scene"))
      (user-error "Unknown agent operation: %s" op))
    ;; Open first, so an invalid drawing leaves nothing queued to run later.
    (unless (excalimacs--live-sockets path)
      (excalimacs-open path))
    (puthash id (cons path 'pending) excalimacs--agent-operations)
    (puthash path (append (gethash path excalimacs--agent-queue)
                          (list `((id . ,id) (op . ,op)
                                  (presentation
                                   . ,(if immediate :null
                                        `((pixelsPerSecond . ,excalimacs-agent-drawing-speed)
                                          (charactersPerSecond . ,excalimacs-agent-typing-speed)
                                          (limit . ,excalimacs-agent-drawing-limit))))
                                  (payload . ,(string-join payload "\n")))))
             excalimacs--agent-queue)
    (excalimacs--flush-agent-queue path)
    id))

(defun excalimacs-agent-result (id output-file)
  "Write the result of agent operation ID to OUTPUT-FILE once it is ready.
Return nil while pending, otherwise `ok', `conflict' or `error'."
  (when-let* ((result (gethash id excalimacs--agent-results)))
    (remhash id excalimacs--agent-results)
    (excalimacs--atomic-write output-file (encode-coding-string result 'utf-8))
    (let ((data (json-parse-string result)))
      (cond ((gethash "current" data) 'conflict)
            ((gethash "error" data) 'error)
            (t 'ok)))))

(defun excalimacs-agent-cancel (id)
  "Cancel pending ID, including work dispatched to a browser queue.
Return `cancelled', `running' or `finished'.  Running edits cannot be undone
by cancellation; discard their eventual reply when the caller has timed out."
  (let ((operation (gethash id excalimacs--agent-operations)))
    (cond
     ((gethash id excalimacs--agent-results) 'finished)
     ((memq (cdr operation) '(running abandoned))
      (setcdr operation 'abandoned)
      'running)
     (t
      (remhash id excalimacs--agent-operations)
      (when operation
        (let ((path (car operation)))
          (puthash path (seq-remove (lambda (op) (equal (alist-get 'id op) id))
                                   (gethash path excalimacs--agent-queue))
                   excalimacs--agent-queue)))
      'cancelled))))

(defun excalimacs--server-running-p ()
  "Return non-nil if the Excalimacs listener is running."
  (and excalimacs--server (process-live-p excalimacs--server)))

(defun excalimacs--serving-p ()
  "Return non-nil inside a callback for the Excalimacs listener."
  (and excalimacs--server
       (eq excalimacs-httpd-current-server excalimacs--server)))

(defun excalimacs--stop-listener ()
  "Stop only the Excalimacs listener and its client connections."
  (excalimacs-httpd-stop excalimacs--server)
  (setq excalimacs--server nil))

(defun excalimacs--start-listener (host)
  "Listen on HOST, preserving the port and drawing sessions when restarting."
  (let ((port (if (excalimacs--server-running-p)
                  (process-contact excalimacs--server :service) 0)))
    (excalimacs--stop-listener)
    (setq excalimacs--server
          (excalimacs-httpd-start excalimacs-dist-directory :host host :port port
                                 :handler #'excalimacs--log-request)))
  (excalimacs--log "Server listening on %s:%s" host
                   (process-contact excalimacs--server :service))
  (excalimacs--diagnostics-schedule-refresh))

(defun excalimacs--start (&optional network)
  "Start the HTTP server, allowing LAN connections when NETWORK is non-nil."
  (when (and network (not excalimacs-allow-remote))
    (user-error "Enable excalimacs-allow-remote to use remote open actions"))
  (unless (file-exists-p (expand-file-name "index.html" excalimacs-dist-directory))
    (error "Build Excalimacs first: npm run build"))
  (unless (excalimacs--server-running-p)
    (excalimacs--start-listener (if network "0.0.0.0" "127.0.0.1")))
  (when (and network (equal (process-contact excalimacs--server :host) "127.0.0.1"))
    (excalimacs--start-listener "0.0.0.0"))
  (process-contact excalimacs--server :service))

(defun excalimacs--network-address ()
  "Return the configured or detected LAN IPv4 address."
  (or excalimacs-network-address
      (cl-loop for (name . address) in (network-interface-list)
               when (and (= (length address) 5)
                         (not (string-match-p "\\`\\(?:lo\\|utun\\|tun\\|docker\\|veth\\)" name))
                         (not (memq (aref address 0) '(0 127 169))))
               return (mapconcat #'number-to-string (seq-take address 4) "."))
      (user-error "Set excalimacs-network-address to your computer's LAN IPv4 address")))

(defun excalimacs--remote-session-p (session)
  "Return non-nil if SESSION grants access through a remote URL."
  (and (listp session) (plist-get session :origin)
       (not (string-prefix-p "http://127.0.0.1:" (plist-get session :origin)))))

(defun excalimacs--remote-enabled-p ()
  "Return non-nil if remote access is permitted or already listening."
  (or excalimacs-allow-remote
      (and (excalimacs--server-running-p)
           (equal (process-contact excalimacs--server :host) "0.0.0.0"))))

(defun excalimacs--clear-drawing (path)
  "Revoke every session for drawing PATH, keeping the file."
  (let (tokens)
    (maphash (lambda (token session)
               (when (equal path (if (stringp session) session (plist-get session :path)))
                 (push token tokens))) excalimacs--sessions)
    (mapc #'excalimacs--revoke-session tokens)))

(defun excalimacs--revoke-session (token)
  "Revoke TOKEN and restrict the server when no remote sessions remain."
  (when-let* ((session (gethash token excalimacs--sessions)))
    (excalimacs--log "Drawing access cleared: %s"
                    (if (stringp session) session (plist-get session :path))))
  (remhash token excalimacs--sessions)
  (dolist (socket excalimacs--sockets)
    (when (equal (nth 1 socket) token) (delete-process (car socket))))
  (excalimacs--diagnostics-schedule-refresh)
  (when (and (excalimacs--server-running-p)
             (equal (process-contact excalimacs--server :host) "0.0.0.0")
             (not (cl-loop for session being the hash-values of excalimacs--sessions
                           thereis (excalimacs--remote-session-p session))))
    (excalimacs--start-listener "127.0.0.1")))

(defun excalimacs--show-qr (url token)
  "Display URL as a QR code, with a button to revoke TOKEN."
  (unless (executable-find "qrencode")
    (user-error "Install qrencode to display QR codes"))
  (let ((png (with-temp-buffer
               (set-buffer-multibyte nil)
               (unless (zerop (call-process "qrencode" nil t nil
                                           "-t" "PNG" "-s" "8" "-o" "-" url))
                 (error "Could not generate QR code"))
               (buffer-string)))
        (buffer (get-buffer-create (format "*Excalimacs QR %s*" (substring token 0 8)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Scan to edit this drawing on your device.\n\n")
        (insert-image (create-image png 'png t))
        (insert "\n\n" url "\n\nKeep this URL private. Access lasts until revoked or the server stops.\n\n")
        (insert-text-button
         "Revoke access" 'action
         (lambda (_button)
           (excalimacs--revoke-session token)
           (message "Drawing access revoked")))
        (special-mode)))
    (pop-to-buffer buffer)))

;;;###autoload
(defun excalimacs--follow-link (link _arg)
  "Open an Org LINK to a drawing, optionally focused on an element or group."
  (unless (string-match "\\`\\([^#]+\\)\\(?:#\\(element\\|group\\)=\\([^#&]+\\)\\)?\\'" link)
    (user-error "Invalid Excalimacs link: %s" link))
  (let ((path (match-string 1 link))
        (target (when (match-string 2 link)
                  (concat (match-string 2 link) "=" (match-string 3 link)))))
    (excalimacs-open (decode-coding-string (url-unhex-string path) 'utf-8)
                    'browser target)))

;;;###autoload
(org-link-set-parameters "excalimacs" :follow #'excalimacs--follow-link)

;;;###autoload
(defun excalimacs-open (path &optional action target)
  "Open drawing PATH using ACTION or `excalimacs-open-action'.
With a prefix argument, choose browser, copy-url, or qr-code.
TARGET, when non-nil, is an element=ID or group=ID viewport target."
  (interactive (list (read-file-name "Drawing: ")
                     (when current-prefix-arg
                       (intern (completing-read "Open action: "
                                                '("browser" "copy-url" "qr-code") nil t)))))
  (setq path (file-truename path))
  (unless (or (and (string-suffix-p ".excalidraw" path)
                   (file-exists-p path)
                   (excalimacs--valid-drawing-p (excalimacs--read path)))
              (and (string-suffix-p ".excalidraw.png" path)
                   (or (not (file-exists-p path))
                       (excalimacs--png-p (excalimacs--read-bytes path)))))
    (user-error "Not a valid Excalidraw drawing: %s" path))
  (let* ((action (or action excalimacs-open-action))
         (network (memq action '(copy-url qr-code)))
         (address (if network (excalimacs--network-address) "127.0.0.1")))
    (unless (memq action '(browser copy-url qr-code))
      (user-error "Unknown open action: %s" action))
    (when (and network (not excalimacs-allow-remote))
      (user-error "Enable excalimacs-allow-remote to use remote open actions"))
    (when (and (eq action 'qr-code) (not (executable-find "qrencode")))
      (user-error "Install qrencode to display QR codes"))
    (let* ((port (excalimacs--start network))
           (token (excalimacs--token))
           (origin (format "http://%s:%s" address port))
           (url (concat (format "%s/?token=%s" origin token)
                        (when target (concat "#" target)))))
      (puthash token (list :path path :origin origin) excalimacs--sessions)
      (excalimacs--log "Drawing opened (%s): %s" action path)
      (excalimacs--diagnostics-schedule-refresh)
      (condition-case err
          (pcase action
            ('browser (browse-url url))
            ('copy-url (kill-new url) (message "Drawing URL copied"))
            ('qr-code (excalimacs--show-qr url token)))
        (error (excalimacs--revoke-session token)
               (signal (car err) (cdr err))))
      url)))

;;;###autoload
(defun excalimacs-create-drawing (name)
  "Insert the current mode's template for NAME and open its drawing."
  (interactive (list (read-string "Drawing name: ")))
  (let* ((template (or (excalimacs--template)
                       (user-error "No Excalimacs template for %s" major-mode)))
         (name (string-trim name))
         (filename (cond ((string-empty-p name) (concat (org-id-uuid) ".excalidraw.png"))
                         ((string-suffix-p ".excalidraw.png" name) name)
                         (t (concat (file-name-sans-extension name) ".excalidraw.png"))))
         (directory (if (functionp excalimacs-directory)
                        (funcall excalimacs-directory)
                      excalimacs-directory))
         (path (progn
                 (unless (stringp directory)
                   (user-error "Excalimacs directory must be a string, got: %S" directory))
                 (setq directory (expand-file-name directory))
                 (expand-file-name filename directory))))
    (unless (and (equal filename (file-name-nondirectory filename))
                 (not (member name '("." ".."))))
      (user-error "Drawing name must be a filename"))
    (make-directory directory t)
    (when (file-exists-p path) (user-error "Drawing already exists: %s" path))
    (insert (excalimacs--block-string template path))
    (when (bound-and-true-p excalimacs-minor-mode) (excalimacs-refresh))
    (excalimacs-open path)))

;;;###autoload
(defun excalimacs-stop ()
  "Stop the Excalimacs server and forget its drawing sessions."
  (interactive)
  (excalimacs--stop-listener)
  (clrhash excalimacs--sessions)
  (clrhash excalimacs--agent-queue)
  (clrhash excalimacs--agent-operations)
  (clrhash excalimacs--agent-results)
  (excalimacs--log "Server stopped; all drawing access cleared")
  (excalimacs--diagnostics-schedule-refresh))

(require 'excalimacs-diagnostics)

(provide 'excalimacs)
;;; excalimacs.el ends here
