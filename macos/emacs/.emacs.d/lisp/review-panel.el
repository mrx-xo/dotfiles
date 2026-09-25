;;; review-panel.el --- The files panel beside a review session -*- lexical-binding: t; -*-
;;; Commentary:
;; Drawn from Figma file FCZk2pGQidWPYfSWzu4qUk, page "PR review (Emacs)":
;; "Files panel / expanded (default)" and "Files strip / collapsed".
;; Design pixels are scaled to the frame font (Iosevka at 12 px is 6 px
;; wide), so spacing keeps the design's proportions at any font size.
;; The panel re-renders from the session on `review-session-update-hook'
;; and never holds state the session has.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'review-session)

(defcustom review-panel-width 70
  "Columns for the expanded panel: the design's 420 px at 6 px per character."
  :type 'integer :group 'review)
(defcustom review-panel-strip-width 7 "Columns for the collapsed strip." :type 'integer :group 'review)
(defcustom review-panel-pop-out t
  "Open new reviews' file panels in their own graphical frames.
When nil, attach the panel to the compare frame's left side.
Independent of `review-session-pop-out'; terminals always use a side window."
  :type 'boolean :group 'review)

(defcustom review-panel-palette
  '((bg-hard . "#1d2021") (bg-0 . "#282828") (bg-1 . "#3c3836") (bg-2 . "#504945")
    (fg . "#ebdbb2") (dim . "#a89984") (mute . "#928374")
    (orange . "#fe8019") (yellow . "#fabd2f") (green . "#b8bb26") (red . "#fb4934"))
  "Gruvbox tokens of the panel's Figma design."
  :type '(alist :key-type symbol :value-type color) :group 'review)

(defvar-local review-panel--session nil)
(defvar-local review-panel--toggled nil
  "Files whose hunk list is flipped: the current file shows its hunks
unless toggled; any other file shows them only when toggled.")
(defvar-local review-panel--collapsed nil "Non-nil when shown as the strip.")
(defvar-local review-panel--render-width nil "Width used by the last render.")
(defvar review-panel--refreshing nil)
(defvar review-panel--scale 1.0 "Screen pixels per design pixel during a render.")

;;;; Design primitives

(defun review-panel--hex (token &optional faded)
  "Palette TOKEN's colour; FADED blends it like the design's 62% opacity."
  (let ((hex (alist-get token review-panel-palette)))
    (if (not faded) hex
      (let ((bg (alist-get 'bg-hard review-panel-palette)))
        (apply #'format "#%02x%02x%02x"
               (cl-loop for i in '(1 3 5)
                        collect (round (+ (* 0.62 (string-to-number (substring hex i (+ i 2)) 16))
                                          (* 0.38 (string-to-number (substring bg i (+ i 2)) 16))))))))))

(cl-defun review-panel--txt (text token &key faded weight height)
  "TEXT in palette TOKEN's colour."
  (propertize text 'face `(:foreground ,(review-panel--hex token faded)
                           ,@(and weight `(:weight ,weight))
                           ,@(and height `(:height ,height)))))

(defun review-panel--px (design)
  "Screen pixels for DESIGN pixels."
  (max 1 (round (* design review-panel--scale))))

(defun review-panel--gap (design)
  "Horizontal space of DESIGN pixels."
  (propertize " " 'display `(space :width (,(review-panel--px design)))))

(defun review-panel--pixels (string)
  "Estimated pixel width of STRING: pixel spaces plus scaled characters.
Computed rather than measured, so batch tests and frames agree."
  (let ((cw (frame-char-width)) (px 0.0))
    (dotimes (i (length string))
      (let* ((display (get-text-property i 'display string))
             (width (and (eq (car-safe display) 'space) (plist-get (cdr display) :width)))
             (face (get-text-property i 'face string))
             (height (or (and (consp face) (keywordp (car face))
                              (numberp (plist-get face :height)) (plist-get face :height))
                         1.0)))
        (setq px (+ px (if (consp width) (car width)
                         (* cw height (char-width (aref string i))))))))
    (round px)))

(defun review-panel--flush (left right &optional width pad)
  "LEFT, then RIGHT ending PAD design pixels (default 16) from the edge.
When both do not fit in WIDTH columns, RIGHT is dropped rather than
drawn over LEFT."
  (let ((edge (+ (review-panel--px (or pad 16)) (review-panel--pixels right))))
    (if (and width (> (+ (review-panel--pixels left) edge (review-panel--px 10))
                      (* width (frame-char-width))))
        left
      (concat left (propertize " " 'display `(space :align-to (- right (,edge)))) right))))

(defun review-panel--center (text)
  "TEXT centred in the window."
  (concat (propertize " " 'display
                      `(space :align-to (- center (,(/ (review-panel--pixels text) 2)))))
          text))

(cl-defun review-panel--row (content &key bg pad (factor 1.0) props)
  "CONTENT as one line.  BG fills to the edge; PAD is (TOP BOTTOM) design px.
FACTOR is the tallest text height on the line, relative to the frame font."
  (let ((line (concat content "\n")))
    (when bg
      (add-face-text-property 0 (length line)
                              `(:background ,(review-panel--hex bg) :extend t) t line))
    (when pad
      (let ((text (round (* factor (frame-char-height))))
            (top (review-panel--px (car pad))))
        (put-text-property (1- (length line)) (length line) 'line-height
                           (list (+ text top) (+ text top (review-panel--px (cadr pad))))
                           line)))
    (when props (add-text-properties 0 (length line) props line))
    line))

(defun review-panel--spacer (design)
  "An empty line DESIGN pixels tall."
  (propertize " \n" 'face '(:height 0.1) 'line-height (review-panel--px design)))

(defun review-panel--divider ()
  "A hairline across the panel, like the design's 1 px divider."
  (propertize " \n" 'face `(:background ,(review-panel--hex 'bg-1) :height 0.1 :extend t)))

(defun review-panel--status (state &optional height)
  "The design's icon for STATE: viewed, current or pending."
  (pcase state
    ('viewed (review-panel--txt "●" 'green :faded t :height height))
    ('current (review-panel--txt "❯" 'orange :height height))
    (_ (review-panel--txt "○" 'mute :height height))))

(defun review-panel--mode-label (mode)
  "Short label for a content-unchanged file with MODE (OLD . NEW)."
  (if (not mode) "no changes"
    (let ((old (logand #o111 (string-to-number (car mode) 8)))
          (new (logand #o111 (string-to-number (cdr mode) 8))))
      (cond ((and (zerop old) (not (zerop new))) "mode +x")
            ((and (not (zerop old)) (zerop new)) "mode -x")
            (t "mode")))))

(defun review-panel--kind (file faded)
  (pcase-let ((`(,letter . ,token) (pcase (plist-get file :kind)
                                     ('added '("A" . green)) ('deleted '("D" . red))
                                     ('renamed '("R" . orange)) (_ '("M" . yellow)))))
    (review-panel--txt letter token :faded faded :weight 'bold :height 0.92)))

(defun review-panel--tally (rows)
  "(ADDED . DELETED) among ROWS."
  (cons (cl-count-if (lambda (r) (memq (plist-get r :kind) '(add both))) rows)
        (cl-count-if (lambda (r) (memq (plist-get r :kind) '(del both))) rows)))

(defun review-panel--counts (counts faded height)
  "COUNTS as green +N and red -N, omitting zeros."
  (string-join
   (delq nil (list (and (> (car counts) 0)
                        (review-panel--txt (format "+%d" (car counts)) 'green :faded faded :height height))
                   (and (> (cdr counts) 0)
                        (review-panel--txt (format "-%d" (cdr counts)) 'red :faded faded :height height))))
   (review-panel--gap 6)))

(defun review-panel--room (width used-px height)
  "Columns of HEIGHT-scaled text left in WIDTH columns after USED-PX pixels."
  (let ((cw (frame-char-width)))
    (max 0 (floor (/ (- (* width cw) used-px) (* cw height))))))

(defun review-panel--fit-path (path room)
  "Split PATH into (DIR . NAME) fitting ROOM columns.
The file name wins: whole folders are dropped from the left behind
\"…/\", and the name itself is cut at its end only when no folder fits."
  (let* ((dir (or (file-name-directory path) ""))
         (name (file-name-nondirectory path))
         (dir-room (- room (string-width name))))
    (cond
     ((<= (string-width dir) dir-room) (cons dir name))
     ((< dir-room 2) (cons "" (truncate-string-to-width name room nil nil "…")))
     (t (let ((kept "") (full t))
          (dolist (part (reverse (split-string dir "/" t)))
            (let ((next (concat part "/" kept)))
              (if (and full (<= (+ 2 (string-width next)) dir-room))
                  (setq kept next)
                (setq full nil))))
          (cons (concat "…/" kept) name))))))

;;;; Sections

(defun review-panel--header (session width)
  (let* ((source (review-session-source session))
         (number (review-source-number source))
         (lead (concat (review-panel--gap 16)
                       (if number
                           (concat (review-panel--txt (format "#%d" number) 'orange
                                                      :weight 'bold :height 1.08)
                                   (review-panel--gap 8))
                         "")))
         (room (review-panel--room width (+ (review-panel--pixels lead) (review-panel--px 16)) 1.17))
         (title (truncate-string-to-width (or (review-source-title source) "") room nil nil "…"))
         (subtitle (or (review-source-subtitle source) (review-source-range-label source))))
    (concat
     (review-panel--row (concat lead (review-panel--txt title 'fg :weight 'bold :height 1.17))
                        :bg 'bg-0 :pad '(14 2) :factor 1.17 :props '(review-header t))
     (review-panel--row (concat (review-panel--gap 16)
                                (review-panel--txt (truncate-string-to-width
                                                    subtitle (review-panel--room width (review-panel--px 32) 0.92)
                                                    nil nil "…")
                                                   'dim :height 0.92))
                        :bg 'bg-0 :pad '(2 12) :props '(review-header t)))))

(defun review-panel--bar (viewed total width)
  "The design's 3 px progress bar: yellow fill on a dark track."
  (let* ((track (max 0 (- (* width (frame-char-width)) (* 2 (review-panel--px 16)))))
         (fill (if (zerop total) 0 (round (* track (/ (float viewed) total))))))
    (concat (propertize " " 'display `(space :width (,(review-panel--px 16))) 'face '(:height 0.2))
            (propertize " " 'display `(space :width (,fill))
                        'face `(:background ,(review-panel--hex 'yellow) :height 0.2))
            (propertize " " 'display `(space :align-to (- right (,(review-panel--px 16))))
                        'face `(:background ,(review-panel--hex 'bg-1) :height 0.2))
            (propertize "\n" 'face '(:height 0.2) 'review-header t))))

(defun review-panel--progress (session width expanded)
  "Viewed count, totals, the hunk position when EXPANDED, and the bar."
  (let* ((files (append (review-session-files session) nil))
         (index (review-session-current session))
         (progress (review-session-progress session))
         (totals (cl-reduce (lambda (acc file)
                              (if-let ((rows (plist-get file :rows)))
                                  (let ((c (review-panel--tally rows)))
                                    (cons (+ (car acc) (car c)) (+ (cdr acc) (cdr c))))
                                acc))
                            files :initial-value '(0 . 0)))
         (hunks (plist-get (nth index files) :hunks))
         (hunk (review-session-hunk session))
         (all (apply #'+ (mapcar (lambda (f) (length (plist-get f :hunks))) files)))
         (before (apply #'+ (mapcar (lambda (f) (length (plist-get f :hunks)))
                                    (cl-subseq files 0 index))))
         (lead (review-panel--gap 16)))
    (concat
     (review-panel--row
      (review-panel--flush
       (concat lead (review-panel--txt (format "%d of %d viewed" (car progress) (cdr progress))
                                       'fg :weight 'medium))
       (review-panel--txt (format "+%d  -%d" (car totals) (cdr totals)) 'dim)
       width)
      :pad '(10 3) :props '(review-header t))
     (if (and expanded hunks)
         (review-panel--row
          (review-panel--flush
           (concat lead (review-panel--txt (format "hunk %d of %d in this file" (1+ hunk) (length hunks))
                                           'dim :height 0.92))
           (review-panel--txt (format "%d of %d hunks total" (+ before hunk 1) all) 'mute :height 0.92)
           width)
          :pad '(3 3) :props '(review-header t))
       "")
     (review-panel--spacer 6)
     (review-panel--bar (car progress) (cdr progress) width)
     (review-panel--spacer 10))))

(defun review-panel--file-row (session i width)
  (let* ((file (review-session-file session i))
         (current (= i (review-session-current session)))
         (viewed (and (not current) (memq i (review-session-viewed session)) t))
         (hunks (plist-get file :hunks))
         (tally (and (plist-get file :rows) (review-panel--tally (plist-get file :rows))))
         (status (cond ((plist-get file :error) (review-panel--txt "failed" 'red :height 0.92))
                       ((plist-get file :binary) (review-panel--txt "binary" 'mute :faded viewed :height 0.92))
                       ((plist-get file :unchanged)
                        (review-panel--txt (review-panel--mode-label (plist-get file :mode))
                                           'mute :faded viewed :height 0.92))
                       ((not (plist-get file :loaded)) (review-panel--txt "loading" 'mute :height 0.92))
                       ((and current hunks)
                        (review-panel--txt (format "hunk %d/%d" (1+ (review-session-hunk session)) (length hunks))
                                           'dim :height 0.92))
                       (hunks (review-panel--txt (format "%d hunk%s" (length hunks) (if (cdr hunks) "s" ""))
                                                 'mute :faded viewed :height 0.92))
                       (t "")))
         (counts (if tally (review-panel--counts tally viewed 0.92) ""))
         (right (concat status (if (and (> (length status) 0) (> (length counts) 0)) (review-panel--gap 10) "")
                        counts))
         (lead (concat (review-panel--gap 12)
                       (if current
                           (propertize " " 'display `(space :width (,(review-panel--px 3)))
                                       'face `(:background ,(review-panel--hex 'orange)))
                         (review-panel--gap 3))
                       (review-panel--gap 10) (review-panel--status (cond (current 'current) (viewed 'viewed)))
                       (review-panel--gap 10) (review-panel--kind file viewed) (review-panel--gap 10)))
         (room (review-panel--room width (+ (review-panel--pixels lead) (review-panel--pixels right)
                                            (review-panel--px 26))
                                   1.0))
         (fit (review-panel--fit-path (plist-get file :path) room))
         (text (concat (review-panel--txt (car fit) 'mute :faded viewed)
                       (review-panel--txt (cdr fit) (if viewed 'dim 'fg)
                                          :faded viewed :weight (and current 'medium)))))
    (review-panel--row (review-panel--flush (concat lead text) right)
                       :bg (and current 'bg-1) :pad '(7 7) :props `(review-file ,i))))

(defun review-panel--hunk-rows (session i width)
  "Hunk rows of file I: done, current, or pending, as in the design."
  (let* ((file (review-session-file session i))
         (rows (plist-get file :rows))
         (current (= i (review-session-current session)))
         (viewed (memq i (review-session-viewed session)))
         (h -1))
    (mapconcat
     (lambda (hunk)
       (cl-incf h)
       (let* ((state (cond ((not current) (if viewed 'done 'pending))
                           ((< h (review-session-hunk session)) 'done)
                           ((= h (review-session-hunk session)) 'current)
                           (t 'pending)))
              (faded (eq state 'done))
              (right (review-panel--counts
                      (review-panel--tally (cl-subseq rows (plist-get hunk :start)
                                                      (min (length rows) (1+ (plist-get hunk :end)))))
                      faded 0.83))
              (lead (concat (review-panel--gap 44)
                            (review-panel--status (pcase state ('done 'viewed) ('current 'current)) 0.83)
                            (review-panel--gap 10)
                            (review-panel--txt (format "@@ -%d,%d +%d,%d @@"
                                                       (plist-get hunk :old-start) (plist-get hunk :old-count)
                                                       (plist-get hunk :new-start) (plist-get hunk :new-count))
                                               'mute :faded faded :height 0.92)
                            (review-panel--gap 10)))
              (room (review-panel--room width (+ (review-panel--pixels lead) (review-panel--pixels right)
                                                 (review-panel--px 26))
                                        0.92))
              (label (truncate-string-to-width (or (plist-get hunk :label) "") room nil nil "…")))
         (review-panel--row
          (review-panel--flush
           (concat lead (review-panel--txt label (if faded 'dim 'fg) :faded faded
                                           :weight (and (eq state 'current) 'medium) :height 0.92))
           right)
          :bg (and (eq state 'current) 'bg-0) :pad '(5 5) :props `(review-file ,i review-hunk ,h))))
     (plist-get file :hunks) "")))

(defun review-panel--strip (session)
  "The collapsed strip: PR number, viewed count, a vertical bar, one icon per file."
  (let* ((source (review-session-source session))
         (number (review-source-number source))
         (progress (review-session-progress session))
         (current (review-session-current session))
         (viewed (review-session-viewed session))
         (filled (if (zerop (cdr progress)) 0 (round (* 6 (/ (float (car progress)) (cdr progress)))))))
    (concat
     (review-panel--row (review-panel--center
                         (review-panel--txt (if number (format "#%d" number)
                                              (truncate-string-to-width (review-source-name source) 5))
                                            'orange :weight 'bold :height 0.92))
                        :bg 'bg-0 :pad '(14 12) :props '(review-header t))
     (review-panel--row (review-panel--center
                         (review-panel--txt (number-to-string (car progress)) 'fg :weight 'bold :height 1.08))
                        :pad '(10 0) :factor 1.08 :props '(review-header t))
     (review-panel--row (review-panel--center (review-panel--txt "of" 'mute :height 0.75))
                        :props '(review-header t))
     (review-panel--row (review-panel--center
                         (review-panel--txt (number-to-string (cdr progress)) 'dim :height 1.08))
                        :pad '(0 8) :factor 1.08 :props '(review-header t))
     (mapconcat (lambda (k)
                  (concat (review-panel--center
                           (propertize " " 'display `(space :width (,(review-panel--px 3))
                                                            :height (,(review-panel--px 10)))
                                       'face `(:background ,(review-panel--hex (if (< k filled) 'yellow 'bg-1))
                                                           :height 0.1)))
                          (propertize "\n" 'face '(:height 0.1))))
                (number-sequence 0 5) "")
     (review-panel--spacer 10)
     (review-panel--divider)
     (review-panel--spacer 6)
     (mapconcat (lambda (i)
                  (review-panel--row
                   (concat (if (= i current)
                               (propertize " " 'display `(space :width (,(review-panel--px 3)))
                                           'face `(:background ,(review-panel--hex 'orange)))
                             "")
                           (review-panel--center
                            (review-panel--status (cond ((= i current) 'current)
                                                        ((memq i viewed) 'viewed))
                                                  0.92)))
                   :bg (and (= i current) 'bg-1) :pad '(6 6) :props `(review-file ,i)))
                (number-sequence 0 (1- (length (review-session-files session)))) ""))))

(defun review-panel-render (session toggled collapsed &optional width)
  "Render SESSION as panel text in WIDTH columns.
TOGGLED flips files' hunk lists (see `review-panel--toggled'); COLLAPSED
renders the strip."
  (let ((review-panel--scale (/ (frame-char-width) 6.0))
        (width (or width (if collapsed review-panel-strip-width review-panel-width))))
    (if collapsed
        (review-panel--strip session)
      (let* ((current (review-session-current session))
             (expanded (lambda (i) (if (memq i toggled) (/= i current) (= i current)))))
        (concat (review-panel--header session width)
                (review-panel--progress session width (funcall expanded current))
                (review-panel--divider)
                (review-panel--spacer 4)
                (mapconcat (lambda (i)
                             (concat (review-panel--file-row session i width)
                                     (if (funcall expanded i) (review-panel--hunk-rows session i width) "")))
                           (number-sequence 0 (1- (length (review-session-files session)))) ""))))))

(defun review-panel--footer (collapsed)
  "Key hints for the mode line, as the design's footer; COLLAPSED shows TAB only."
  (let ((review-panel--scale (/ (frame-char-width) 6.0))
        (cap (lambda (key)
               (propertize (concat " " key " ")
                           'face `(:background ,(review-panel--hex 'bg-2) :foreground ,(review-panel--hex 'fg)
                                               :weight bold :height 0.75))))
        (label (lambda (text) (review-panel--txt text 'dim :height 0.75))))
    (if collapsed
        (list (review-panel--center (funcall cap "TAB")))
      (list (review-panel--gap 16)
            (mapconcat (lambda (hint) (concat (funcall cap (car hint)) (review-panel--gap 4)
                                              (funcall label (cdr hint))))
                       '(("C-j/k" . "file") ("M-j/k" . "hunk") ("TAB" . "fold")
                         ("RET" . "open") ("v" . "viewed") ("u" . "park"))
                       (review-panel--gap 10))))))

;;;; Buffer

(defvar review-panel-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB") #'review-panel-fold)
    (define-key m (kbd "<tab>") #'review-panel-fold)
    (define-key m (kbd "RET") #'review-panel-visit)
    (define-key m (kbd "C-j") #'review-session-next-file)
    (define-key m (kbd "C-k") #'review-session-prev-file)
    (define-key m (kbd "M-j") #'review-session-next-hunk)
    (define-key m (kbd "M-k") #'review-session-prev-hunk)
    (define-key m (kbd "v") #'review-session-toggle-viewed)
    (define-key m (kbd "u") #'syzygy-park)
    (define-key m (kbd "q") #'review-session-quit)
    m))

(define-derived-mode review-panel-mode special-mode "ReviewFiles"
  "Files panel of a review session."
  (setq truncate-lines t cursor-type nil)
  (setq-local cursor-in-non-selected-windows nil)
  (setq-local popper-popup-status 'raised)
  ;; The design's surfaces: a hard background, and a footer bar that holds
  ;; the key hints above a 1 px divider.
  (let ((pad (max 1 (round (* 10 (/ (frame-char-width) 6.0))))))
    (face-remap-add-relative 'default :background (review-panel--hex 'bg-hard))
    (face-remap-add-relative 'fringe :background (review-panel--hex 'bg-hard))
    (dolist (face '(mode-line mode-line-active mode-line-inactive))
      (face-remap-add-relative
       face `(:background ,(review-panel--hex 'bg-0) :foreground ,(review-panel--hex 'dim)
              :box (:line-width (0 . ,pad) :color ,(review-panel--hex 'bg-0))
              :overline ,(review-panel--hex 'bg-1) :underline nil)))))

(with-eval-after-load 'evil
  (evil-define-key 'normal review-panel-mode-map
    (kbd "TAB") #'review-panel-fold (kbd "<tab>") #'review-panel-fold
    (kbd "RET") #'review-panel-visit
    (kbd "C-j") #'review-session-next-file (kbd "C-k") #'review-session-prev-file
    (kbd "M-j") #'review-session-next-hunk (kbd "M-k") #'review-session-prev-hunk
    (kbd "v") #'review-session-toggle-viewed (kbd "q") #'review-session-quit
    (kbd "u") #'syzygy-park))

(defun review-panel--refresh (&optional session)
  "Re-render SESSION's panel, preserving its selected file or hunk."
  (let ((s (or session review-session--current))
        (review-panel--refreshing t))
    (when (and s (buffer-live-p (review-session-panel s)))
      (review-panel--display s)
      (with-current-buffer (review-session-panel s)
        (let* ((inhibit-read-only t)
               (file (get-text-property (point) 'review-file))
               (hunk (get-text-property (point) 'review-hunk))
               (window (get-buffer-window (current-buffer) t))
               (render (lambda ()
                         ;; Measure in the panel's own frame and font.
                         (cons (review-panel-render s review-panel--toggled review-panel--collapsed
                                                    review-panel--render-width)
                               (review-panel--footer review-panel--collapsed)))))
          (setq review-panel--render-width
                (if window (window-body-width window) review-panel-width))
          (pcase-let ((`(,text . ,footer)
                       (if window (with-selected-window window (funcall render)) (funcall render))))
            (erase-buffer)
            (insert text)
            (setq mode-line-format footer))
          (goto-char (point-min))
          (when file
            (let ((pos (text-property-any (point-min) (point-max) 'review-file file)))
              (when pos
                (goto-char pos)
                (when (and hunk (not review-panel--collapsed))
                  (while (and (< (point) (point-max))
                              (eq (get-text-property (point) 'review-file) file)
                              (not (eq (get-text-property (point) 'review-hunk) hunk)))
                    (forward-line)))))))))))

(defun review-panel--resized (frame)
  "Reflow the panel when its window in FRAME changes width."
  (when-let* ((s review-session--current)
              (buffer (review-session-panel s))
              (_ (buffer-live-p buffer))
              (window (get-buffer-window buffer frame)))
    (unless (or review-panel--refreshing
                (equal (window-body-width window)
                       (buffer-local-value 'review-panel--render-width buffer)))
      (review-panel--refresh s))))

(add-hook 'window-size-change-functions #'review-panel--resized)

(defun review-panel--source-updated (source)
  "Re-render when the live session's SOURCE learns its title late."
  (when-let ((s review-session--current))
    (when (eq source (review-session-source s)) (review-panel--refresh s))))

(defun review-panel--on-update (session)
  (if session
      (progn (review-panel--refresh session)
             (review-panel--show-bar session))
    (when-let ((bar (get-buffer review-panel--bar-name))) (kill-buffer bar))))

;;;; Compare frame chrome
;; Figma frame "Compare / side by side": a top bar across both panes, a
;; header per pane, a band above each hunk, the hard background, and no
;; mode lines.

(defconst review-panel--bar-name "*review bar*")
(defvar-local review-panel--pane-styled nil "Face remaps are in place.")

(defun review-panel--pane-header (session side)
  "OLD in red or NEW in green, then the side's branch and commit."
  (let* ((source (review-session-source session))
         (kind (plist-get (review-session-file session) :kind))
         (label (cond ((and (eq side 'old) (eq kind 'added)) "(new file)")
                      ((and (eq side 'new) (eq kind 'deleted)) "(deleted)")
                      ((if (eq side 'old) (review-source-old-label source)
                         (review-source-new-label source)))
                      (t (review-source-range-label source)))))
    (concat (review-panel--gap 16)
            (review-panel--txt (if (eq side 'old) "OLD" "NEW") (if (eq side 'old) 'red 'green)
                               :weight 'bold :height 0.83)
            (review-panel--gap 8)
            ;; Header lines read %-constructs.
            (review-panel--txt (string-replace "%" "%%" label) 'mute :height 0.83))))

(defun review-panel--band (hunk index total column)
  "The band shown above HUNK: its range and position, on the raised surface."
  (let ((band (concat (make-string column ?\s)
                      (review-panel--txt (format "@@ -%d,%d +%d,%d @@  hunk %d of %d"
                                                 (plist-get hunk :old-start) (plist-get hunk :old-count)
                                                 (plist-get hunk :new-start) (plist-get hunk :new-count)
                                                 index total)
                                         'dim :height 0.92)
                      "\n")))
    (add-face-text-property 0 (length band)
                            `(:background ,(review-panel--hex 'bg-0) :extend t) t band)
    band))

(defun review-panel--style-pane (session buffer side)
  "Give pane BUFFER the design's surface, header and hunk bands."
  (with-current-buffer buffer
    (setq mode-line-format nil
          header-line-format (review-panel--pane-header session side))
    ;; The design's rows are 20 px for 17 px of text.
    (setq-local line-spacing 0.17)
    (unless review-panel--pane-styled
      (setq review-panel--pane-styled t)
      (let ((pad (max 1 (round (* 6 review-panel--scale)))))
        (face-remap-add-relative 'default :background (review-panel--hex 'bg-hard))
        (face-remap-add-relative 'fringe :background (review-panel--hex 'bg-hard))
        (dolist (face '(header-line header-line-active header-line-inactive))
          (when (facep face)
            (face-remap-add-relative
             face `(:background ,(review-panel--hex 'bg-hard) :foreground ,(review-panel--hex 'mute)
                    :box (:line-width (0 . ,pad) :color ,(review-panel--hex 'bg-hard))
                    :underline nil :overline nil :inherit nil))))))
    (remove-overlays (point-min) (point-max) 'review-band t)
    (let* ((hunks (plist-get (review-session-file session review-pane--file-index) :hunks))
           (total (length hunks)) (index 0))
      (dolist (hunk hunks)
        (cl-incf index)
        (let ((o (make-overlay (review-session--row-position buffer (plist-get hunk :start))
                               (review-session--row-position buffer (plist-get hunk :start)))))
          (overlay-put o 'review-band t)
          (overlay-put o 'before-string
                       (review-panel--band hunk index total review-pane--text-column)))))))

(defun review-panel--bar-text (session width)
  "The top bar: kind and path on the left; file, hunk and counts on the right."
  (let* ((file (review-session-file session))
         (path (plist-get file :path))
         (hunks (plist-get file :hunks))
         (tally (and (plist-get file :rows) (review-panel--tally (plist-get file :rows))))
         (left (concat (review-panel--gap 16) (review-panel--kind file nil) (review-panel--gap 12)
                       (review-panel--txt (or (file-name-directory path) "") 'mute :height 1.08)
                       (review-panel--txt (file-name-nondirectory path) 'fg :weight 'medium :height 1.08)))
         (right (concat (review-panel--txt (format "file %d of %d" (1+ (review-session-current session))
                                                   (length (review-session-files session)))
                                           'dim :height 0.92)
                        (if hunks
                            (concat (review-panel--gap 12)
                                    (review-panel--txt (format "hunk %d of %d" (1+ (review-session-hunk session))
                                                               (length hunks))
                                                       'fg :weight 'medium :height 0.92))
                          "")
                        (if tally
                            (concat (review-panel--gap 12) (review-panel--counts tally nil 0.92))
                          ""))))
    (review-panel--row (review-panel--flush left right width) :bg 'bg-0 :pad '(10 10) :factor 1.08)))

(defun review-panel--show-bar (session)
  "Show or refresh the top bar across SESSION's compare frame."
  (let ((frame (review-session-frame session)))
    (when (frame-live-p frame)
      (with-selected-frame frame
        (let* ((review-panel--scale (/ (frame-char-width) 6.0))
               (buffer (get-buffer-create review-panel--bar-name))
               (window (or (get-buffer-window buffer frame)
                           (display-buffer-in-side-window
                            buffer '((side . top) (slot . 0) (window-height . 1)
                                     (window-parameters (no-other-window . t)
                                                        (no-delete-other-windows . t)))))))
          (when (window-live-p window)
            (set-window-dedicated-p window t)
            (with-current-buffer buffer
              (unless (derived-mode-p 'special-mode) (special-mode))
              (setq mode-line-format nil header-line-format nil cursor-type nil truncate-lines t)
              (setq-local cursor-in-non-selected-windows nil)
              (face-remap-set-base 'default :background (review-panel--hex 'bg-0))
              (let ((inhibit-read-only t)
                    (text (review-panel--bar-text session (window-body-width window))))
                (erase-buffer)
                (insert text)
                (goto-char (point-min))
                ;; One padded line: size the window to it exactly.
                (let ((height (cadr (get-text-property (1- (length text)) 'line-height text)))
                      (window-resize-pixelwise t))
                  (when (and (integerp height) (display-graphic-p frame))
                    (ignore-errors
                      (window-resize window (- height (window-body-height window t)) nil t t))))))))))))

(defun review-panel--style-compare (session)
  "Dress SESSION's compare frame in the design: panes, bands and top bar."
  (dolist (side '(old new))
    (let ((buffer (if (eq side 'old) (review-session-old-buffer session)
                    (review-session-new-buffer session))))
      (when (buffer-live-p buffer)
        (let ((window (get-buffer-window buffer t)))
          (if window
              (with-selected-window window
                (let ((review-panel--scale (/ (frame-char-width) 6.0)))
                  (review-panel--style-pane session buffer side)))
            (review-panel--style-pane session buffer side))))))
  ;; Only our own frame gets a recoloured divider between the panes.
  (when (and (review-session-own-frame session) (frame-live-p (review-session-frame session)))
    (set-face-attribute 'vertical-border (review-session-frame session)
                        :foreground (review-panel--hex 'bg-1)))
  (review-panel--show-bar session))

(defun review-panel--display (session)
  "Display SESSION's panel in its own frame or beside the compare panes."
  (when (and (frame-live-p (review-session-frame session))
             (buffer-live-p (review-session-panel session)))
    (with-selected-frame (or (review-session-panel-frame session)
                             (review-session-frame session))
      (let* ((buffer (review-session-panel session))
             (width (with-current-buffer buffer
                      (if review-panel--collapsed review-panel-strip-width
                        (if (review-session-panel-frame session) review-panel-width
                          (min review-panel-width
                               (max 12 (/ (frame-width) 3))))))))
        (if (review-session-panel-frame session)
            (let ((window (or (get-buffer-window buffer (selected-frame))
                              (frame-selected-window))))
              ;; A fresh frame can inherit *scratch*'s popup window.  This
              ;; frame belongs to the panel: give it one ordinary window.
              (select-window window)
              (set-window-dedicated-p window nil)
              (dolist (parameter '(window-side window-slot no-other-window
                                   no-delete-other-windows quit-restore))
                (set-window-parameter window parameter nil))
              (let ((ignore-window-parameters t)) (delete-other-windows window))
              (set-window-buffer window buffer)
              ;; The strip is a narrow column: shrink its own frame to fit,
              ;; and widen it again on expand.  Only on a toggle, so a
              ;; width the user chose is otherwise left alone.
              (let ((frame (selected-frame))
                    (collapsed (buffer-local-value 'review-panel--collapsed buffer)))
                (unless (eq collapsed (frame-parameter frame 'review-collapsed))
                  (set-frame-parameter frame 'review-collapsed collapsed)
                  ;; Float while a strip, or a tiling space stretches it back.
                  ;; Collapse: float, then shrink.  Expand: widen while still
                  ;; floating, then tile; resizing a freshly tiled window let
                  ;; yabai move it to another display, so place it again.
                  (if collapsed
                      (review-frame-set-floating
                       frame t (lambda ()
                                 (when (frame-live-p frame)
                                   (set-frame-width frame review-panel-strip-width))))
                    (set-frame-width frame review-panel-width)
                    (review-frame-set-floating
                     frame nil (lambda ()
                                 (when (frame-live-p frame)
                                   (review-frame-place frame review-panel-display))))))))
          (let ((window (display-buffer-in-side-window
                         buffer `((side . left) (slot . 0) (window-width . ,width)))))
            (when (/= width (window-total-width window))
              (window-resize window (- width (window-total-width window)) t t))))))))

(defun review-panel--make-frame ()
  "Create a frame for review files without taking input focus."
  (save-selected-window
    (make-frame (review-frame-parameters
                 `((name . "Review files") (title . "Review files")
                   (width . ,review-panel-width)
                   (height . 45) (min-width . ,review-panel-strip-width)
                   (no-focus-on-map . t))))))

(defun review-panel--preload (session index)
  "Fill SESSION's hunk map incrementally, starting at INDEX."
  (when (and (eq session review-session--current)
             (buffer-live-p (review-session-panel session))
             (< index (length (review-session-files session))))
    (let ((next (lambda (&optional _error)
                  (review-panel--refresh session)
                  (run-at-time 0 nil #'review-panel--preload session (1+ index)))))
      (condition-case err
          (review-session-load session index next)
        (error
         (let ((file (review-session-file session index)))
           (aset (review-session-files session) index
                 (plist-put file :error (error-message-string err))))
         (funcall next))))))

(defun review-panel-open (session)
  "Create SESSION's files panel and begin loading its hunk map."
  (let ((buffer (generate-new-buffer
                 (format "*review files: %s*"
                         (review-source-range-label (review-session-source session))))))
    (with-current-buffer buffer
      (review-panel-mode)
      (setq review-panel--session session
            default-directory (review-session-directory session)))
    (setf (review-session-panel session) buffer)
    (add-hook 'review-session-update-hook #'review-panel--on-update)
    (add-hook 'review-session-display-hook #'review-panel--display)
    (add-hook 'review-session-display-hook #'review-panel--style-compare)
    (add-hook 'review-source-updated-functions #'review-panel--source-updated)
    (condition-case err
        (progn
          (when (and review-panel-pop-out
                     (display-graphic-p (review-session-frame session)))
            (setf (review-session-panel-frame session) (review-panel--make-frame))
            (review-frame-place (review-session-panel-frame session) review-panel-display))
          (review-panel--refresh session))
      (error (review-session-quit) (signal (car err) (cdr err))))
    (run-at-time 0 nil #'review-panel--preload session 0)
    buffer))

(defun review-panel-fold ()
  "Toggle the hunks of the file at point; on the header, toggle the strip."
  (interactive)
  (let ((i (get-text-property (point) 'review-file)))
    (cond
     ((get-text-property (point) 'review-header)
      (setq review-panel--collapsed (not review-panel--collapsed)))
     (i (setq review-panel--toggled (if (memq i review-panel--toggled)
                                        (delq i review-panel--toggled)
                                      (cons i review-panel--toggled))))
     (t (user-error "Put point on a file or the header")))
    (review-panel--refresh review-panel--session)))

(defun review-panel-visit ()
  "Show the file and hunk at point after its text has loaded."
  (interactive)
  (let ((i (get-text-property (point) 'review-file))
        (h (get-text-property (point) 'review-hunk)))
    (unless i (user-error "Put point on a file"))
    (review-session-show i h)))

(provide 'review-panel)
;;; review-panel.el ends here
