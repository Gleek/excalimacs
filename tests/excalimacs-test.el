;;; excalimacs-test.el --- File safety tests for Excalimacs -*- lexical-binding: t; -*-

(require 'ert)
(require 'excalimacs)

(ert-deftest excalimacs-library-saves-and-rejects-stale-writes ()
  (let* ((directory (make-temp-file "excalimacs-library-" t))
         (excalimacs-library-directory directory)
         (excalimacs--sessions (make-hash-table :test #'equal))
         (path (excalimacs--library-path))
         (text "{\"type\":\"excalidrawlib\",\"version\":2,\"libraryItems\":[]}")
         status)
    (unwind-protect
        (progn
          (puthash "test" "/tmp/drawing.excalidraw" excalimacs--sessions)
          (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) t))
                    ((symbol-function 'httpd-send-header)
                     (lambda (_proc _mime code &rest _headers)
                       (setq status code httpd--header-sent t))))
            (httpd/api/library nil "/api/library" nil
                               '(("GET" "/api/library" "HTTP/1.1")
                                 ("X-Editor-Token" "test")))
            (should (= status 200))
            (should-not (file-exists-p path))
            (let ((body (json-serialize `((baseHash . :null) (text . ,text)))))
              (httpd/api/library nil "/api/library" nil
                                 `(("PUT" "/api/library" "HTTP/1.1")
                                   ("X-Editor-Token" "test") ("Content" ,body)))
              (should (= status 200))
              (should (equal (excalimacs--read path) text))
              (httpd/api/library nil "/api/library" nil
                                 `(("PUT" "/api/library" "HTTP/1.1")
                                   ("X-Editor-Token" "test") ("Content" ,body)))
              (should (= status 409)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-library-import-follows-directory ()
  (let* ((directory (make-temp-file "excalimacs-library-" t))
         (excalimacs-library-directory directory)
         (excalimacs--sessions (make-hash-table :test #'equal))
         (text "{\"type\":\"excalidrawlib\",\"version\":2,\"libraryItems\":[{\"id\":\"test\",\"elements\":[]}]}")
         (path (expand-file-name "author-shapes.excalidrawlib" directory))
         status)
    (unwind-protect
        (progn
          (puthash "test" "/tmp/drawing.excalidraw" excalimacs--sessions)
          (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) t))
                    ((symbol-function 'httpd-send-header)
                     (lambda (_proc _mime code &rest _headers)
                       (setq status code httpd--header-sent t))))
            (let ((body (json-serialize `((name . "author-shapes.excalidrawlib")
                                          (text . ,text)))))
              (httpd/api/library nil "/api/library" nil
                                 `(("POST" "/api/library" "HTTP/1.1")
                                   ("X-Editor-Token" "test")
                                   ("Content" ,body))))
            (should (= status 200))
            (should (equal (excalimacs--read path) text))
            (should (= (length (excalimacs--combined-library)) 1))
            (delete-file path)
            (should (= (length (excalimacs--combined-library)) 0))
            (cl-letf (((symbol-function 'excalimacs--download-library)
                       (lambda (_) text)))
              (let ((body (json-serialize
                           '((url . "https://libraries.excalidraw.com/libraries/author/shapes.excalidrawlib")))))
                (httpd/api/library nil "/api/library" nil
                                   `(("POST" "/api/library" "HTTP/1.1")
                                     ("X-Library-Token" ,(secure-hash 'sha256 "excalimacs-library:test"))
                                     ("Content" ,body)))))
            (should (= status 200))
            (should (file-exists-p path))
            (let ((legacy "{\"type\":\"excalidrawlib\",\"version\":1,\"library\":[[{\"type\":\"rectangle\",\"id\":\"box\"}]]}"))
              (should (excalimacs--valid-library-p legacy))
              (with-temp-file path (insert legacy))
              (let ((item (aref (excalimacs--combined-library) 0)))
                (should (equal (gethash "status" item) "published"))
                (should (equal (gethash "type" (aref (gethash "elements" item) 0))
                               "rectangle"))))))
      (delete-directory directory t))))

(ert-deftest excalimacs-overlapping-responses-have-separate-buffers ()
  (let ((excalimacs--owns-server t))
    (httpd--ensure-buffer
      (insert "outer response")
      (setq httpd--header-sent t)
      (let ((outer (current-buffer)))
        (excalimacs--isolate-request
         (lambda ()
           (httpd--ensure-buffer
             (should-not (eq outer (current-buffer)))
             (should-not httpd--header-sent)
             (should (equal (buffer-string) ""))
             (insert "inner response")
             (setq httpd--header-sent t))))
        (should (equal (buffer-string) "outer response"))
        (should httpd--header-sent)))))

(ert-deftest excalimacs-open-in-app-uses-authorized-session ()
  (let ((excalimacs--sessions (make-hash-table :test #'equal))
        (path "/tmp/drawing with spaces.excalidraw")
        (allowed t)
        (exit-status 0)
        status calls)
    (puthash "test" path excalimacs--sessions)
    (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) allowed))
              ((symbol-function 'call-process)
               (lambda (&rest args) (push args calls) exit-status))
              ((symbol-function 'httpd-send-header)
               (lambda (_proc _mime code &rest _headers)
                 (setq status code httpd--header-sent t))))
      (dolist (case '(("GET" "test" t 405)
                      ("POST" "unknown" t 403)
                      ("POST" "test" nil 403)
                      ("POST" "test" t 200)))
        (setq allowed (nth 2 case))
        (httpd/api/open-in-app nil "/api/open-in-app" nil
                              `((,(car case) "/api/open-in-app" "HTTP/1.1")
                                ("X-Editor-Token" ,(nth 1 case))))
        (should (= status (nth 3 case))))
      (should (equal calls (list (list (if (eq system-type 'darwin) "open" "xdg-open")
                                      nil nil nil path))))
      (setq exit-status 1)
      (httpd/api/open-in-app nil "/api/open-in-app" nil
                            '(("POST" "/api/open-in-app" "HTTP/1.1")
                              ("X-Editor-Token" "test")))
      (should (= status 400)))))

(ert-deftest excalimacs-save-unicode-http-body ()
  (let* ((directory (make-temp-file "excalimacs-unicode-" t))
         (path (expand-file-name "drawing.excalidraw" directory))
         (initial "{\"type\":\"excalidraw\",\"elements\":[],\"appState\":{},\"files\":{}}")
         (edited "{\"type\":\"excalidraw\",\"elements\":[{\"type\":\"text\",\"text\":\"😀 👨‍👩‍👧‍👦 café اردو\"}],\"appState\":{},\"files\":{}}")
         (excalimacs--sessions (make-hash-table :test #'equal))
         (status nil))
    (unwind-protect
        (progn
          (with-temp-file path (insert initial))
          (puthash "test" path excalimacs--sessions)
          ;; simple-httpd inserts binary process output into a multibyte buffer.
          (let ((body (with-temp-buffer
                        (insert (encode-coding-string
                                 (json-serialize
                                  `((baseHash . ,(excalimacs--hash initial))
                                    (text . ,edited))) 'utf-8))
                        (buffer-string))))
            (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) t))
                      ((symbol-function 'httpd-send-header)
                       (lambda (_proc _mime code &rest _headers)
                         (setq status code httpd--header-sent t))))
              (httpd/api/drawing nil "/api/drawing" nil
                                 `(("PUT" "/api/drawing" "HTTP/1.1")
                                   ("X-Editor-Token" "test") ("Content" ,body)))))
          (should (= status 200))
          (should (equal (excalimacs--read path) edited)))
      (delete-directory directory t))))

(ert-deftest excalimacs-save-rejects-stale-writers ()
  (let* ((directory (make-temp-file "excalimacs-test-" t))
         (path (expand-file-name "drawing.excalidraw" directory))
         (initial "{\"type\":\"excalidraw\",\"elements\":[],\"appState\":{},\"files\":{}}")
         (edited "{\"type\":\"excalidraw\",\"elements\":[{\"id\":\"one\",\"type\":\"text\",\"text\":\"hello\"}],\"appState\":{},\"files\":{}}"))
    (unwind-protect
        (progn
          (with-temp-file path (insert initial))
          (let ((old-hash (excalimacs--hash initial)))
            (should (equal (excalimacs--save path old-hash edited)
                           (excalimacs--hash edited)))
            (should-error (excalimacs--save path old-hash initial)
                          :type 'file-already-exists))
          (should (equal (excalimacs--read path) edited))
          (should-not (file-exists-p (expand-file-name ".excalidraw-backups" directory))))
      (delete-directory directory t))))

(ert-deftest excalimacs-create-inserts-searchable-block ()
  (let ((directory (make-temp-file "excalimacs-org-" t))
        (opened nil))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (let ((excalimacs-directory directory))
            (cl-letf (((symbol-function 'excalimacs-open)
                       (lambda (path) (setq opened path))))
              (excalimacs-create-drawing "example")))
          (should (equal opened (expand-file-name "example.excalidraw.png" directory)))
          (should (equal (buffer-string)
                         (format "#+begin_excalimacs :file %S\n#+end_excalimacs" opened)))
          (should-not (file-exists-p opened)))
      (delete-directory directory t))))

(ert-deftest excalimacs-create-resolves-directory-function-in-source-buffer ()
  (let ((directory (make-temp-file "excalimacs-context-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'agent-shell-mode
                default-directory (file-name-as-directory directory))
          (let* ((source (current-buffer))
                 (calls 0)
                 (excalimacs-directory
                  (lambda ()
                    (should (eq (current-buffer) source))
                    (should (eq major-mode 'agent-shell-mode))
                    (cl-incf calls)
                    ".agent-shell/diagrams/"))
                 (expected (expand-file-name
                            ".agent-shell/diagrams/example.excalidraw.png"
                            directory)))
            (cl-letf (((symbol-function 'excalimacs-open)
                       (lambda (path) (should (equal path expected)))))
              (excalimacs-create-drawing "example"))
            (should (= calls 1))
            (should (file-directory-p (file-name-directory expected)))
            (should (equal (buffer-string) (format "@%S" expected)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-create-rejects-invalid-directory-function-result ()
  (with-temp-buffer
    (let ((excalimacs-directory (lambda () nil)))
      (cl-letf (((symbol-function 'excalimacs-open)
                 (lambda (_) (ert-fail "Should not open a drawing"))))
        (should-error (excalimacs-create-drawing "example") :type 'user-error))
      (should (equal (buffer-string) "")))))

(ert-deftest excalimacs-org-delete-drawing-removes-block-and-optional-file ()
  (let* ((directory (make-temp-file "excalimacs-delete-" t))
         (file (expand-file-name "drawing.excalidraw.png" directory))
         (png (concat (unibyte-string 137 80 78 71 13 10 26 10) "data")))
    (unwind-protect
        (dolist (setting '(nil t ask))
          (with-temp-file file (set-buffer-multibyte nil) (insert png))
          (with-temp-buffer
            (org-mode)
            (insert (format "Before\n#+begin_excalimacs :file %S\n#+end_excalimacs\nAfter" file))
            (excalimacs-minor-mode 1)
            (goto-char (point-min))
            (search-forward "After")
            (backward-char (length "After"))
            (should (eq (key-binding (kbd "DEL")) #'excalimacs-delete-backward))
            (let ((excalimacs-delete-file setting))
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
                (excalimacs-delete-backward)))
            (should (equal (buffer-string) "Before\nAfter"))
            (should (eq (file-exists-p file) (if setting nil t)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-png-save-is-atomic-and-rejects-stale-writers ()
  (let* ((directory (make-temp-file "excalimacs-png-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory))
         (png-a (concat (unibyte-string 137 80 78 71 13 10 26 10) "first"))
         (png-b (concat (unibyte-string 137 80 78 71 13 10 26 10) "second")))
    (unwind-protect
        (let ((hash-a (excalimacs--write-png path png-a nil)))
          (should (equal hash-a (excalimacs--hash-bytes png-a)))
          (should-error (excalimacs--write-png path png-b "stale")
                        :type 'file-already-exists)
          (should (equal (excalimacs--read-bytes path) png-a))
          (should (equal (excalimacs--write-png path png-b hash-a)
                         (excalimacs--hash-bytes png-b))))
      (delete-directory directory t))))

(ert-deftest excalimacs-updates-searchable-block-text ()
  (let* ((directory (make-temp-file "excalimacs-block-" t))
         (org-file (expand-file-name "note.org" directory))
         (drawing (expand-file-name "drawing.excalidraw.png" directory)))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name org-file)
          (org-mode)
          (insert "Before\n#+begin_excalimacs :file drawing.excalidraw.png\nold text\n#+end_excalimacs\nAfter\n")
          (excalimacs--replace-block-text drawing '("Authentication" "PostgreSQL"))
          (should (equal (buffer-string)
                         "Before\n#+begin_excalimacs :file drawing.excalidraw.png\nAuthentication\nPostgreSQL\n#+end_excalimacs\nAfter\n")))
      (delete-directory directory t))))

(ert-deftest excalimacs-templates-insert-in-any-supported-mode ()
  (let ((directory (make-temp-file "excalimacs-template-" t)))
    (unwind-protect
        (dolist (case '((org-mode "#+begin_excalimacs :file " "#+end_excalimacs")
                        (markdown-mode "<!-- excalidraw: " "-->")
                        (emacs-lisp-mode "; excalidraw: " "; /excalidraw")
                        (agent-shell-mode "@" nil)
                        (fundamental-mode "excalidraw: " "end-excalidraw")))
          (with-temp-buffer
            (if (fboundp (car case))
                (funcall (car case))
              (setq major-mode (car case)))
            (let ((excalimacs-directory directory)
                  (path (expand-file-name
                         (format "%s.excalidraw.png" (car case)) directory)))
              (cl-letf (((symbol-function 'excalimacs-open) #'ignore))
                (excalimacs-create-drawing (symbol-name (car case))))
              (should (string-prefix-p (concat (nth 1 case) (prin1-to-string path))
                                       (buffer-string)))
              (when (nth 2 case)
                (should (string-suffix-p (concat "\n" (nth 2 case))
                                         (buffer-string))))
              (should (equal (caddr (car (excalimacs--blocks))) path)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-custom-template-and-optional-text ()
  (let* ((directory (make-temp-file "excalimacs-custom-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory))
         (excalimacs-templates '((fundamental-mode :begin "DRAW {file}"
                                                  :end "END" :text t))))
    (unwind-protect
        (with-temp-buffer
          (fundamental-mode)
          (let ((excalimacs-directory directory))
            (cl-letf (((symbol-function 'excalimacs-open) #'ignore))
              (excalimacs-create-drawing "drawing")))
          (excalimacs--replace-block-text path '("hello" "world"))
          (should (equal (buffer-string)
                         (format "DRAW %S\nhello\nworld\nEND" path))))
      (delete-directory directory t))))

(ert-deftest excalimacs-conditional-deletion-preserves-major-mode-keys ()
  (let* ((directory (make-temp-file "excalimacs-keys-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory)))
    (unwind-protect
        (with-temp-buffer
          (emacs-lisp-mode)
          (insert (format "; excalidraw: %S\n; /excalidraw\nAfter" path))
          (with-temp-file path (insert "png"))
          (cl-letf (((symbol-function 'create-image) (lambda (&rest _) "image")))
            (excalimacs-minor-mode 1)
            (goto-char (point-max))
            (should-not (eq (key-binding (kbd "DEL")) #'excalimacs-delete-backward))
            (search-backward "After")
            (should (eq (key-binding (kbd "DEL")) #'excalimacs-delete-backward))
            (let ((excalimacs-delete-file nil))
              (excalimacs-delete-backward))
            (should (equal (buffer-string) "After"))
            (should (file-exists-p path))))
      (delete-directory directory t))))

(ert-deftest excalimacs-does-not-delete-read-only-history ()
  (let* ((directory (make-temp-file "excalimacs-history-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'agent-shell-mode)
          (insert (format "@%S\n" path))
          (put-text-property (point-min) (1- (point-max)) 'read-only t)
          (with-temp-file path (insert "png"))
          (cl-letf (((symbol-function 'create-image) (lambda (&rest _) "image")))
            (excalimacs-minor-mode 1)
            (goto-char (1- (point-max)))
            (let ((excalimacs-delete-file nil))
              (should-error (excalimacs-delete-backward) :type 'text-read-only))
            (should (string-prefix-p "@" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-agent-shell-finds-only-drawing-mentions ()
  (with-temp-buffer
    (setq major-mode 'agent-shell-mode)
    (insert "Codex> @\"/tmp/drawing.excalidraw.png\" and @\"/tmp/photo.png\"")
    (let ((blocks (excalimacs--blocks)))
      (should (= (length blocks) 1))
      (pcase-let ((`(,begin ,end ,path) (car blocks)))
        (should (equal (buffer-substring-no-properties begin end)
                       "@\"/tmp/drawing.excalidraw.png\""))
        (should (equal path "/tmp/drawing.excalidraw.png"))))))

(ert-deftest excalimacs-finds-drawing-after-buffer-reload ()
  (let ((saved "Codex> @\"/tmp/drawing.excalidraw.png\""))
    (with-temp-buffer
      (setq major-mode 'agent-shell-mode)
      (insert saved)
      (should (= (length (excalimacs--blocks)) 1)))))

(ert-deftest excalimacs-restores-image-after-prompt-rewrite ()
  (let* ((directory (make-temp-file "excalimacs-rewrite-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory))
         (mention (format "@%S" path)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'agent-shell-mode)
          (insert mention)
          (with-temp-file path (insert "png"))
          (cl-letf (((symbol-function 'create-image) (lambda (&rest _) "image")))
            (excalimacs-minor-mode 1)
            (let ((inhibit-read-only t))
              (delete-region (point-min) (point-max))
              (insert "Codex> " mention))
            (sleep-for 0.05)
            (should (= (length excalimacs--overlays) 1))
            (should (equal (buffer-substring-no-properties
                            (overlay-start (car excalimacs--overlays))
                            (overlay-end (car excalimacs--overlays)))
                           mention))))
      (delete-directory directory t))))

(ert-deftest excalimacs-agent-shell-deletes-only-mention ()
  (let* ((directory (make-temp-file "excalimacs-agent-" t))
         (path (expand-file-name "drawing.excalidraw.png" directory)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'agent-shell-mode)
          (insert (format "Codex> @%S\nNext" path))
          (with-temp-file path (insert "png"))
          (cl-letf (((symbol-function 'create-image) (lambda (&rest _) "image")))
            (excalimacs-minor-mode 1)
            (goto-char (overlay-start (car excalimacs--overlays)))
            (let ((excalimacs-delete-file nil))
              (excalimacs-delete-forward))
            (should (equal (buffer-string) "Codex> \nNext"))))
      (delete-directory directory t))))

(ert-deftest excalimacs-agent-shell-creates-at-point ()
  (let ((directory (make-temp-file "excalimacs-agent-create-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'agent-shell-mode)
          (insert "Codex> Explain this")
          (goto-char (+ (point-min) (length "Codex> ")))
          (let ((excalimacs-directory directory))
            (cl-letf (((symbol-function 'excalimacs-open) #'ignore))
              (excalimacs-create-drawing "example")))
          (should (equal (buffer-string)
                         (format "Codex> @%SExplain this"
                                 (expand-file-name "example.excalidraw.png"
                                                   directory)))))
      (delete-directory directory t))))

(ert-deftest excalimacs-element-links-use-org-and-authorized-session ()
  (let ((excalimacs--sessions (make-hash-table :test #'equal))
        (allowed t)
        status opened)
    (puthash "test" "/tmp/drawings/example.excalidraw.png" excalimacs--sessions)
    (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) allowed))
              ((symbol-function 'org-link-open-from-string)
               (lambda (link &optional _arg)
                 (push (list link default-directory (current-buffer)) opened)))
              ((symbol-function 'httpd-send-header)
               (lambda (_proc _mime code &rest _headers)
                 (setq status code httpd--header-sent t))))
      (dolist (case '(("GET" "test" t 405)
                      ("POST" "unknown" t 403)
                      ("POST" "test" nil 403)))
        (setq allowed (nth 2 case))
        (httpd/api/open-link nil "/api/open-link" nil
                            `((,(car case) "/api/open-link" "HTTP/1.1")
                              ("X-Editor-Token" ,(nth 1 case))))
        (should (= status (nth 3 case))))
      (should-not opened)
      (setq allowed t)
      (dolist (link '("id:abc" "file:notes.org::Heading" "agent-shell:session"
                      "pdf:document.pdf#page=2" "https://example.com"))
        (httpd/api/open-link nil "/api/open-link" nil
                            `(("POST" "/api/open-link" "HTTP/1.1")
                              ("X-Editor-Token" "test")
                              ("Content" ,(json-serialize `((link . ,link))))))
        (should (= status 200))
        (should (equal (caar opened) (concat "[[" link "]]")))
        (should (equal (cadar opened) "/tmp/drawings/"))
        (should (eq (nth 2 (car opened)) (window-buffer (selected-window)))))
      (httpd/api/open-link nil "/api/open-link" nil
                          '(("POST" "/api/open-link" "HTTP/1.1")
                            ("X-Editor-Token" "test") ("Content" "{\"link\":null}")))
      (should (= status 400)))))

(ert-deftest excalimacs-element-links-accept-org-brackets ()
  (let ((excalimacs--sessions (make-hash-table :test #'equal))
        (org-link-parameters (copy-tree org-link-parameters))
        status opened)
    (puthash "test" "/tmp/drawing.excalidraw.png" excalimacs--sessions)
    (org-link-set-parameters "excalimacs-test"
                             :follow (lambda (path _arg) (setq opened path)))
    (cl-letf (((symbol-function 'excalimacs--allowed-origin-p) (lambda (_) t))
              ((symbol-function 'httpd-send-header)
               (lambda (_proc _mime code &rest _headers)
                 (setq status code httpd--header-sent t))))
      (dolist (link '("excalimacs-test:hello"
                      "[[excalimacs-test:hello]]"
                      " [[excalimacs-test:hello][A description]] "))
        (setq opened nil)
        (httpd/api/open-link nil "/api/open-link" nil
                            `(("POST" "/api/open-link" "HTTP/1.1")
                              ("X-Editor-Token" "test")
                              ("Content" ,(json-serialize `((link . ,link))))))
        (should (= status 200))
        (should (equal opened "hello"))))))

(ert-deftest excalimacs-org-projection-exposes-links ()
  (dolist (name '("excalimacs"))
    (with-temp-buffer
      (org-mode)
      (insert (format "#+begin_%s :file /tmp/example.excalidraw.png\n: old\n#+end_%s\n"
                      name name))
      (excalimacs--replace-block-text "/tmp/example.excalidraw.png"
                                    '(": Label" ": [[id:abc][Note]]"))
      (should (string-match-p "\nLabel\n\\[\\[id:abc\\]\\[Note\\]\\]\n" (buffer-string)))
      (should (equal (org-element-map (org-element-parse-buffer) 'link
                       (lambda (link) (org-element-property :raw-link link)))
                     '("id:abc"))))))

(provide 'excalimacs-test)
;;; excalimacs-test.el ends here
