;;; mr-x-bookmark-popup.el --- System-wide bookmark picker -*- lexical-binding: t; -*-

;; A temporary minibuffer-only frame, inspired by Xenodium's bookmark launcher.
;; Hammerspoon invokes this command; yabai exempts its title from tiling.

(require 'bookmark)
(require 'seq)
(require 'subr-x)

;; Marginalia otherwise derives the implementation name "Bmkp-Dired".
(put 'bmkp-jump-dired 'bookmark-handler-type "Dired")

(defvar vertico-count)
(defvar vertico-resize)
(defvar mr-x/bookmark-popup-frame nil
  "The current bookmark picker frame, or nil.")

(defun mr-x/bookmark-popup--local-frame-p (frame)
  "Return non-nil when FRAME is an ordinary Mac window."
  (and (frame-live-p frame)
       (eq (framep frame) 'ns)
       (not (eq (frame-parameter frame 'device) 'calliope))
       (not (frame-parameter frame 'parent-frame))
       (not (eq (frame-parameter frame 'minibuffer) 'only))))

(defun mr-x/bookmark-popup--local-frame ()
  "Choose an ordinary Mac frame, creating one only when none exists."
  (or (and (mr-x/bookmark-popup--local-frame-p (selected-frame))
           (selected-frame))
      (seq-find #'mr-x/bookmark-popup--local-frame-p (frame-list))
      (make-frame '((window-system . ns) (client . nil)))))

(defun mr-x/bookmark-popup--display-buffer (buffer frame)
  "Display BUFFER inside FRAME without reusing any other frame.
Preserve dedicated panes; split locally if no ordinary window is free."
  (unless (mr-x/bookmark-popup--local-frame-p frame)
    (user-error "The bookmark destination window was closed"))
  (let ((window
         (or (get-buffer-window buffer frame)
             (seq-find (lambda (w)
                         (and (not (window-dedicated-p w))
                              (not (window-parameter w 'window-side))))
                       (window-list frame 'no-minibuffer))
             (let ((new (split-window (frame-root-window frame) nil 'right)))
               (set-window-dedicated-p new nil)
               new))))
    (set-window-buffer window buffer)
    window))

(defun mr-x/bookmark-popup (&optional workarea)
  "Pick a live bookmark in a floating frame, then close that frame.
Optional WORKAREA is (X Y WIDTH HEIGHT) in screen pixels, supplied by
Hammerspoon for the invoking screen.  Use normal bookmark handlers so
URLs, files, and directories retain their existing behavior.  The picker
and its destinations stay on the Mac, never a terminal or Calliope frame.
Return `opened' or `cancelled' for the external launcher."
  (interactive)
  (when (or (frame-live-p mr-x/bookmark-popup-frame)
            (active-minibuffer-window))
    (user-error "Finish the current minibuffer before opening bookmarks"))
  (bookmark-maybe-load-default-file)
  (unless bookmark-alist (user-error "No named bookmarks saved yet"))
  (let* ((origin (mr-x/bookmark-popup--local-frame))
         ;; Frame creation hooks must also originate on the Mac.
         (_ (select-frame origin))
         (popup (make-frame
                 '((window-system . ns)
                   ;; Do not inherit the originating emacsclient's startup
                   ;; behavior: Perspective would show fetch in another
                   ;; frame because this one has no ordinary window.
                   (client . nil)
                   (name . "Emacs Bookmark Picker")
                   (title . "Emacs Bookmark Picker")
                   (minibuffer . only)
                   (width . 86) (height . 15)
                   (visibility . nil)
                   (undecorated . t) (undecorated-round . t)
                   (internal-border-width . 18)
                   (left-fringe . 0) (right-fringe . 0)
                   (menu-bar-lines . 0) (tool-bar-lines . 0)
                   (vertical-scroll-bars . nil)
                   (unsplittable . t) (skip-taskbar . t))))
         (vertico-count 11)
         (vertico-resize nil)
         (resize-mini-frames nil)
         choice)
    (setq mr-x/bookmark-popup-frame popup)
    (condition-case nil
        (unwind-protect
            (progn
              (pcase-let ((`(,x ,y ,width ,height)
                           (or workarea
                               (alist-get 'workarea (frame-monitor-attributes popup)))))
                ;; (+ N) preserves absolute negative coordinates on monitors
                ;; above or left of the main screen.
                (modify-frame-parameters
                 popup
                 `((left . (+ ,(+ x (max 0 (/ (- width (frame-pixel-width popup)) 2)))))
                   (top . (+ ,(+ y (max 0 (/ (- height (frame-pixel-height popup)) 3))))))))
              (make-frame-visible popup)
              (select-frame-set-input-focus popup)
              (setq choice
                    (completing-read
                     "Bookmark: "
                     (lambda (string pred action)
                       (if (eq action 'metadata)
                           '(metadata (category . bookmark))
                         (complete-with-action action bookmark-alist string pred)))
                     nil t nil 'bookmark-history)))
          ;; Choose the Mac before deleting its picker, so Emacs need not
          ;; select a terminal as the replacement for the deleted frame.
          (unless (mr-x/bookmark-popup--local-frame-p origin)
            (setq origin (mr-x/bookmark-popup--local-frame)))
          (select-frame origin)
          (when (frame-live-p popup)
            ;; This transient frame owns no workspace.  Perspective's normal
            ;; teardown cycles buffers via other frames, including terminals.
            (let ((delete-frame-functions
                   (remq 'persp-delete-frame delete-frame-functions)))
              (delete-frame popup t)))
          (setq mr-x/bookmark-popup-frame nil))
      (quit (setq choice nil)))
    (if (or (null choice) (string-empty-p choice))
        'cancelled
      (unless (mr-x/bookmark-popup--local-frame-p origin)
        (setq origin (mr-x/bookmark-popup--local-frame)))
      (select-frame-set-input-focus origin)
      ;; Override cross-frame fallback, including when the Mac's selected
      ;; window is dedicated or the buffer is already visible on Calliope.
      (let ((display-buffer-overriding-action
             (list (list (lambda (buffer _alist)
                           (mr-x/bookmark-popup--display-buffer buffer origin))))))
        (bookmark-jump choice))
      'opened)))

(provide 'mr-x-bookmark-popup)
;;; mr-x-bookmark-popup.el ends here
