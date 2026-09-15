;;; major-pane-layout-test.el --- Pane placement regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'major-pane)

(defmacro major-pane-layout-test--with-layout (&rest body)
  "Run BODY with real windows and an isolated conversation."
  (declare (indent 0))
  `(save-window-excursion
     (let* ((chat (generate-new-buffer " *layout-chat*"))
            (work (generate-new-buffer " *layout-work*"))
            (major-pane--state
             (major-pane--make-state :conversations (list chat) :active chat))
            (major-pane-home-frame nil)
            (major-pane-direction 'auto)
            (major-pane-width 0.30)
            (major-pane-height 0.35)
            (display-buffer-alist nil)
            (display-buffer-overriding-action nil)
            (display-buffer-base-action nil)
            (old-placement (frame-parameter nil 'major-pane-placement))
            (old-size (frame-parameter nil 'major-pane-frame-size)))
       (unwind-protect
           (progn
             (set-frame-parameter nil 'major-pane-placement nil)
             (set-frame-parameter nil 'major-pane-frame-size nil)
             (delete-other-windows)
             (set-window-dedicated-p (selected-window) nil)
             (set-window-parameter (selected-window) 'major-pane nil)
             (set-window-buffer (selected-window) work)
             ,@body)
         (set-frame-parameter nil 'major-pane-placement old-placement)
         (set-frame-parameter nil 'major-pane-frame-size old-size)
         (dolist (w (window-list nil 'nomini))
           (set-window-dedicated-p w nil)
           (set-window-parameter w 'major-pane nil))
         (kill-buffer chat)
         (kill-buffer work)))))

(defun major-pane-layout-test--assert-edge (pane work direction)
  "Assert PANE lies on DIRECTION relative to WORK, spanning the other axis."
  (pcase-let ((`(,pl ,pt ,pr ,pb) (window-edges pane))
              (`(,wl ,wt ,wr ,wb) (window-edges work)))
    (pcase direction
      ('left  (should (= pr wl)) (should (= pt wt)) (should (= pb wb)))
      ('right (should (= pl wr)) (should (= pt wt)) (should (= pb wb)))
      ('above (should (= pb wt)) (should (= pl wl)) (should (= pr wr)))
      ('below (should (= pt wb)) (should (= pl wl)) (should (= pr wr))))))

(ert-deftest major-pane-layout-auto-uses-frame-pixels ()
  "Tall frames open above; wide or square frames open left."
  (dolist (geometry '((900 1600 above) (1600 900 left) (900 900 left)))
    (major-pane-layout-test--with-layout
      ;; Pixel dimensions are external input; the split itself is real.
      (cl-letf (((symbol-function 'frame-pixel-width) (lambda (&optional _) (nth 0 geometry)))
                ((symbol-function 'frame-pixel-height) (lambda (&optional _) (nth 1 geometry))))
        (let* ((main (selected-window))
               (pane (major-pane-display-buffer-action chat nil)))
          (major-pane-layout-test--assert-edge pane main (nth 2 geometry)))))))

(ert-deftest major-pane-layout-all-directions-use-correct-size ()
  "Both display entry points honor all four edges and the correct size axis."
  (dolist (display '(major-pane--display major-pane-display-buffer-action))
    (dolist (direction '(left right above below))
      (major-pane-layout-test--with-layout
        (let* ((major-pane-direction direction)
               (main (selected-window))
               (horizontal (memq direction '(left right)))
               (total (if horizontal (window-total-width) (window-total-height)))
               (pane (if (eq display 'major-pane--display)
                         (funcall display chat)
                       (funcall display chat nil))))
          (major-pane-layout-test--assert-edge pane main direction)
          (should (<= (abs (- (if horizontal (window-total-width pane)
                               (window-total-height pane))
                             (* total (if horizontal 0.30 0.35))))
                      2)))))))

(ert-deftest major-pane-layout-manual-moves-pane-and-preserves-work ()
  "Changing edge preserves editor splits, selection, chat point and scroll."
  (major-pane-layout-test--with-layout
    (let* ((major-pane-direction 'left)
           (main (selected-window))
           (other (split-window main nil 'below))
           (pane (major-pane-display-buffer-action chat nil)))
      (with-current-buffer chat (insert (make-string 2000 ?x)))
      (set-window-point pane 123)
      (set-window-start pane 100)
      (major-pane-set-placement 'below)
      (let ((moved (get-buffer-window chat)))
        (should (eq (selected-window) main))
        (should (window-live-p other))
        (should (eq (window-buffer main) work))
        (should (= (window-point moved) 123))
        (should (= (window-start moved) 100))
        (should (= (car (window-edges moved)) (car (window-edges main))))
        (should (>= (nth 1 (window-edges moved)) (nth 3 (window-edges other))))
        (should (window-dedicated-p moved))
        (should (eq (major-pane-state-active major-pane--state) chat)))
      (select-window (get-buffer-window chat))
      (major-pane-set-placement 'right)
      (should (eq (window-buffer (selected-window)) chat)))))

(ert-deftest major-pane-layout-auto-resizes-unless-overridden ()
  "A manual edge survives aspect changes; selecting auto resumes adaptation."
  (major-pane-layout-test--with-layout
    (let ((width 1600) (height 900) (main (selected-window)))
      (cl-letf (((symbol-function 'frame-pixel-width) (lambda (&optional _) width))
                ((symbol-function 'frame-pixel-height) (lambda (&optional _) height)))
        (major-pane-display-buffer-action chat nil)
        (setq width 900 height 1600)
        (run-hook-with-args 'window-size-change-functions (selected-frame))
        (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'above)
        (major-pane-set-placement 'below)
        (setq width 1600 height 900)
        (run-hook-with-args 'window-size-change-functions (selected-frame))
        (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'below)
        (major-pane-set-placement 'auto)
        (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'left)
        ;; Hiding and showing must retain this frame's override.
        (major-pane-set-placement 'right)
        (major-pane-toggle)
        (major-pane-toggle)
        (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'right)))))

(ert-deftest major-pane-layout-hidden-choice-does-not-open-chat ()
  "Choosing an edge while hidden only changes the next opening."
  (major-pane-layout-test--with-layout
    (major-pane-set-placement 'below)
    (should-not (get-buffer-window chat))
    (should (eq (major-pane-state-mode major-pane--state) 'hidden))
    (let ((main (selected-window)))
      (major-pane-toggle)
      (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'below))))

(ert-deftest major-pane-layout-full-frame-defers-placement-until-restore ()
  "An override in full view keeps full view, then applies to the restored pane."
  (major-pane-layout-test--with-layout
    (let ((major-pane-direction 'left) (main (selected-window)))
      (select-window (major-pane-display-buffer-action chat nil))
      (major-pane-toggle t)
      (major-pane-set-placement 'below)
      (should (= (length (window-list nil 'nomini)) 1))
      (should (eq (major-pane-state-mode major-pane--state) 'full))
      (major-pane-toggle t)
      (major-pane-layout-test--assert-edge (get-buffer-window chat) main 'below))))

(ert-deftest major-pane-layout-work-area-opens-opposite-pane ()
  "Files and ejected chats split on the opposite edge of a sole pane."
  (dolist (direction '(left right above below))
    (dolist (open '(eject file))
      (major-pane-layout-test--with-layout
        (let* ((major-pane-direction direction) (pane (selected-window))
               (horizontal (memq direction '(left right)))
               (total (if horizontal (window-total-width) (window-total-height))))
          (setf (major-pane-state-mode major-pane--state) 'full)
          (set-window-buffer pane chat)
          (set-window-parameter pane 'major-pane t)
          (set-window-dedicated-p pane 'soft)
          (let ((main (if (eq open 'eject)
                          (major-pane--eject-target-window)
                        (major-pane-display-work-buffer-action work nil))))
            (major-pane-layout-test--assert-edge pane main direction)
            (should (<= (abs (- (if horizontal (window-total-width pane)
                                 (window-total-height pane))
                               (* total (if horizontal 0.30 0.35))))
                        2))))))))

(ert-deftest major-pane-layout-launcher-can-move ()
  "The empty-pane launcher honors placement changes too."
  (major-pane-layout-test--with-layout
    (let ((major-pane-launcher-buffer-name " *layout-launcher*")
          (main (selected-window)))
      (unwind-protect
          (progn
            (major-pane--show-launcher)
            (major-pane-set-placement 'below)
            (major-pane-layout-test--assert-edge
             (get-buffer-window major-pane-launcher-buffer-name) main 'below))
        (major-pane-launcher--quit)))))

(ert-deftest major-pane-layout-failed-move-restores-layout-and-choice ()
  "A failed split cannot destroy the pane or leave a failed override set."
  (major-pane-layout-test--with-layout
    (let* ((major-pane-direction 'left)
           (main (selected-window))
           (pane (major-pane-display-buffer-action chat nil))
           (edges (window-edges pane)))
      ;; Inject the actual boundary failure: Emacs declines a split.
      (cl-letf (((symbol-function 'display-buffer-in-direction) (lambda (&rest _) nil)))
        (should-error (major-pane-set-placement 'below) :type 'user-error))
      (should (eq (selected-window) main))
      (should (equal (window-edges (get-buffer-window chat)) edges))
      (should (window-dedicated-p (get-buffer-window chat)))
      (should-not (frame-parameter nil 'major-pane-placement)))))

(ert-deftest major-pane-layout-gui-frame-overrides-and-home ()
  "Real GUI frames keep independent choices as the pane roams or is locked."
  (skip-unless (display-graphic-p))
  (let ((frames nil)
        (chat (generate-new-buffer " *layout-gui-chat*"))
        (major-pane--state (major-pane--make-state))
        (major-pane-home-frame nil)
        (major-pane-direction 'auto)
        (display-buffer-alist nil)
        (display-buffer-overriding-action nil)
        (display-buffer-base-action nil))
    (unwind-protect
        (save-selected-window
          (let* ((wide (make-frame '((name . "layout-test-wide") (visibility . nil)
                                    (width . 120) (height . 30))))
                 (_ (push wide frames))
                 (tall (make-frame '((name . "layout-test-tall") (visibility . nil)
                                    (width . 60) (height . 90)))))
            (push tall frames)
            (setf (major-pane-state-conversations major-pane--state) (list chat)
                  (major-pane-state-active major-pane--state) chat)
            ;; Restrict the global pane scan to frames owned by this test.
            (cl-letf (((symbol-function 'major-pane--all-windows)
                       (lambda () (apply #'append
                                         (mapcar (lambda (f) (window-list f 'nomini)) frames)))))
              (with-selected-frame wide
                (should (< (frame-pixel-height) (frame-pixel-width)))
                (major-pane-display-buffer-action chat nil)
                (major-pane-set-placement 'below))
              (with-selected-frame tall
                (should (> (frame-pixel-height) (frame-pixel-width)))
                (let* ((main (selected-window))
                       (pane (major-pane-display-buffer-action chat nil)))
                  (major-pane-layout-test--assert-edge pane main 'above)
                  (major-pane-set-placement 'right)))
              (with-selected-frame wide
                (let* ((main (selected-window))
                       (pane (major-pane-display-buffer-action chat nil)))
                  (major-pane-layout-test--assert-edge pane main 'below)
                  (major-pane-set-placement 'auto)
                  (major-pane-layout-test--assert-edge (get-buffer-window chat wide) main 'left)
                  ;; Actual frame resize, without faking pixel dimensions.
                  (set-frame-size wide 60 90)
                  (run-hook-with-args 'window-size-change-functions wide)
                  (major-pane-layout-test--assert-edge (get-buffer-window chat wide) main 'above)))
              ;; Home routing must use the home frame's override, not the caller's.
              (setq major-pane-home-frame wide)
              (with-selected-frame tall
                (should (eq (major-pane--effective-direction) 'right))
                (let ((pane (major-pane--display chat)))
                  (should (eq (window-frame pane) wide))
                  (should (eq (window-parameter pane 'major-pane-direction) 'above)))))))
      (dolist (f frames) (when (frame-live-p f) (delete-frame f t)))
      (kill-buffer chat))))

(provide 'major-pane-layout-test)
;;; major-pane-layout-test.el ends here
