;;; excalimacs.el --- Edit local Excalidraw files from Org -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.1") (simple-httpd "1.7"))

;;; Commentary:
;; Edit Excalidraw drawings in Org with the bundled browser application.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'simple-httpd)
(require 'subr-x)
(require 'url)
(require 'org-id)
(require 'ol)

(defgroup excalimacs nil "Local Excalidraw editor for Org." :group 'org)

(defcustom excalimacs-dist-directory
  (expand-file-name "dist" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing the built browser application."
  :type 'directory)

(defcustom excalimacs-directory "~/org-excalidraw"
  "Directory used by `excalimacs-create-drawing'."
  :type 'directory)

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
  "Whether deleting a displayed drawing also deletes its PNG file.
The value `ask' prompts before deleting; nil keeps the file."
  :type '(choice (const :tag "Ask" ask)
                 (const :tag "Delete automatically" t)
                 (const :tag "Keep file" nil)))

(defvar excalimacs--sessions (make-hash-table :test #'equal))
(defvar excalimacs--owns-server nil)
(defvar-local excalimacs--org-overlays nil)
(defvar excalimacs-org-block-map)

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
  (let* ((method (caar request))
         (session (if (equal method "POST")
                      (excalimacs--library-import-session request)
                    (excalimacs--session-path request))))
    (condition-case err
        (cond
         ((not session) (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
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
          (unless (excalimacs--allowed-origin-p request) (error "Forbidden"))
          (let* ((data (json-parse-string
                        (decode-coding-string (cadr (assoc "Content" request)) 'utf-8)
                        :object-type 'hash-table))
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
         ((not (equal method "PUT"))
          (excalimacs--json-reply 405 '(("error" . "Method not allowed"))))
         ((not (excalimacs--allowed-origin-p request))
          (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         (t
          (let* ((data (json-parse-string
                        (decode-coding-string (cadr (assoc "Content" request)) 'utf-8)
                        :object-type 'hash-table))
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

(defun excalimacs--session-path (request)
  "Return the drawing path authorized by REQUEST."
  (let ((session (gethash (cadr (assoc "X-Editor-Token" request))
                          excalimacs--sessions)))
    (if (stringp session) session (plist-get session :path))))

(defun excalimacs--allowed-origin-p (request)
  "Return non-nil if REQUEST came from this local server."
  (let ((origin (cadr (assoc "Origin" request)))
        (port (process-contact httpd--server :service)))
    (or (not origin) (equal origin (format "http://127.0.0.1:%s" port)))))

(httpd-servlet api/drawing application/json (_path _query request)
  (let ((path (excalimacs--session-path request))
        (method (caar request)))
    (condition-case err
        (cond
         ((not path) (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
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
         ((not (equal method "PUT"))
          (excalimacs--json-reply 405 '(("error" . "Method not allowed"))))
         ((not (excalimacs--allowed-origin-p request))
          (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         ((string-suffix-p ".png" path)
          (let ((bytes (cadr (assoc "Content" request)))
                (base (cadr (assoc "X-Base-Hash" request))))
            (unless (excalimacs--png-p bytes) (error "Invalid PNG"))
            (let ((hash (excalimacs--write-png path bytes base)))
              (excalimacs--refresh-org-images path)
              (excalimacs--json-reply 200 `(("hash" . ,hash))))))
         (t
          (let* ((data (json-parse-string (decode-coding-string
                                          (cadr (assoc "Content" request)) 'utf-8)
                                          :object-type 'hash-table))
                 (base (gethash "baseHash" data))
                 (text (gethash "text" data)))
            (unless (and (stringp base) (stringp text))
              (error "Invalid save request"))
            (excalimacs--json-reply 200 `(("hash" . ,(excalimacs--save path base text)))))))
      (file-already-exists
       (excalimacs--json-reply 409 `(("error" . ,(error-message-string err)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(httpd-servlet api/open-in-app application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((not path) (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         ((not (equal (caar request) "POST"))
          (excalimacs--json-reply 405 '(("error" . "Method not allowed"))))
         ((not (excalimacs--allowed-origin-p request))
          (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         (t
          (let ((program (if (eq system-type 'darwin) "open" "xdg-open")))
            (unless (zerop (call-process program nil nil nil path))
              (error "Could not open drawing with %s" program)))
          (excalimacs--json-reply 200 '(("opened" . t)))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(defun excalimacs--refresh-org-images (&optional path)
  "Refresh inline images and Excalimacs blocks in open Org buffers.
When PATH is non-nil, refresh blocks referring to that drawing."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (when (bound-and-true-p excalimacs-minor-mode)
          (excalimacs-org-refresh path))
        (org-display-inline-images t t)))))

(defun excalimacs--block-path (parameters)
  "Resolve the :file value in block PARAMETERS."
  (when (string-match "\\(?:^\\|[[:space:]]\\):file[[:space:]]+\\(\"[^\"]+\"\\|[^[:space:]]+\\)" parameters)
    (let ((value (match-string 1 parameters)))
      (when (and (> (length value) 1) (eq (aref value 0) ?\"))
        (setq value (car (read-from-string value))))
      (expand-file-name value (or (and buffer-file-name (file-name-directory buffer-file-name))
                                  default-directory)))))

(defun excalimacs--org-blocks (&optional wanted-path)
  "Return Excalimacs blocks in the current buffer.
If WANTED-PATH is non-nil, only return blocks referring to it."
  (let (blocks)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \\t]*#\\+begin_excalidraw\\(.*\\)$" nil t)
        (let* ((begin (line-beginning-position))
               (path (excalimacs--block-path (match-string-no-properties 1))))
          (when (re-search-forward "^[ \\t]*#\\+end_excalidraw[ \\t]*$" nil t)
            ;; Keep the terminating newline visible so the image does not
            ;; share a display line with the following heading or block.
            (let ((end (line-end-position)))
              (when (and path (or (not wanted-path)
                                  (equal (file-truename path) (file-truename wanted-path))))
                (push (list begin end path) blocks)))))))
    (nreverse blocks)))

(defun excalimacs-org-refresh (&optional path)
  "Display Excalidraw blocks as their PNG images.
When PATH is non-nil, it is accepted for targeted refresh callers."
  (interactive)
  (ignore path)
  (mapc #'delete-overlay excalimacs--org-overlays)
  (setq excalimacs--org-overlays nil)
  (dolist (block (excalimacs--org-blocks))
    (pcase-let ((`(,begin ,end ,file) block))
      (when (file-readable-p file)
        (clear-image-cache file)
        (let ((overlay (make-overlay begin end nil t nil)))
          (overlay-put overlay 'display
                       (create-image file nil nil :width excalimacs-preview-width))
          (overlay-put overlay 'excalimacs-path file)
          (overlay-put overlay 'mouse-face 'highlight)
          (overlay-put overlay 'help-echo "RET or mouse-1: edit drawing")
          (overlay-put overlay 'keymap excalimacs-org-block-map)
          (push overlay excalimacs--org-overlays))))))

(defun excalimacs-org-open-at-point (&optional event)
  "Open the Excalidraw block at point."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (when event (mouse-set-point event))
  (let ((path (seq-some (lambda (overlay) (overlay-get overlay 'excalimacs-path))
                        (overlays-at (point)))))
    (unless path (user-error "No Excalidraw block at point"))
    (excalimacs-open path)))

(defun excalimacs--drawing-at (position)
  "Return the drawing overlay covering POSITION, if any."
  (seq-find (lambda (overlay) (overlay-get overlay 'excalimacs-path))
            (overlays-at position)))

(defun excalimacs-org-delete-backward ()
  "Delete the displayed drawing before point as one character."
  (interactive)
  (let ((overlay (or (excalimacs--drawing-at (point))
                     (and (> (point) (point-min))
                          (excalimacs--drawing-at (1- (point))))
                     (and (> (point) (1+ (point-min)))
                          (eq (char-before (point)) ?\n)
                          (excalimacs--drawing-at (- (point) 2))))))
    (if overlay
        (excalimacs--delete-drawing overlay)
      (call-interactively #'org-delete-backward-char))))

(defun excalimacs-org-delete-forward ()
  "Delete the displayed drawing at point as one character."
  (interactive)
  (let ((overlay (excalimacs--drawing-at (point))))
    (if overlay
        (excalimacs--delete-drawing overlay)
      (call-interactively #'delete-char))))

(defun excalimacs--delete-drawing (overlay)
  "Delete the block represented by OVERLAY and optionally its PNG."
  (let* ((file (overlay-get overlay 'excalimacs-path))
         (begin (overlay-start overlay))
         (end (overlay-end overlay))
         (delete-file-p (and (file-exists-p file)
                             (pcase excalimacs-delete-file
                               ('ask (y-or-n-p (format "Delete drawing file %s? " file)))
                               ('nil nil)
                               (_ t)))))
    (delete-region begin (if (eq (char-after end) ?\n) (1+ end) end))
    (when delete-file-p (delete-file file))
    (excalimacs-org-refresh)))

(defvar excalimacs-org-block-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'excalimacs-org-open-at-point)
    (define-key map [mouse-1] #'excalimacs-org-open-at-point)
    (define-key map (kbd "DEL") #'excalimacs-org-delete-backward)
    (define-key map (kbd "<backspace>") #'excalimacs-org-delete-backward)
    (define-key map (kbd "<delete>") #'excalimacs-org-delete-forward)
    (define-key map (kbd "C-d") #'excalimacs-org-delete-forward)
    map))

(defvar excalimacs-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "DEL") #'excalimacs-org-delete-backward)
    (define-key map (kbd "<backspace>") #'excalimacs-org-delete-backward)
    (define-key map (kbd "<delete>") #'excalimacs-org-delete-forward)
    (define-key map (kbd "C-d") #'excalimacs-org-delete-forward)
    map))

;;;###autoload
(define-minor-mode excalimacs-minor-mode
  "Render Excalidraw blocks and open their PNG links in Excalimacs."
  :lighter " Excali"
  (if excalimacs-minor-mode
      (progn
        (cl-pushnew '("\\.excalidraw\\.png\\'" . excalimacs--open-preview)
                    org-file-apps :test #'equal)
        (add-hook 'after-save-hook #'excalimacs-org-refresh nil t)
        (excalimacs-org-refresh))
    (remove-hook 'after-save-hook #'excalimacs-org-refresh t)
    (mapc #'delete-overlay excalimacs--org-overlays)
    (setq excalimacs--org-overlays nil)))

(defun excalimacs--replace-block-text (path lines)
  "Replace searchable text in open Org blocks for PATH with LINES."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (let ((blocks (reverse (excalimacs--org-blocks path)))
              (was-modified (buffer-modified-p)))
          (dolist (block blocks)
            (pcase-let ((`(,begin ,end ,_file) block))
              (save-excursion
                (goto-char begin)
                (forward-line 1)
                (let ((body-begin (point)))
                  (goto-char end)
                  (re-search-backward "^[ \\t]*#\\+end_excalidraw")
                  (delete-region body-begin (line-beginning-position))
                  (goto-char body-begin)
                  (insert (mapconcat #'identity lines "\n"))
                  (unless (null lines) (insert "\n"))))))
          (when (bound-and-true-p excalimacs-minor-mode)
            (excalimacs-org-refresh))
          (when (and blocks (not was-modified) buffer-file-name
                     (file-exists-p buffer-file-name))
            (save-buffer)))))))

(httpd-servlet api/text application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((not path) (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         ((not (equal (caar request) "POST"))
          (excalimacs--json-reply 405 '(("error" . "Method not allowed"))))
         ((not (excalimacs--allowed-origin-p request))
          (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         (t
          (let* ((data (json-parse-string (decode-coding-string
                                          (cadr (assoc "Content" request)) 'utf-8)
                                          :object-type 'hash-table :array-type 'list))
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

(defun excalimacs--open-preview (path _link)
  "Open Excalidraw PNG PATH, or its legacy JSON source."
  (excalimacs-open
   (if (file-exists-p (string-remove-suffix ".png" path))
       (string-remove-suffix ".png" path)
     path)))

(httpd-servlet api/preview application/json (_path _query request)
  (let ((path (excalimacs--session-path request)))
    (condition-case err
        (cond
         ((not path) (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         ((not (equal (caar request) "POST"))
          (excalimacs--json-reply 405 '(("error" . "Method not allowed"))))
         ((not (excalimacs--allowed-origin-p request))
          (excalimacs--json-reply 403 '(("error" . "Forbidden"))))
         ((not (equal (cadr (assoc "X-Drawing-Hash" request))
                      (excalimacs--hash (excalimacs--read path))))
          (excalimacs--json-reply 409 '(("error" . "Drawing changed before preview arrived"))))
         (t
          (let ((png (cadr (assoc "Content" request))))
            (unless (excalimacs--png-p png)
              (error "Invalid PNG"))
            (excalimacs--atomic-write (concat path ".png") png)
            (excalimacs--refresh-org-images (concat path ".png"))
            (excalimacs--json-reply 200 '(("updated" . t))))))
      (error
       (excalimacs--json-reply 400 `(("error" . ,(error-message-string err))))))))

(defun excalimacs--isolate-request (handle &rest args)
  "Run HANDLE with ARGS outside any pending HTTP response buffer.
Sending large assets can run another request's timer.  simple-httpd
otherwise reuses the interrupted response buffer, corrupting both replies."
  (if excalimacs--owns-server
      (with-temp-buffer (apply handle args))
    (apply handle args)))

(advice-add 'httpd--handle-request :around #'excalimacs--isolate-request)

(defun excalimacs--start ()
  "Start a local Emacs HTTP server for Excalimacs."
  (unless (file-exists-p (expand-file-name "index.html" excalimacs-dist-directory))
    (error "Build Excalimacs first: npm run build"))
  (if (httpd-running-p)
      (unless (and excalimacs--owns-server
                   (equal httpd-host "127.0.0.1")
                   (equal (file-truename httpd-root)
                          (file-truename excalimacs-dist-directory)))
        (error "simple-httpd is already serving another site"))
    (setq httpd-host "127.0.0.1"
          httpd-port 0
          httpd-root excalimacs-dist-directory
          httpd-listings nil)
    (httpd-start)
    (setq excalimacs--owns-server t))
  (process-contact httpd--server :service))

;;;###autoload
(defun excalimacs-open (path)
  "Open Excalidraw file PATH in a private browser session."
  (interactive "fDrawing: ")
  (setq path (file-truename path))
  (unless (or (and (string-suffix-p ".excalidraw" path)
                   (file-exists-p path)
                   (excalimacs--valid-drawing-p (excalimacs--read path)))
              (and (string-suffix-p ".excalidraw.png" path)
                   (or (not (file-exists-p path))
                       (excalimacs--png-p (excalimacs--read-bytes path)))))
    (user-error "Not a valid Excalidraw drawing: %s" path))
  (let* ((port (excalimacs--start))
         (token (excalimacs--token))
         (url (format "http://127.0.0.1:%s/?token=%s" port token)))
    (puthash token path excalimacs--sessions)
    (browse-url url)
    url))

;;;###autoload
(defun excalimacs-create-drawing (name)
  "Insert a searchable Org block for NAME and open its PNG drawing."
  (interactive (list (read-string "Drawing name: ")))
  (unless (derived-mode-p 'org-mode)
    (user-error "Create drawings from an Org buffer"))
  (let* ((name (string-trim name))
         (filename (cond ((string-empty-p name) (concat (org-id-uuid) ".excalidraw.png"))
                         ((string-suffix-p ".excalidraw.png" name) name)
                         (t (concat (file-name-sans-extension name) ".excalidraw.png"))))
         (path (expand-file-name filename excalimacs-directory)))
    (unless (and (equal filename (file-name-nondirectory filename))
                 (not (member name '("." ".."))))
      (user-error "Drawing name must be a filename"))
    (make-directory excalimacs-directory t)
    (when (file-exists-p path) (user-error "Drawing already exists: %s" path))
    (insert (format "#+begin_excalidraw :file %S\n#+end_excalidraw" path))
    (when (bound-and-true-p excalimacs-minor-mode) (excalimacs-org-refresh))
    (excalimacs-open path)))

;;;###autoload
(defun excalimacs-stop ()
  "Stop the Excalimacs server and forget its drawing sessions."
  (interactive)
  (when (and excalimacs--owns-server (httpd-running-p))
    (httpd-stop))
  (setq excalimacs--owns-server nil)
  (clrhash excalimacs--sessions))

(provide 'excalimacs)
;;; excalimacs.el ends here
