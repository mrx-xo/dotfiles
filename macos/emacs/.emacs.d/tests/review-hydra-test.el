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

(ert-deftest review-hydra-uses-the-session-keys ()
  "Every hydra head for a session key is the key the panes and panel use."
  (dolist (k review-session-keys)
    (unless (eq (cdr k) 'review-session-quit) ; `q' leaves the hydra, `Q' quits
      (let ((head (lookup-key hydra-review/keymap (kbd (car k)))))
        (should (symbolp head))
        (should (string-prefix-p (format "hydra-review/%s" (cdr k))
                                 (symbol-name head)))))))

(ert-deftest review-hydra-and-panes-switch-long-lines ()
  (should (string-prefix-p "hydra-review/review-session-toggle-long-lines"
                           (symbol-name (lookup-key hydra-review/keymap (kbd "w")))))
  (dolist (k review-session-long-line-keys)
    (should (eq (lookup-key (evil-get-auxiliary-keymap review-pane-mode-map 'normal) (kbd (car k)))
                (cdr k)))))

(ert-deftest review-session-keys-bind-panes-and-panel ()
  (dolist (map (list review-pane-mode-map review-panel-mode-map))
    (dolist (k review-session-keys)
      (should (eq (lookup-key map (kbd (car k))) (cdr k)))
      (should (eq (lookup-key (evil-get-auxiliary-keymap map 'normal) (kbd (car k)))
                  (cdr k)))))
  ;; `v' is left to Evil so panes can select text for Quick Ask.
  (should-not (lookup-key review-pane-mode-map (kbd "v"))))

(provide 'review-hydra-test)
