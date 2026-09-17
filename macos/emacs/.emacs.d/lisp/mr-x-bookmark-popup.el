;;; mr-x-bookmark-popup.el --- System-wide bookmark picker -*- lexical-binding: t; -*-

;; A temporary minibuffer-only frame, inspired by Xenodium's bookmark launcher.
;; Hammerspoon invokes this command; yabai exempts its title from tiling.

(require 'bookmark)
(require 'seq)
(require 'subr-x)

(defvar vertico-count)
(defvar vertico-resize)
(defvar mr-x/bookmark-popup-frame nil
  "The current bookmark picker frame, or nil.")

(defun mr-x/bookmark-popup (&optional workarea)
  "Pick a live bookmark in a floating frame, then close that frame.
Optional WORKAREA is (X Y WIDTH HEIGHT) in screen pixels, supplied by
Hammerspoon for the invoking screen.  Use normal bookmark handlers so
URLs, files, and directories retain their existing behavior.
Return `opened' or `cancelled' for the external launcher."
  (interactive)
  (when (or (frame-live-p mr-x/bookmark-popup-frame)
            (active-minibuffer-window))
    (user-error "Finish the current minibuffer before opening bookmarks"))
  (bookmark-maybe-load-default-file)
  (unless bookmark-alist (user-error "No named bookmarks saved yet"))
  (let* ((origin (selected-frame))
         (popup (make-frame
                 '((window-system . ns)
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
          (when (frame-live-p popup) (delete-frame popup t))
          (setq mr-x/bookmark-popup-frame nil)
          (when (frame-live-p origin) (select-frame origin)))
      (quit (setq choice nil)))
    (if (or (null choice) (string-empty-p choice))
        'cancelled
      ;; The chosen buffer must belong to a lasting frame, never the picker.
      (unless (display-graphic-p)
        (select-frame-set-input-focus (make-frame '((window-system . ns)))))
      (bookmark-jump choice)
      'opened)))

(provide 'mr-x-bookmark-popup)
;;; mr-x-bookmark-popup.el ends here
