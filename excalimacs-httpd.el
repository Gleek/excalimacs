;;; excalimacs-httpd.el --- Independent simple-httpd listeners -*- lexical-binding: t; -*-

;;; Commentary:
;; Run multiple simple-httpd sites without replacing its global listener.
;; Each returned server process owns its document root and client connections.
;; Servlets remain shared, as in simple-httpd.

;;; Code:

(require 'cl-lib)
(require 'simple-httpd)

(defvar excalimacs-httpd-current-server nil
  "Listener handling the current callback, or nil for ordinary simple-httpd.")
(defvar excalimacs-httpd--settings nil)

(cl-defun excalimacs-httpd-start (root &key (host "127.0.0.1") (port 0) handler)
	  "Serve ROOT on HOST and PORT without changing the global simple-httpd site.
Return the listener process.  PORT zero chooses an available port.
Directory listings are disabled.  Optional HANDLER wraps request handling:
it receives the original handler followed by the client and request."
	  (let ((httpd--server nil) (httpd--clients nil)
		(httpd-host host) (httpd-port port) (httpd-ip-family 'ipv4)
		(httpd-log-buffer nil) (httpd-start-hook nil) (httpd-stop-hook nil))
	    (httpd-start)
	    (process-put httpd--server 'excalimacs-httpd-root root)
	    (process-put httpd--server 'excalimacs-httpd-handler handler)
	    httpd--server))

(defun excalimacs-httpd-stop (server)
  "Stop SERVER and its clients without affecting other listeners."
  (when (and server (process-live-p server))
    (let ((httpd--server server)
          (httpd--clients (process-get server 'excalimacs-httpd-clients))
          (httpd-stop-hook nil)
          (excalimacs-httpd-current-server server))
      (httpd-stop))))

(defun excalimacs-httpd--accept (accept server proc message)
  "Call ACCEPT for client PROC of SERVER with connection MESSAGE."
  (if (not (process-get server 'excalimacs-httpd-root))
      (let ((excalimacs-httpd-current-server nil))
        (funcall accept server proc message))
    (process-put proc 'excalimacs-httpd-server server)
    (let ((httpd--clients (process-get server 'excalimacs-httpd-clients))
          (excalimacs-httpd-current-server server))
      (funcall accept server proc message)
      (process-put server 'excalimacs-httpd-clients httpd--clients))
    (set-process-sentinel proc #'excalimacs-httpd--sentinel)))

(defun excalimacs-httpd--sentinel (proc message)
  "Clean up client PROC after MESSAGE using its listener's client list."
  (let* ((server (process-get proc 'excalimacs-httpd-server))
         (httpd--clients (process-get server 'excalimacs-httpd-clients))
         (excalimacs-httpd-current-server server))
    (httpd--sentinel proc message)
    (process-put server 'excalimacs-httpd-clients httpd--clients)))

(defun excalimacs-httpd--handle-request (handle &rest args)
  "Call HANDLE with ARGS in the client's site and a fresh response buffer.
Sending a response can run another request's timer.  Preserve the original
site settings so ordinary simple-httpd requests can also nest safely."
  (let* ((server (and (processp (car args))
                      (process-get (car args) 'excalimacs-httpd-server)))
         (excalimacs-httpd--settings
          (if excalimacs-httpd-current-server
              excalimacs-httpd--settings
            (cons httpd-root httpd-listings)))
         (httpd-root (if server (process-get server 'excalimacs-httpd-root)
                       (car excalimacs-httpd--settings)))
         (httpd-listings (and (not server) (cdr excalimacs-httpd--settings)))
         (excalimacs-httpd-current-server server)
         (handler (and server (process-get server 'excalimacs-httpd-handler))))
    (with-temp-buffer
      (if handler (apply handler handle args) (apply handle args)))))

(advice-add 'httpd--accept :around #'excalimacs-httpd--accept)
(advice-add 'httpd--handle-request :around #'excalimacs-httpd--handle-request)

(provide 'excalimacs-httpd)
;;; excalimacs-httpd.el ends here
