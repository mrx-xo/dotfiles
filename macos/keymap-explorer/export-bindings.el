;;; export-bindings.el --- Read effective leader bindings for practice -*- lexical-binding: t; -*-

(require 'json)
(require 'cl-lib)

(defun iris-practice-export (destination)
  "Write browser-safe, effective SPC bindings to DESTINATION atomically.
Inspect a disposable fundamental-mode buffer in Evil normal state.  No
commands are invoked and no keymaps or existing buffers are changed."
  (unless (fboundp 'evil-normal-state)
    (error "Evil is not loaded; start your normal Emacs session first"))
  (let ((cards nil) (skipped 0) (visited (make-hash-table :test #'equal)))
    (with-temp-buffer
      (fundamental-mode)
      (evil-local-mode 1)
      (evil-normal-state)
      (cl-labels
          ((walk (prefix depth)
             (let ((map (key-binding prefix t)))
               (when (and (keymapp map) (< depth 5))
                 (map-keymap
                  (lambda (event _definition)
                    (when (or (integerp event) (symbolp event))
                      (let* ((keys (vconcat prefix (vector event)))
                             (description (key-description keys))
                             (binding (key-binding keys t)))
                        (unless (gethash description visited)
                          (puthash description t visited)
                          (cond
                           ((keymapp binding) (walk keys (1+ depth)))
                           ((and (symbolp binding) (commandp binding)
                                 (not (memq binding '(undefined ignore))))
                            (if (cl-every (lambda (key) (and (integerp key) (<= 32 key 126))) keys)
                                (push `((id . ,(concat description ":" (symbol-name binding)))
                                        (sequence . ,description)
                                        (keys . ,(vconcat (mapcar #'char-to-string keys)))
                                        (command . ,(symbol-name binding))
                                        (group . ,(key-description (cl-subseq keys 0 (min 2 (length keys))))))
                                      cards)
                              (cl-incf skipped))))))))
                  map)))))
        (walk (kbd "SPC") 0)))
    (unless cards (error "No printable SPC leader bindings found; previous export preserved"))
    (let* ((payload `((version . 1)
                      (generatedAt . ,(format-time-string "%FT%TZ" nil t))
                      (context . "fundamental-mode / Evil normal / SPC leader")
                      (skipped . ,skipped)
                      (cards . ,(vconcat (sort cards (lambda (a b) (string< (alist-get 'sequence a) (alist-get 'sequence b))))))))
           (temporary (make-temp-file (concat destination "."))))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (insert "// Generated from the running Emacs. Refresh with ./practice.sh --refresh-only.\n"
                      "window.IRIS_BINDINGS = " (json-encode payload) ";\n"))
            (rename-file temporary destination t))
        (when (file-exists-p temporary) (delete-file temporary))))
    (format "Exported %d bindings; %d non-printable/chord bindings excluded" (length cards) skipped)))

(provide 'iris-practice-export)
;;; export-bindings.el ends here
