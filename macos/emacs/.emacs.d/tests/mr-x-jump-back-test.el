;;; mr-x-jump-back-test.el --- Tests for mr-x-jump-back -*- lexical-binding: t; -*-

(require 'ert)
(add-to-list 'load-path (expand-file-name "../lisp" (file-name-directory
                                                     (or load-file-name buffer-file-name))))
(require 'mr-x-jump-back)

(defmacro mr-x-jump-back-test--with-setup (&rest body)
  "Run BODY with a file-like buffer on the left and a shell-like one on the right."
  (declare (indent 0))
  `(save-window-excursion
     (let ((mr-x-jump-back--list nil)
           (mr-x-jump-back--index -1)
           (mr-x-jump-back--pre nil)
           (file (generate-new-buffer "jb-file"))
           (shell (generate-new-buffer "jb-shell")))
       (unwind-protect
           (progn
             (delete-other-windows)
             (with-current-buffer file
               (dotimes (i 300) (insert (format "line %d\n" i))))
             (with-current-buffer shell (insert "prompt> "))
             (switch-to-buffer file)
             (let ((left (selected-window))
                   (right (split-window-right)))
               (set-window-buffer right shell)
               ,@body))
         (kill-buffer file)
         (kill-buffer shell)))))

(defun mr-x-jump-back-test--run (cmd fn)
  "Run FN as if it were the command CMD, with the pre/post hooks around it."
  (let ((this-command cmd))
    (mr-x-jump-back--pre-command)
    (funcall fn)
    (mr-x-jump-back--post-command)))

(ert-deftest mr-x-jump-back-returns-to-other-window ()
  "Hop from the file window to the shell window, back lands on the file line."
  (mr-x-jump-back-test--with-setup
    (goto-char (point-min))
    (forward-line 199)
    (mr-x-jump-back-test--run 'some-hop (lambda () (select-window right)))
    (should (eq (selected-window) right))
    (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
    (should (eq (selected-window) left))
    (should (eq (current-buffer) file))
    (should (= (line-number-at-pos) 200))))

(ert-deftest mr-x-jump-back-forward-returns ()
  "After going back, forward returns to where back was pressed."
  (mr-x-jump-back-test--with-setup
    (mr-x-jump-back-test--run 'some-hop (lambda () (select-window right)))
    (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
    (should (eq (selected-window) left))
    (mr-x-jump-back-test--run 'mr-x/jump-forward #'mr-x/jump-forward)
    (should (eq (selected-window) right))
    (should (eq (current-buffer) shell))))

(ert-deftest mr-x-jump-back-same-window-buffer-switch ()
  "Switching buffers inside one window is recorded, including non-file buffers."
  (mr-x-jump-back-test--with-setup
    (goto-char (point-min))
    (forward-line 50)
    (mr-x-jump-back-test--run 'some-switch (lambda () (switch-to-buffer shell)))
    (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
    (should (eq (current-buffer) file))
    (should (= (line-number-at-pos) 51))))

(ert-deftest mr-x-jump-back-skips-killed-buffers ()
  "Entries whose buffer was killed are skipped, not reopened."
  (mr-x-jump-back-test--with-setup
    (let ((gone (generate-new-buffer "jb-gone")))
      (mr-x-jump-back-test--run 'a (lambda () (switch-to-buffer gone)))
      (mr-x-jump-back-test--run 'b (lambda () (select-window right)))
      (kill-buffer gone)
      (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
      (should (eq (current-buffer) file)))))

(ert-deftest mr-x-jump-back-new-record-drops-forward-entries ()
  "Moving somewhere new after going back discards the forward entries."
  (mr-x-jump-back-test--with-setup
    (mr-x-jump-back-test--run 'hop (lambda () (select-window right)))
    (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
    (forward-line 10)
    (mr-x-jump-back-test--run 'hop (lambda () (switch-to-buffer shell)))
    (should (= mr-x-jump-back--index -1))
    (mr-x-jump-back-test--run 'mr-x/jump-forward #'mr-x/jump-forward)
    (should (eq (current-buffer) shell))))

(ert-deftest mr-x-jump-back-far-move-in-same-buffer ()
  "A command that jumps far inside one buffer (reply text to prompt) is recorded."
  (mr-x-jump-back-test--with-setup
    (goto-char (point-min))
    (forward-line 40)
    (mr-x-jump-back-test--run 'goto-prompt (lambda () (goto-char (point-max))))
    (mr-x-jump-back-test--run 'mr-x/jump-back #'mr-x/jump-back)
    (should (eq (current-buffer) file))
    (should (= (line-number-at-pos) 41))))

(ert-deftest mr-x-jump-back-scrolling-is-not-a-jump ()
  "Scrolling and short moves are not recorded."
  (mr-x-jump-back-test--with-setup
    (goto-char (point-min))
    (mr-x-jump-back-test--run 'evil-scroll-down (lambda () (forward-line 100)))
    (mr-x-jump-back-test--run 'evil-forward-word-begin (lambda () (forward-line 3)))
    (should (null mr-x-jump-back--list))))

;;; mr-x-jump-back-test.el ends here
