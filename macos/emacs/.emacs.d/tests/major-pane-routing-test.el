;;; major-pane-routing-test.el --- Pane navigation regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'major-pane)

(defmacro major-pane-routing-test--with-layout (&rest body)
  "Run BODY with two conversations and an isolated pane layout."
  (declare (indent 0))
  `(save-window-excursion
     (let* ((first (generate-new-buffer " *pane-first*"))
            (second (generate-new-buffer " *pane-second*"))
            (target (generate-new-buffer " *pane-target*"))
            (major-pane--state
             (major-pane--make-state :mode 'side
                                    :conversations (list first second)
                                    :active first))
            (major-pane-home-frame nil)
            (major-pane-direction 'left)
            (switch-to-buffer-obey-display-actions t)
            (display-buffer-alist
             '((major-pane-work-buffer-p
                (major-pane-display-work-buffer-action))))
            (display-buffer-overriding-action nil)
            (display-buffer-base-action nil)
            (pane (selected-window)))
       (unwind-protect
           (progn
             (delete-other-windows)
             (set-window-dedicated-p pane nil)
             (set-window-buffer pane first)
             (set-window-parameter pane 'major-pane t)
             (set-window-dedicated-p pane 'soft)
             (select-window pane)
             ,@body)
         (set-window-dedicated-p pane nil)
         (set-window-parameter pane 'major-pane nil)
         (mapc #'kill-buffer (list first second target))))))

(ert-deftest major-pane-routing-tab-navigation-preserves-pane ()
  "Tab cycling, tab clicks and goto must not let the next file steal the pane."
  (dolist (navigation '(cycle click goto))
    (major-pane-routing-test--with-layout
      (let* ((main (split-window pane nil 'right))
             (edges (window-edges pane)))
        (set-window-buffer main target)
        (pcase navigation
          ('cycle (major-pane-next-tab))
          ('click
           (let* ((tab (major-pane--render-tab second nil))
                  (pos (text-property-not-all 0 (length tab) 'local-map nil tab)))
             (funcall (lookup-key (get-text-property pos 'local-map tab)
                                  [header-line mouse-1]))))
          ('goto (major-pane-goto-conversation second)))
        ;; This fails before routing is involved: set-window-buffer clears
        ;; soft dedication whenever it replaces the displayed conversation.
        (should (window-dedicated-p pane))
        (switch-to-buffer target)
        (should (eq (window-buffer pane) second))
        (should (eq (selected-window) main))
        (should (equal (window-edges pane) edges))))))

(ert-deftest major-pane-routing-full-pane-opens-file-to-right ()
  "A sole conversation window must create its work area on the right."
  (major-pane-routing-test--with-layout
    (let ((file (make-temp-file "major-pane-link-")))
      (unwind-protect
          (progn
            (find-file file)
            (should (eq (window-buffer pane) first))
            (should (> (car (window-edges (selected-window)))
                       (car (window-edges pane))))
            (should (= (nth 1 (window-edges (selected-window)))
                       (nth 1 (window-edges pane)))))
        (when-let ((buf (get-file-buffer file))) (kill-buffer buf))
        (delete-file file)))))

(ert-deftest major-pane-routing-restored-pane-recovers-protection ()
  "Restoring a layout must recover dedication as well as pane chrome."
  (major-pane-routing-test--with-layout
    (set-window-dedicated-p pane nil)
    (set-window-parameter pane 'major-pane nil)
    (major-pane--refresh-decorations)
    (should (window-parameter pane 'major-pane))
    (should (window-dedicated-p pane))))

(ert-deftest major-pane-routing-capture-remains-explicit-takeover ()
  "The intentional capture command may still replace the conversation."
  (major-pane-routing-test--with-layout
    (major-pane-capture-buffer target)
    (major-pane--refresh-decorations)
    (should (eq (window-buffer pane) target))
    (should-not (window-parameter pane 'major-pane))
    (should-not (window-dedicated-p pane))))

(ert-deftest major-pane-routing-leaves-ordinary-windows-alone ()
  "The pane fallback must not redirect navigation from the work area."
  (major-pane-routing-test--with-layout
    (let ((main (split-window pane nil 'right)))
      (set-window-buffer main target)
      (select-window main)
      (should-not (major-pane-work-buffer-p (buffer-name first) nil))
      (should-not (major-pane-work-buffer-p (buffer-name target) nil))
      (select-window pane)
      (should-not (major-pane-work-buffer-p (buffer-name second) nil)))))

(ert-deftest major-pane-routing-keeps-popup-windows-out-of-work-area ()
  "Opening a file must neither overwrite nor promote an existing popup."
  (major-pane-routing-test--with-layout
    (let* ((popup-buffer (generate-new-buffer " *pane-popup*"))
           (popup (display-buffer-in-side-window
                   popup-buffer '((side . bottom) (window-height . 0.25)))))
      (unwind-protect
          (progn
            (switch-to-buffer target)
            (should (eq (window-buffer pane) first))
            (should (eq (window-buffer popup) popup-buffer))
            (should-not (eq (selected-window) popup))
            (should (> (car (window-edges (selected-window)))
                       (car (window-edges pane)))))
        (kill-buffer popup-buffer)))))

(provide 'major-pane-routing-test)
;;; major-pane-routing-test.el ends here
