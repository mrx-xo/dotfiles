;;; major-pane-label-test.el --- New-chat name prompt and label ownership -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'major-pane)

(defmacro major-pane-label-test--with-state (&rest body)
  "Run BODY with fresh, isolated major-pane label and conversation state."
  (declare (indent 0))
  `(let ((major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (major-pane-modes '(fundamental-mode)))
     ,@body))

(defun major-pane-label-test--chat (dir)
  "Return a new registered conversation buffer whose project is DIR."
  (let ((buf (generate-new-buffer " *label-chat*")))
    (with-current-buffer buf (setq default-directory dir))
    (major-pane--register-conversation buf)
    buf))

(ert-deftest major-pane-label-default-is-project-plus-counter ()
  "The default name is the project directory name plus the first free number."
  (major-pane-label-test--with-state
    (let* ((root (make-temp-file "mp-label" t))
           (dir (file-name-as-directory (expand-file-name ".dotfiles" root)))
           a b)
      (make-directory dir)
      (unwind-protect
          (progn
            (setq a (major-pane-label-test--chat dir))
            (should (equal (major-pane--default-label a) "dotfiles 1"))
            (major-pane-set-buffer-label a "dotfiles 1" 'provisional)
            (setq b (major-pane-label-test--chat dir))
            (should (equal (major-pane--default-label b) "dotfiles 2")))
        (mapc (lambda (x) (when (buffer-live-p x) (kill-buffer x))) (list a b))
        (delete-directory root t)))))

(ert-deftest major-pane-label-provisional-flag-follows-last-set ()
  "A provisional label is marked; setting a real name clears the mark."
  (major-pane-label-test--with-state
    (let ((buf (generate-new-buffer " *label-flag*")))
      (unwind-protect
          (progn
            (major-pane-set-buffer-label buf "dotfiles 1" 'provisional)
            (should (equal (gethash buf major-pane--labels) "dotfiles 1"))
            (should (major-pane-label-provisional-p buf))
            (major-pane-set-buffer-label buf "release notes")
            (should (equal (gethash buf major-pane--labels) "release notes"))
            (should-not (major-pane-label-provisional-p buf))
            (major-pane-set-buffer-label buf nil)
            (should-not (gethash buf major-pane--labels))
            (should-not (major-pane-label-provisional-p buf)))
        (kill-buffer buf)))))

(ert-deftest major-pane-label-prompt-gate ()
  "`launch' prompts only inside a keyboard launch; t always; nil never."
  (let ((major-pane-prompt-label-on-start nil)
        (major-pane-launch-prompt-label t))
    (should-not (major-pane--prompt-label-p)))
  (let ((major-pane-prompt-label-on-start t)
        (major-pane-launch-prompt-label nil))
    (should (major-pane--prompt-label-p)))
  (let ((major-pane-prompt-label-on-start 'launch)
        (major-pane-launch-prompt-label nil))
    (should-not (major-pane--prompt-label-p)))
  (let ((major-pane-prompt-label-on-start 'launch)
        (major-pane-launch-prompt-label t))
    (should (major-pane--prompt-label-p))))

(ert-deftest major-pane-label-prompt-typed-name-is-final ()
  "A typed name is stored as a final label."
  (major-pane-label-test--with-state
    (let ((buf (generate-new-buffer " *label-typed*")))
      (unwind-protect
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _) "release notes")))
            (major-pane--prompt-start-label buf "dotfiles 1")
            (should (equal (gethash buf major-pane--labels) "release notes"))
            (should-not (major-pane-label-provisional-p buf)))
        (kill-buffer buf)))))

(ert-deftest major-pane-label-prompt-enter-or-quit-gives-provisional-default ()
  "Enter on the default, a blank answer, or C-g all leave a provisional default."
  (major-pane-label-test--with-state
    (dolist (answer (list "dotfiles 1" "" "   " 'quit))
      (let ((buf (generate-new-buffer " *label-default*")))
        (unwind-protect
            (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _)
                         (if (eq answer 'quit) (signal 'quit nil) answer))))
              (major-pane--prompt-start-label buf "dotfiles 1")
              (should (equal (gethash buf major-pane--labels) "dotfiles 1"))
              (should (major-pane-label-provisional-p buf)))
          (kill-buffer buf))))))

;;; major-pane-label-test.el ends here
