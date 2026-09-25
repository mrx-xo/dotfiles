;;; review-hydra-test.el --- Preserve normal movement in the review hydra -*- lexical-binding: t; -*-
(require 'ert)
(require 'evil)
(require 'review-hydra)

(ert-deftest review-hydra-preserves-normal-navigation ()
  (dolist (mode '(review-pane-mode review-panel-mode))
    (with-temp-buffer
      (funcall mode)
      (evil-local-mode 1)
      (evil-normal-state)
      (let* ((buffer (current-buffer))
             (keys '("j" "k" "n" "p"))
             (bindings (lambda ()
                         ;; The hint display can change the current buffer in
                         ;; batch; the command loop reads the pane's own maps.
                         (with-current-buffer buffer
                           (mapcar (lambda (key) (key-binding (kbd key) t)) keys))))
             (before (funcall bindings)))
        (unwind-protect
            (progn
              (hydra-review/body)
              (dolist (key keys)
                (should-not (lookup-key hydra-review/keymap (kbd key))))
              (should (equal before (funcall bindings)))
              ;; A normal command runs through the hydra and keeps it open,
              ;; like every other mode hydra (:foreign-keys run).
              (let ((this-command (car before))) (hydra--clearfun))
              (should hydra-curr-map))
          (hydra-keyboard-quit))))))

(ert-deftest review-hydra-navigation-uses-control-keys ()
  (dolist (pair '(("C-j" . hydra-review/review-session-next-file)
                  ("C-k" . hydra-review/review-session-prev-file)
                  ("C-n" . hydra-review/review-session-next-hunk)
                  ("C-p" . hydra-review/review-session-prev-hunk)))
    (should (eq (lookup-key hydra-review/keymap (kbd (car pair))) (cdr pair)))))

(provide 'review-hydra-test)
