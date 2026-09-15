;;; journal-copy-tests.el --- Journal copy regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'org-id)
(require 'org-refile)
(require 'cl-lib)

;; Load only the production definitions: no personal capture data or timers.
(let ((source (expand-file-name "../init.el" (file-name-directory load-file-name))))
  (with-temp-buffer
    (insert-file-contents source)
    (goto-char (point-min))
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (and (eq (car-safe form) 'defun)
                       (memq (cadr form)
                             '(my/org-roam-copy-todo-to-today
                               my/org-roam-renew-copied-ids)))
              (eval form t))))
      (end-of-file nil))))

(ert-deftest journal-copy-preserves-source-and-renews-subtree-ids ()
  "Copying must not reuse source IDs or change unrelated journal entries."
  (let* ((dir (make-temp-file "journal-copy-test-" t))
         (source (expand-file-name "source.org" dir))
         (daily (expand-file-name "daily.org" dir))
         (original "* DONE Parent\n:PROPERTIES:\n:ID: parent-id\n:END:\nBody [[id:parent-id][source]].\n** DONE Child\n:PROPERTIES:\n:ID: child-id\n:END:\n** Plain child\nNotes.\n")
         (org-id-locations (make-hash-table :test 'equal))
         (org-id-files nil)
         (org-id-locations-file (expand-file-name "ids" dir))
         (org-mode-hook nil)
         (org-after-todo-state-change-hook nil)
         (org-bookmark-names-plist nil)
         (org-log-refile nil)
         (org-refile-use-cache nil))
    (unwind-protect
        (progn
          (with-temp-file source (insert original))
          (with-temp-file daily
            (insert "* Tasks\n** Existing\n:PROPERTIES:\n:ID: existing-id\n:END:\n"))
          ;; Capture normally opens today's personal journal. Redirect only
          ;; that boundary; exercise the real copy/refile and save operations.
          (cl-letf (((symbol-function 'org-roam-dailies--capture)
                     (lambda (&rest _)
                       (set-buffer (find-file-noselect daily))
                       (goto-char (point-min)))))
            (with-current-buffer (find-file-noselect source)
              (goto-char (point-min))
              (my/org-roam-copy-todo-to-today)
              (should (equal (buffer-string) original))
              (should-not (buffer-modified-p))))
          (with-temp-buffer
            (insert-file-contents source)
            (should (equal (buffer-string) original)))
          (with-temp-buffer
            (insert-file-contents daily)
            (org-mode)
            (goto-char (point-min))
            (re-search-forward "^\\*\\* DONE Parent$")
            (let ((parent (org-entry-get nil "ID")))
              (should parent)
              (should-not (equal parent "parent-id"))
              (re-search-forward "^\\*\\*\\* DONE Child$")
              (let ((child (org-entry-get nil "ID")))
                (should child)
                (should-not (member child (list "child-id" parent)))))
            (re-search-forward "^\\*\\*\\* Plain child$")
            (should-not (org-entry-get nil "ID"))
            (goto-char (point-min))
            (re-search-forward "^\\*\\* Existing$")
            (should (equal (org-entry-get nil "ID") "existing-id"))
            (should (string-match-p (regexp-quote "Body [[id:parent-id][source]].")
                                    (buffer-string)))))
      (dolist (file (list source daily))
        (when-let ((buffer (get-file-buffer file)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory dir t))))
