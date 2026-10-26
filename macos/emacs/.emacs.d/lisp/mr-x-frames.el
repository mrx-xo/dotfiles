;;; mr-x-frames.el --- Stable main-frame identity -*- lexical-binding: t; -*-

;;; Commentary:
;; The oldest real graphical editor is main until it closes.  Registration
;; covers make-frame as well as server clients, and excludes child/TTY frames.
;; Loading this file repairs an existing session without selecting a frame.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defvar mr-x/main-frame nil
  "The registered main graphical editing frame.
Its identity survives buffer switches, new clients and live reloads.")

(defvar mr-x/frame-counter 0
  "Counter used to title secondary client frames.")

(defconst mr-x/auxiliary-frame-names
  '("Review diff" "Review files" "Agent Shell Manager")
  "Creation names/titles of existing dedicated helper frames.
Other helper constructors can opt out with `mr-x-auxiliary-frame'.")

;; Establish the binding before the deferred package loads.  Its defvar
;; then preserves the home selected here instead of initializing it to nil.
(defvar major-pane-home-frame nil)
(defvar major-pane-launcher-buffer-name)

(declare-function major-pane--pane-window "major-pane")
(declare-function major-pane--find-buffer "major-pane")
(declare-function major-pane--show-launcher "major-pane")
(declare-function major-pane--select-window "major-pane" (window))
(declare-function major-pane-display-buffer-action "major-pane" (buffer alist))

(defun mr-x/main-frame-eligible-p (frame)
  "Whether FRAME is a live graphical editor, rather than a popup or terminal."
  (and (frame-live-p frame)
       (display-graphic-p frame)
       (not (frame-parent frame))
       (not (frame-parameter frame 'tooltip))
       (not (eq (frame-parameter frame 'minibuffer) 'only))
       (not (frame-parameter frame 'mr-x-auxiliary-frame))
       ;; These stable creation labels cover helpers before their owners
       ;; store frame references, and existing frames without a role marker.
       (not (member (frame-parameter frame 'name) mr-x/auxiliary-frame-names))
       (not (member (frame-parameter frame 'title) mr-x/auxiliary-frame-names))))

(defun mr-x/initialize-main-frame (&optional excluding)
  "Register main and bind the pane home, without changing focus.
Keep the registered frame when live; otherwise use the oldest eligible
frame.  EXCLUDING is a frame about to be deleted (still live in the
deletion hook).  Return the main frame, or nil if no editor remains."
  (let ((main (if (and (not (eq mr-x/main-frame excluding))
                       (mr-x/main-frame-eligible-p mr-x/main-frame))
                  mr-x/main-frame
                ;; Cocoa prepends newly created frames to frame-list.
                (car (last (seq-filter
                            (lambda (frame)
                              (and (not (eq frame excluding))
                                   (mr-x/main-frame-eligible-p frame)))
                            (frame-list)))))))
    (setq mr-x/main-frame main
          major-pane-home-frame main)
    ;; Repair stale markers too, including those on ineligible frames.
    (dolist (frame (frame-list))
      (when (frame-parameter frame 'mr-x-main-frame)
        (set-frame-parameter frame 'mr-x-main-frame nil)))
    (when main
      (set-frame-parameter main 'mr-x-main-frame t)
      (set-frame-parameter main 'undecorated-round t)
      (set-frame-parameter main 'title nil)
      (set-frame-parameter main 'background-color "#1d2021"))
    main))

(defun mr-x/register-frame (frame)
  "Register a newly created editing FRAME, keeping an existing main."
  (when (mr-x/main-frame-eligible-p frame)
    (unless (mr-x/main-frame-eligible-p mr-x/main-frame)
      (mr-x/initialize-main-frame))
    (set-frame-parameter frame 'mr-x-main-frame (eq frame mr-x/main-frame))))

(defun mr-x/decorate-secondary-frame ()
  "Give secondary client frames stable numbered titles; leave main clean."
  (let ((frame (selected-frame)))
    (when (mr-x/main-frame-eligible-p frame)
      (mr-x/register-frame frame)
      (unless (eq frame mr-x/main-frame)
        (let ((number (or (frame-parameter frame 'mr-x-frame-number)
                          (cl-incf mr-x/frame-counter))))
          (set-frame-parameter frame 'mr-x-frame-number number)
          (set-frame-parameter frame 'undecorated-round nil)
          (set-frame-parameter frame 'title (format "Emacs #%d" number)))))))

(defun mr-x/main-frame-deleted (frame)
  "Replace FRAME if it is main, excluding it before Emacs removes it."
  (when (eq frame mr-x/main-frame)
    (mr-x/initialize-main-frame frame)))

(defun mr-x/focus-ai-window ()
  "Show and focus the existing AI pane on the main editing frame.
Preserve its active conversation regardless of the caller's project.
When no conversations exist, focus the launcher instead."
  (interactive)
  (unless (mr-x/main-frame-eligible-p mr-x/main-frame)
    (mr-x/initialize-main-frame))
  (unless mr-x/main-frame
    (user-error "No graphical main editing frame available"))
  (require 'major-pane)
  (setq major-pane-home-frame mr-x/main-frame)
  (let ((window
         (with-selected-frame mr-x/main-frame
           (let ((pane (major-pane--pane-window))
                 (buffer (major-pane--find-buffer)))
             (cond
              ((and (window-live-p pane)
                    (eq (window-frame pane) mr-x/main-frame)
                    (eq (window-buffer pane) buffer))
               pane)
              ((buffer-live-p buffer)
               (major-pane-display-buffer-action buffer nil))
              (t
               (or (get-buffer-window major-pane-launcher-buffer-name
                                      mr-x/main-frame)
                   (major-pane--show-launcher))))))))
    ;; Select only after with-selected-frame restores the caller, so the
    ;; helper also raises main and gives it macOS keyboard focus.
    (when (window-live-p window)
      (major-pane--select-window window))))

(add-hook 'after-make-frame-functions #'mr-x/register-frame)
(add-hook 'server-after-make-frame-hook #'mr-x/decorate-secondary-frame)
(add-hook 'delete-frame-functions #'mr-x/main-frame-deleted)
(add-hook 'window-setup-hook #'mr-x/initialize-main-frame)
(mr-x/initialize-main-frame)

(provide 'mr-x-frames)
;;; mr-x-frames.el ends here
