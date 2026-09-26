;;; mr-x-jump-back.el --- One global back/forward history across windows -*- lexical-binding: t; -*-

;;; Commentary:

;; Evil's jump list is per window and ignores buffers without a file, so
;; `C-o' from an agent-shell window cannot return to the file window you
;; came from.  This keeps ONE history for the whole session.  Each entry
;; remembers the window and position, and going back re-selects that
;; window when it is still live.
;;
;; Recorded:
;;   - any command that changes the selected window or its buffer
;;   - any command that moves point `mr-x-jump-back-min-lines' or more
;;     in one go, except scrolling and line-by-line motion
;;   - any evil jump inside a buffer (G, gg, /, n, %, ...)
;;
;; `mr-x-jump-back-mode' installs the hooks.  Bind `mr-x/jump-back' and
;; `mr-x/jump-forward' yourself.

;;; Code:

(require 'cl-lib)

(defvar mr-x-jump-back-max 100
  "Maximum number of entries kept in the history.")

(defvar mr-x-jump-back--list nil
  "History entries, newest first.  Each is (WINDOW . MARKER).")

(defvar mr-x-jump-back--index -1
  "Position in `mr-x-jump-back--list' while navigating, -1 when not.")

(defvar mr-x-jump-back--pre nil
  "(WINDOW BUFFER MARKER) captured before the current command.")

(defvar mr-x-jump-back-min-lines 10
  "A command that moves point at least this many lines in one go is a jump.")

(defvar mr-x-jump-back-ignored-commands-regexp
  "scroll\\|next-line\\|previous-line\\|mwheel\\|mouse\\|self-insert\\|recenter"
  "Commands matching this regexp never count as a far jump.
Scrolling and line-by-line motion move far without meaning to jump.")

(defconst mr-x-jump-back--commands '(mr-x/jump-back mr-x/jump-forward)
  "Commands that navigate the history and must not record into it.")

(defun mr-x-jump-back--recordable-p (window buffer)
  "Non-nil when WINDOW showing BUFFER is worth recording."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))))

(defun mr-x-jump-back--same-place-p (entry window marker)
  "Non-nil when ENTRY is WINDOW at MARKER's line."
  (let ((m (cdr entry)))
    (and (eq (car entry) window)
         (eq (marker-buffer m) (marker-buffer marker))
         (with-current-buffer (marker-buffer marker)
           (= (line-number-at-pos m) (line-number-at-pos marker))))))

(defun mr-x-jump-back--record (window marker)
  "Push WINDOW at MARKER as the newest entry.
A new record while navigating drops the entries ahead of the index,
like a browser history."
  (when (mr-x-jump-back--recordable-p window (marker-buffer marker))
    (when (> mr-x-jump-back--index 0)
      (setq mr-x-jump-back--list
            (nthcdr mr-x-jump-back--index mr-x-jump-back--list)))
    (setq mr-x-jump-back--index -1)
    (unless (and mr-x-jump-back--list
                 (mr-x-jump-back--same-place-p
                  (car mr-x-jump-back--list) window marker))
      (push (cons window marker) mr-x-jump-back--list)
      (when (> (length mr-x-jump-back--list) mr-x-jump-back-max)
        (setq mr-x-jump-back--list
              (seq-take mr-x-jump-back--list mr-x-jump-back-max))))))

(defun mr-x-jump-back--pre-command ()
  "Remember where point is before each command."
  (setq mr-x-jump-back--pre
        (unless (memq this-command mr-x-jump-back--commands)
          (let ((win (selected-window)))
            (list win (window-buffer win) (point-marker))))))

(defun mr-x-jump-back--post-command ()
  "Record the pre-command place when the command changed window or
buffer, or moved point far inside the same buffer (like a jump from a
transcript up to the prompt)."
  (when-let* ((pre mr-x-jump-back--pre))
    (setq mr-x-jump-back--pre nil)
    (let ((win (nth 0 pre))
          (buf (nth 1 pre))
          (m (nth 2 pre))
          (now (selected-window)))
      (when (and (not (window-minibuffer-p now))
                 (or (not (eq win now))
                     (not (eq buf (window-buffer now)))
                     (mr-x-jump-back--far-move-p m)))
        (mr-x-jump-back--record win m)))))

(defun mr-x-jump-back--far-move-p (marker)
  "Non-nil when the command just run moved point far from MARKER.
MARKER is in the current buffer."
  (and (eq (marker-buffer marker) (current-buffer))
       (not (and (symbolp this-command)
                 (string-match-p mr-x-jump-back-ignored-commands-regexp
                                 (symbol-name this-command))))
       (>= (count-lines marker (point)) mr-x-jump-back-min-lines)))

(defun mr-x-jump-back--evil-set-jump (&optional pos)
  "Also record same-buffer evil jumps (G, /, %).  POS as in `evil-set-jump'.
Buffer crossings are left to the post-command hook, which knows the
right window."
  (unless (memq this-command mr-x-jump-back--commands)
    (let ((m (if (markerp pos) pos (copy-marker (or pos (point))))))
      (when (eq (marker-buffer m) (window-buffer (selected-window)))
        (mr-x-jump-back--record (selected-window) (copy-marker m))))))

(defun mr-x-jump-back--visit (entry)
  "Go to ENTRY, selecting its window when it is still live."
  (let* ((win (car entry))
         (m (cdr entry))
         (buf (marker-buffer m)))
    (cond ((window-live-p win) (select-window win))
          ((get-buffer-window buf) (select-window (get-buffer-window buf))))
    (unless (eq (window-buffer) buf)
      (switch-to-buffer buf nil t))
    (goto-char m)))

(defun mr-x-jump-back--valid-p (entry)
  "Non-nil when ENTRY's buffer still exists."
  (buffer-live-p (marker-buffer (cdr entry))))

(defun mr-x-jump-back--here-p (entry)
  "Non-nil when ENTRY is where point is now."
  (mr-x-jump-back--same-place-p entry (selected-window) (point-marker)))

(defun mr-x/jump-back (&optional count)
  "Go back COUNT places in the global history, across windows."
  (interactive "p")
  (dotimes (_ (or count 1))
    (when (= mr-x-jump-back--index -1)
      ;; Save where we are so `mr-x/jump-forward' can return here.
      (mr-x-jump-back--record (selected-window) (point-marker))
      (setq mr-x-jump-back--index 0))
    (let ((i (1+ mr-x-jump-back--index))
          (n (length mr-x-jump-back--list)))
      (while (and (< i n)
                  (let ((e (nth i mr-x-jump-back--list)))
                    (or (not (mr-x-jump-back--valid-p e))
                        (mr-x-jump-back--here-p e))))
        (setq i (1+ i)))
      (if (>= i n)
          (message "No earlier place")
        (setq mr-x-jump-back--index i)
        (mr-x-jump-back--visit (nth i mr-x-jump-back--list))))))

(defun mr-x/jump-forward (&optional count)
  "Go forward COUNT places after `mr-x/jump-back'."
  (interactive "p")
  (dotimes (_ (or count 1))
    (let ((i (1- mr-x-jump-back--index)))
      (while (and (>= i 0)
                  (not (mr-x-jump-back--valid-p (nth i mr-x-jump-back--list))))
        (setq i (1- i)))
      (if (< i 0)
          (message "No later place")
        (setq mr-x-jump-back--index i)
        (mr-x-jump-back--visit (nth i mr-x-jump-back--list))))))

;;;###autoload
(define-minor-mode mr-x-jump-back-mode
  "Keep one back/forward place history across all windows."
  :global t
  :group 'convenience
  (if mr-x-jump-back-mode
      (progn
        (add-hook 'pre-command-hook #'mr-x-jump-back--pre-command)
        (add-hook 'post-command-hook #'mr-x-jump-back--post-command)
        (with-eval-after-load 'evil-jumps
          (advice-add 'evil-set-jump :before #'mr-x-jump-back--evil-set-jump)))
    (remove-hook 'pre-command-hook #'mr-x-jump-back--pre-command)
    (remove-hook 'post-command-hook #'mr-x-jump-back--post-command)
    (advice-remove 'evil-set-jump #'mr-x-jump-back--evil-set-jump)))

(provide 'mr-x-jump-back)
;;; mr-x-jump-back.el ends here
