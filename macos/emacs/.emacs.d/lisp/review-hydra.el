;;; review-hydra.el --- Mode hydra for review panes and files -*- lexical-binding: t; -*-
(require 'hydra)
(require 'review-panel)

(defun review-hydra--focus (window)
  "Select WINDOW and its frame."
  (unless (window-live-p window) (user-error "Review window is not available"))
  (select-frame-set-input-focus (window-frame window))
  (select-window window))

(defun review-hydra-files ()
  "Focus this review's files panel."
  (interactive)
  (let ((s (review-session--require)))
    (review-panel--refresh s)
    (review-hydra--focus (get-buffer-window (review-session-panel s) t))))

(defun review-hydra-old ()
  "Focus the old source pane."
  (interactive)
  (review-hydra--focus (review-session-old-window (review-session--require))))

(defun review-hydra-new ()
  "Focus the new source pane."
  (interactive)
  (review-hydra--focus (review-session-new-window (review-session--require))))

(defun review-hydra-fold ()
  "Fold the file at point in the panel, or the current compared file."
  (interactive)
  (let ((s (review-session--require)))
    (if (derived-mode-p 'review-panel-mode)
        (review-panel-fold)
      (with-current-buffer (review-session-panel s)
        (save-excursion
          (goto-char (or (text-property-any (point-min) (point-max)
                                            'review-file (review-session-current s))
                         (point-min)))
          (review-panel-fold))))))

(defun review-hydra-strip ()
  "Toggle the files panel's compact strip from either review surface."
  (interactive)
  (let ((s (review-session--require)))
    (with-current-buffer (review-session-panel s)
      (setq review-panel--collapsed (not review-panel--collapsed)))
    (review-panel--refresh s)))

(defhydra hydra-review (:hint nil :foreign-keys run)
  "
 Review session
 Files               Hunks               View / ask
 _C-j_: next file     _M-j_: next hunk     _f_: files panel
 _C-k_: prev file     _M-k_: prev hunk     _o_: old pane   _w_: new pane
 _v_: viewed        _TAB_: fold       _a_: Quick Ask  _u_: park
                   _z_: strip
 _Q_: quit review                    _q_: quit hydra"
  ("C-j" review-session-next-file)
  ("C-k" review-session-prev-file)
  ("M-j" review-session-next-hunk)
  ("M-k" review-session-prev-hunk)
  ("v" review-session-toggle-viewed)
  ("TAB" review-hydra-fold)
  ("z" review-hydra-strip)
  ("f" review-hydra-files :exit t)
  ("o" review-hydra-old :exit t)
  ("w" review-hydra-new :exit t)
  ("a" mr-x/quick-ask :exit t)
  ("u" syzygy-park :exit t)
  ("Q" review-session-quit :exit t)
  ("q" nil :exit t))

(provide 'review-hydra)
