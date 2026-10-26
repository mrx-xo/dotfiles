;;; syzygy-projects-test.el --- Tests for syzygy-projects -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)

(defvar project-dashboard-projects)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "syzygy-bridge.el" dir) nil t)
  (load (expand-file-name "syzygy-projects.el" dir) nil t))

(defun syzygy-projects-test--decode (encoded)
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist :array-type 'list))

(ert-deftest syzygy-projects-json-expands-and-preserves-order ()
  (let ((project-dashboard-projects
         '(("dotfiles" . "~/.dotfiles") ("mobile" . "/tmp/mobile"))))
    (let ((got (syzygy-projects-test--decode (syzygy-projects-json))))
      (should (equal (mapcar (lambda (p) (alist-get 'name p)) got)
                     '("dotfiles" "mobile")))
      (should (equal (alist-get 'path (car got)) (expand-file-name "~/.dotfiles")))
      (should (equal (alist-get 'path (nth 1 got)) "/tmp/mobile")))))

(ert-deftest syzygy-projects-json-empty-list-is-an-empty-array ()
  (let ((project-dashboard-projects nil))
    (should (equal (syzygy-projects-test--decode (syzygy-projects-json)) '()))))

(ert-deftest syzygy-projects-json-is-nil-without-the-rig-variable ()
  (let ((saved (and (boundp 'project-dashboard-projects) project-dashboard-projects)))
    (unwind-protect
        (progn (makunbound 'project-dashboard-projects)
               (should (null (syzygy-projects-json))))
      (setq project-dashboard-projects saved))))

(provide 'syzygy-projects-test)
;;; syzygy-projects-test.el ends here
