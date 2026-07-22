;;; -*- lexical-binding: t; -*-




(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-sources-directory (expand-file-name "sources/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1 :inherit ignore
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca-activate)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-sources-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (<= emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let* ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                  ((zerop (apply #'call-process `("git" nil ,buffer t "clone"
                                                  ,@(when-let* ((depth (plist-get order :depth)))
                                                      (list (format "--depth=%d" depth) "--no-single-branch"))
                                                  ,(plist-get order :repo) ,repo))))
                  ((zerop (call-process "git" nil buffer t "checkout"
                                        (or (plist-get order :ref) "--"))))
                  (emacs (concat invocation-directory invocation-name))
                  ((zerop (call-process emacs nil buffer nil "-Q" "-L" "." "--batch"
                                        "--eval" "(byte-recompile-directory \".\" 0 'force)")))
                  ((require 'elpaca))
                  ((elpaca-generate-autoloads "elpaca" repo)))
            (progn (message "%s" (buffer-string)) (kill-buffer buffer))
          (error "%s" (with-current-buffer buffer (buffer-string))))
      ((error) (warn "%s" err) (delete-directory repo 'recursive))))
  (unless (require 'elpaca-autoloads nil t)
    (require 'elpaca)
    (elpaca-generate-autoloads "elpaca" repo)
    (let ((load-source-file-function nil)) (load "./elpaca-autoloads"))))
(add-hook 'after-init-hook #'elpaca-process-queues)
(elpaca `(,@elpaca-order))

(elpaca elpaca-use-package
  ;; Enable Elpaca support for use-package's :ensure keyword.
  (elpaca-use-package-mode))

;; cond-let is required by magit-section but not on MELPA
(use-package cond-let
  :ensure (:host github :repo "tarsius/cond-let"))


;; compat MUST be queued before any package that depends on it (org-modern,
;; org-super-agenda, vertico, magit, ...). If it's declared later, elpaca has
;; already queued it as a transitive dependency and re-queuing it errors out
;; ("compat previously queued as dependency of ..." -> Wrong type argument: listp)
;; which aborts the rest of init in daemon mode.
;; Emacs 30 ships compat v30 but newer packages need v31+, so force-require it.
(use-package compat
  :ensure t
  :demand t
  :config
  (require 'compat-31))

(use-package transient
  :ensure t
  :demand t)

;; Load org early to avoid version conflicts
(elpaca org)
(elpaca-wait)

;; Ensure .org files always open in org-mode (fixes version mismatch issues)
(add-to-list 'auto-mode-alist '("\\.org\\'" . org-mode))

;; Function to fix any .org files stuck in fundamental-mode
(defun mr-x/fix-org-mode-buffers ()
  "Fix any .org files that opened in fundamental-mode"
  (interactive)
  (dolist (buffer (buffer-list))
    (when (and (buffer-file-name buffer)
               (string-match "\\.org$" (buffer-file-name buffer))
               (not (eq (with-current-buffer buffer major-mode) 'org-mode)))
      (with-current-buffer buffer
        (org-mode)))))




(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)


(setq gc-cons-threshold (* 100 1024 1024)) ;; 100MB
(run-with-idle-timer 5 t #'garbage-collect)

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; org-mcp is a local project under ~/roaming (synced via Syncthing); load it
;; only when present so a machine without ~/roaming yet doesn't abort all of init.
(let ((org-mcp-dir "~/roaming/projects/MCP servers/org-mcp/src/elisp"))
  (when (file-directory-p org-mcp-dir)
    (add-to-list 'load-path org-mcp-dir)
    (require 'org-mcp nil t)))


      (use-package org
        :ensure nil
        :demand t
  	:hook (org-mode . mr-x/org-mode-setup)
  	:config
  	;; Move org-agenda-files here
  	(setq org-agenda-files '("~/roaming/agenda.org"))
  	
  	;; Move clock persistence here  
  	(setq org-clock-persist t)
  	(org-clock-persistence-insinuate)
  	
  	;; Define setup function here
  	(defun mr-x/org-mode-setup()
  	  (visual-line-mode 1)
  	  (auto-fill-mode 0)
  	  (setq org-agenda-include-diary nil)
  	  (setq org-fold-core-style 'overlays)
  	  (setq org-agenda-span 'day)
  	  (setq evil-auto-indent nil))
  	
  	;; Rest of org config
  	(setq org-ellipsis " ‧")
  	(setq org-hide-emphasis-markers t)
  	(setq org-agenda-start-with-log-mode t)
  	(setq org-log-done 'time)
  	(setq org-log-into-drawer t)

  	;; testing

  	(setq org-M-RET-may-split-line '((default . nil)))
  	(setq org-list-automatic-rules 
  	      '((checkbox . t)
  	       (indent . nil)
  	       (ordered . nil)))

  	(setq org-highlight-latex-and-related '(latex))

  					      ; org- habit setup

  	(require 'org-habit)
  	(add-to-list 'org-modules 'org-habit)
  	(setq org-habit-graph-column 60)
  	(advice-add 'org-habit-insert-consistency-graphs :before
  	            (lambda (&rest _)
  	              (setq org-habit-graph-column
  	                    (min 60 (- (window-width) 32)))))

  	;; org-habit-flex: weekday-specific habits
  	(require 'org-habit-flex)
  	(org-habit-flex-activate)

  	;; ── Color palette ──────────────────────────────────
  	(defvar mr-x/colors
  	  '((gold      . "#fabd2f")
  	    (orange    . "#fe8019")
  	    (green     . "#8ec07c")
  	    (lime      . "#b8bb26")
  	    (cream     . "#ebdbb2")
  	    (gray      . "#665c54")
  	    (gray-warm . "#897d6c")
  	    (red       . "#FF1800")
  	    (muted     . "#62656A")
  	    (mint      . "#B7CBA8")
  	    (bg        . "#1d2021"))
  	  "Central color palette for org-agenda and related UI.")

  	(defun mr-x/color (name)
  	  "Look up color NAME from `mr-x/colors'."
  	  (alist-get name mr-x/colors))

  	;; ── Agenda section header builder ──────────────────
  	(defvar mr-x/agenda-separator "────────────────────"
  	  "Separator string used under agenda section headers.")

  	(defun mr-x/agenda-header (icon name)
  	  "Build a section header with ICON, NAME, and a separator line.
  Color is applied post-render by `mr-x/style-agenda-separators'
  since org-agenda overrides text properties on headers."
  	  (concat "\n" icon "  " name "\n" mr-x/agenda-separator "\n"))

  	;; ── TODO keywords ─────────────────────────────────
  	(setq org-todo-keywords
  	      '((sequence
  		 "TODO(t)"
  		 "NEXT(n)"
  		 "WAIT(w@/!)"
  		 "|"
  		 "DONE(d!)"
  		 "CANC(k@)")))

  	(defvar mr-x/todo-faces
  	  `(("TODO" . (:foreground ,(mr-x/color 'bg) :background ,(mr-x/color 'red) :weight bold))
  	    ("NEXT" . (:foreground ,(mr-x/color 'bg) :background ,(mr-x/color 'orange) :weight bold))
  	    ("WAIT" . (:foreground ,(mr-x/color 'bg) :background ,(mr-x/color 'mint) :weight bold))
  	    ("DONE" . (:foreground ,(mr-x/color 'bg) :background ,(mr-x/color 'muted) :weight bold))
  	    ("CANC" . (:foreground ,(mr-x/color 'bg) :background ,(mr-x/color 'muted) :weight bold)))
  	  "TODO keyword faces used by both org and org-modern.")

  	(setq org-todo-keyword-faces mr-x/todo-faces)

  	(custom-set-faces
  	 '(org-level-1 ((t (:foreground "#c8c8c8"))))
  	 '(org-level-2 ((t (:foreground "#a8a8a8"))))
  	 '(org-level-3 ((t (:foreground "#909090"))))
  	 '(org-level-4 ((t (:foreground "#787878"))))
  	 '(org-level-5 ((t (:foreground "#606060"))))
  	 '(org-level-6 ((t (:foreground "#505050"))))
  	 '(org-level-7 ((t (:foreground "#404040"))))))

      (use-package org-modern
  	:ensure t
  	:hook (org-mode . org-modern-mode)
  	:custom
  	(org-modern-star 'replace)
  	(org-modern-replace-stars "❖✦⬡◈✧◇▸")
  	(org-modern-hide-stars nil)
  	(org-modern-table nil)
  	(org-modern-todo-faces mr-x/todo-faces))

      (add-hook 'org-mode-hook #'org-indent-mode)

      (use-package org-tidy
  	:ensure t
  	:hook (org-mode . org-tidy-mode))

      (use-package org-super-agenda
  	:ensure t
  	:after org
  	:config
  	(setq org-super-agenda-header-map nil)
  	(org-super-agenda-mode 1))

      (defun mr-x/org-get-category (item)
  	"Return capitalized category for ITEM, without 'Category: ' prefix."
  	(when-let ((marker (or (get-text-property 0 'org-marker item)
  			       (get-text-property 0 'org-hd-marker item))))
  	  (with-current-buffer (marker-buffer marker)
  	    (goto-char marker)
  	    (capitalize (org-get-category (point))))))

      ;; Distraction-free centered reading for Mdox reader
      (use-package olivetti
  	:ensure t
  	:defer t
  	:custom
  	(olivetti-body-width 80)
  	(olivetti-minimum-body-width 72))


      ;; org agenda
      (setq org-agenda-skip-scheduled-if-done t
  	    org-agenda-skip-deadline-if-done t
  	    org-agenda-include-deadlines t
  	    org-agenda-block-separator #x2501
  	    org-agenda-compact-blocks t
  	    org-agenda-start-with-log-mode t)

      (setq org-agenda-clockreport-parameter-plist
  	    (quote (:link t :maxlevel 5 :fileskip0 t :compact t :narrow 80)))
      (setq org-agenda-deadline-faces
  	    '((1.0001 . org-warning)              ; due yesterday or before
  	      (0.0    . org-upcoming-deadline)))  ; due today or later

      (defun org-habit-streak-count ()
  	(goto-char (point-min))
  	(while (not (eobp))
  	  ;;on habit line?
  	  (when (get-text-property (point) 'org-habit-p)
  	    (let ((streak 0)
  		  (counter (+ org-habit-graph-column (- org-habit-preceding-days org-habit-following-days)))
  		  )
  	      (move-to-column counter)
  	      ;;until end of line
  	      (while (and (char-after (point))
  			  (= (char-after (point)) org-habit-completed-glyph))
  		(setq streak (+ streak 1))
  		(setq counter (- counter 1))
  		(backward-char 1))
  	      (end-of-line)
  	      (insert (number-to-string streak))))
  	  (forward-line 1)))

      ;; Auto-refresh agenda when org files are saved
      (defun mr-x/agenda-redo-preserving-position ()
  	"Redo agenda and restore cursor to the closest matching entry."
  	(let* ((marker (or (org-get-at-bol 'org-hd-marker)
  			   (org-get-at-bol 'org-marker)))
  	       (entry-text (buffer-substring-no-properties
  			    (line-beginning-position) (line-end-position))))
  	  (org-agenda-redo-all)
  	  (let ((found nil))
  	    (when marker
  	      (goto-char (point-min))
  	      (while (and (not found) (not (eobp)))
  		(when (equal marker (or (org-get-at-bol 'org-hd-marker)
  					(org-get-at-bol 'org-marker)))
  		  (setq found t))
  		(unless found (forward-line 1))))
  	    (unless found
  	      (goto-char (point-min))
  	      (unless (search-forward entry-text nil t)
  		(goto-char (point-min)))))))

      (defun mr-x/agenda-auto-refresh ()
        "Refresh visible agenda buffers when an org file is saved.
  Only refreshes buffers that are currently displayed in a window —
  `org-agenda-redo-all' calls `recenter', which errors when the
  selected window does not show the current buffer."
        (when (derived-mode-p 'org-mode)
          (dolist (buf (buffer-list))
            (when (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (derived-mode-p 'org-agenda-mode))
                       (get-buffer-window buf t))
              (run-with-idle-timer 0.5 nil
                (lambda (b)
                  (when (buffer-live-p b)
                    (when-let ((win (get-buffer-window b t)))
                      (with-selected-window win
                        (mr-x/agenda-redo-preserving-position)))))
                buf)))))

      (add-hook 'after-save-hook #'mr-x/agenda-auto-refresh)

    ;; Auto-redo agenda after marking a habit done
    ;; org-agenda-todo only does an inline update, which doesn't redraw
    ;; the habit consistency graph — a full redo is needed.
    (defun mr-x/agenda-redo-after-habit-done (orig-fun &rest args)
      "After `org-agenda-todo', redo the agenda if the entry was a habit."
      (let ((was-habit (org-get-at-bol 'org-habit-p)))
        (apply orig-fun args)
        (when was-habit
          (org-agenda-redo-all))))
    (advice-add 'org-agenda-todo :around #'mr-x/agenda-redo-after-habit-done)

      ;; Reset finalize hook to prevent stale functions accumulating across reloads
      (setq org-agenda-finalize-hook nil)

      (add-hook 'org-agenda-finalize-hook 'org-habit-streak-count)

      (defun mr-x/clean-current-time-line ()
  	"Remove trailing grid characters from the current-time line in agenda."
  	(save-excursion
  	  (goto-char (point-min))
  	  (while (not (eobp))
  	    (let* ((beg (line-beginning-position))
  		   (end (line-end-position))
  		   (has-face nil))
  	      (save-excursion
  		(goto-char beg)
  		(while (< (point) end)
  		  (when (eq (get-text-property (point) 'face) 'org-agenda-current-time)
  		    (setq has-face t))
  		  (forward-char 1)))
  	      (when has-face
  		(let ((inhibit-read-only t))
  		  (save-excursion
  		    (goto-char beg)
  		    (when (re-search-forward "\\([0-9]+:[0-9]+\\)[┈─·.…]+" end t)
  		      (replace-match "\\1")
  		      (put-text-property beg (line-end-position) 'face 'org-agenda-current-time))))))
  	    (forward-line 1))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/clean-current-time-line)

      (defun mr-x/style-routine-entries ()
        "Reformat routine (sexp) entries with ● icon and colored segments."
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t))
            (while (not (eobp))
              (when (string= (get-text-property (point) 'type) "sexp")
                (let* ((bol (line-beginning-position))
                       (eol (line-end-position))
                       (line (buffer-substring-no-properties bol eol))
                       (props (text-properties-at bol)))
                  (when (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\).*?\\([A-Za-z].*\\)" line)
                    (let ((time (match-string 1 line))
                          (desc (string-trim (match-string 2 line))))
                      (delete-region bol eol)
                      (insert (propertize (format "%7s " time)
                                          'face 'org-time-grid
                                          'type "sexp"
                                          'org-category (plist-get props 'org-category))
                              (propertize "● "
                                          'face `(:foreground ,(mr-x/color 'gold))
                                          'type "sexp"
                                          'org-category (plist-get props 'org-category))
                              (propertize desc
                                          'face `(:foreground ,(mr-x/color 'cream))
                                          'type "sexp"
                                          'org-category (plist-get props 'org-category)))))))
              (forward-line 1)))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/style-routine-entries)

      (defun mr-x/style-timed-todo-entries ()
        "Reformat timed TODO entries with ▲ icon to match agenda styling.
Turns `8:00┈┈┈┈┈Call SNAP' into `   8:00 ▲ Call SNAP'."
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t))
            (while (not (eobp))
              (let ((todo-state (get-text-property (point) 'todo-state)))
                (when (and todo-state
                           (not (string= (or (get-text-property (point) 'type) "") "sexp")))
                  (let* ((bol (line-beginning-position))
                         (eol (line-end-position))
                         (line (buffer-substring-no-properties bol eol))
                         (props (text-properties-at bol)))
                    (when (string-match "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)[^A-Za-z]+\\([A-Za-z].*\\)" line)
                      (let* ((time (match-string 1 line))
                             (desc (string-trim (match-string 2 line)))
                             (common (list 'org-marker (plist-get props 'org-marker)
                                           'org-hd-marker (plist-get props 'org-hd-marker)
                                           'org-category (plist-get props 'org-category)
                                           'todo-state todo-state
                                           'tags (plist-get props 'tags)
                                           'mouse-face 'highlight)))
                        (delete-region bol eol)
                        (insert (apply #'propertize (format "%7s " time)
                                       'face 'org-time-grid common)
                                (apply #'propertize "▲ "
                                       'face `(:foreground ,(mr-x/color 'gold)) common)
                                (apply #'propertize desc
                                       'face `(:foreground ,(mr-x/color 'cream)) common)))))))
              (forward-line 1)))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/style-timed-todo-entries)

      (defun mr-x/style-agenda-entries ()
        "Colorize ▲ icons and add ◆ to NEXT tasks in one pass."
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t))
            (while (not (eobp))
              (when (search-forward "▲" (line-end-position) t)
                (if (string= (get-text-property (line-beginning-position) 'todo-state) "NEXT")
                    (replace-match
                     (concat (propertize "▲" 'face `(:foreground ,(mr-x/color 'gold)))
                             " "
                             (propertize "◆" 'face `(:foreground ,(mr-x/color 'orange)))))
                  (put-text-property (match-beginning 0) (match-end 0)
                                     'face `(:foreground ,(mr-x/color 'gold)))))
              (forward-line 1)))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/style-agenda-entries)

      (defun mr-x/style-habit-entries ()
        "Colorize ↻ icons on habit lines."
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t))
            (while (not (eobp))
              (when (search-forward "↻" (line-end-position) t)
                (put-text-property (match-beginning 0) (match-end 0)
                                   'face `(:foreground ,(mr-x/color 'green))))
              (forward-line 1)))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/style-habit-entries)

      (defun mr-x/style-agenda-separators ()
        "Color separator lines gray. Runs as finalize hook because
org-agenda overrides text properties on header strings."
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t)
                (sep-re (regexp-quote mr-x/agenda-separator)))
            (while (re-search-forward sep-re nil t)
              (put-text-property (match-beginning 0) (match-end 0)
                                 'face `(:foreground ,(mr-x/color 'gray)))))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/style-agenda-separators)

      ;; Sort NEXT tasks to top within category groups
      (defun mr-x/agenda-cmp-next-first (a b)
        "Sort NEXT entries before other todo states."
        (let ((sa (or (get-text-property 1 'todo-state a) ""))
              (sb (or (get-text-property 1 'todo-state b) "")))
          (cond
           ((and (string= sa "NEXT") (not (string= sb "NEXT"))) -1)
           ((and (string= sb "NEXT") (not (string= sa "NEXT"))) +1))))

      ;; Must be set before agenda opens, not in a hook
      (setq org-agenda-window-setup 'only-window)

      ;; Hide empty agenda sections
      (defun mr-x/agenda-remove-empty-sections ()
        "Remove section headers that have no entries below them."
        (save-excursion
          (let ((inhibit-read-only t)
                (section-re "\\(Schedule\\|Do Today\\|Do Next\\|Deadlines\\|Habits\\|Timeline\\|Inbox\\|Priority\\|Unscheduled\\|Upcoming Deadlines\\|Waiting On\\|Stale Tasks\\|Done This Week\\)"))
            (goto-char (point-max))
            (while (re-search-backward section-re nil t)
              (let* ((header-start (line-beginning-position))
                     (sep-end (save-excursion
                                (goto-char (line-end-position))
                                (forward-line 1)
                                (if (looking-at ".*[━─┈═]\\{5,\\}")
                                    (progn (forward-line 1) (point))
                                  (point))))
                     (next-section (save-excursion
                                    (goto-char sep-end)
                                    (if (re-search-forward section-re nil t)
                                        (line-beginning-position)
                                      (point-max))))
                     (has-content nil))
                (save-excursion
                  (goto-char sep-end)
                  (while (and (< (point) next-section) (not has-content))
                    (unless (looking-at "^[ \t]*$")
                      (setq has-content t))
                    (forward-line 1)))
                (unless has-content
                  (let ((del-start (save-excursion
                                     (goto-char header-start)
                                     (while (and (> (point) (point-min))
                                                 (save-excursion
                                                   (forward-line -1)
                                                   (looking-at "^[ \t]*$")))
                                       (forward-line -1))
                                     (point))))
                    (delete-region del-start next-section)
                    (when (> (point) (point-min))
                      (insert "\n")))))))))
      (add-hook 'org-agenda-finalize-hook 'mr-x/agenda-remove-empty-sections 89)

      ;; Go to top when agenda is rendered (redo-preserving-position
      ;; will reposition after refresh, so this only matters for initial open)
      (add-hook 'org-agenda-finalize-hook
                (lambda () (goto-char (point-min)))
                90)

      (defun mr-x/style-org-agenda ()
  	"Set face attributes for agenda mode."
  	(set-face-attribute 'org-agenda-date nil :height 1.1)
  	(set-face-attribute 'org-agenda-date-today nil :height 1.1 :slant 'italic)
  	(set-face-attribute 'org-agenda-date-today nil
  			    :foreground (mr-x/color 'gray-warm)
  			    :background nil
  			    :weight 'bold
  			    :underline nil)
  	(set-face-attribute 'org-agenda-date-weekend nil :height 1.1)
  	(set-face-attribute 'org-agenda-current-time nil
  			    :foreground (mr-x/color 'gold) :weight 'bold)
  	(set-face-attribute 'org-super-agenda-header nil
  			    :foreground (mr-x/color 'green) :weight 'bold))

      (add-hook 'org-agenda-mode-hook 'mr-x/style-org-agenda)


      (setq org-agenda-breadcrumbs-separator " ❱ "
  	    org-agenda-current-time-string "⏰ ┈┈┈┈┈┈┈┈┈┈┈ now"
  	    org-agenda-time-grid '((daily today)
  				   (800 1000 1200 1400 1600 1800 2000)
  				   "---" "┈┈┈┈┈┈┈┈┈┈┈┈┈")
  	    org-agenda-prefix-format '((agenda . "%i %-12:c [%e] %?-12t%b% s")
  				       (todo . " %i %-12:c [%e] ")
  				       (tags . " %i %-12:c")
  				       (search . " %i %-12:c")))




      ;; Diary-sexp helpers for schedule time markers
      ;; `date' must be dynamically bound for org diary-sexp evaluation
      (defvar date nil "Dynamic variable used by org diary-sexp evaluation.")
      (defun my/daily (_date) "Every day." t)
      (defun my/weekdays (date)
        "Monday through Friday."
        (memq (calendar-day-of-week date) '(1 2 3 4 5)))
      (defun my/weekends (date)
        "Saturday and Sunday."
        (memq (calendar-day-of-week date) '(0 6)))
      (defun my/on-days (date &rest days)
        "Match specific DAYS (symbols: mon tue wed thu fri sat sun)."
        (let ((day-map '((sun . 0) (mon . 1) (tue . 2) (wed . 3)
                         (thu . 4) (fri . 5) (sat . 6))))
          (memq (calendar-day-of-week date)
                (mapcar (lambda (d) (cdr (assq d day-map))) days))))

      ;; Habit skip helpers for agenda views
      (defun mr-x/agenda-skip-habits ()
        "Skip entries that are habits."
        (let ((end (save-excursion (org-end-of-subtree t))))
          (when (string= (org-entry-get nil "STYLE") "habit")
            end)))

      (defun mr-x/agenda-skip-non-habits ()
        "Skip entries that are NOT habits."
        (let ((end (save-excursion (org-end-of-subtree t))))
          (unless (string= (org-entry-get nil "STYLE") "habit")
            end)))

      (defun mr-x/agenda-routine-p ()
        "Return non-nil if entry at point is a routine."
        (string= (or (org-entry-get nil "CATEGORY" t) "") "Routines"))

      (defun mr-x/agenda-skip-untimed ()
        "Skip entries without a time-of-day (keeps routines)."
        (let ((end (save-excursion (org-end-of-subtree t)))
              (scheduled (org-entry-get nil "SCHEDULED"))
              (deadline (org-entry-get nil "DEADLINE")))
          (unless (or (and scheduled (string-match "[0-9]\\{1,2\\}:[0-9]\\{2\\}" scheduled))
                      (and deadline (string-match "[0-9]\\{1,2\\}:[0-9]\\{2\\}" deadline))
                      (mr-x/agenda-routine-p))
            end)))

      (defun mr-x/agenda-skip-timed ()
        "Skip entries with a time-of-day (skips routines)."
        (let ((end (save-excursion (org-end-of-subtree t)))
              (scheduled (org-entry-get nil "SCHEDULED"))
              (deadline (org-entry-get nil "DEADLINE")))
          (when (or (and scheduled (string-match "[0-9]\\{1,2\\}:[0-9]\\{2\\}" scheduled))
                    (and deadline (string-match "[0-9]\\{1,2\\}:[0-9]\\{2\\}" deadline))
                    (mr-x/agenda-routine-p))
            end)))

      (defun mr-x/agenda-skip-routines ()
        "Skip entries with category Routines."
        (let ((end (save-excursion (org-end-of-subtree t))))
          (when (mr-x/agenda-routine-p)
            end)))

      (defun mr-x/agenda-skip-if-deadline ()
        "Skip entries that have a DEADLINE."
        (let ((end (save-excursion (org-end-of-subtree t))))
          (when (org-entry-get nil "DEADLINE")
            end)))

      ;; Prompt for next action when marking a task DONE
      (add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
      (require 'mr-x-popup)

      (defun mr-x/prompt-for-next-action ()
        "After marking a task DONE, prompt to set the next action in the project.
Uses mr-x/popup-prompt to let the user pick from remaining TODO siblings."
        (when (and (member org-state '("DONE" "CANC"))
                   (not (string= (or (org-entry-get nil "STYLE") "") "habit")))
          (save-excursion
            (let* ((project-name nil)
                   (has-next nil)
                   (siblings '()))
              ;; Go up to the parent heading (the project's Tasks section or project root)
              (when (org-up-heading-safe)
                (setq project-name (org-get-heading t t t t))
                ;; Check all children for existing NEXT and collect TODOs
                (save-excursion
                  (org-map-entries
                   (lambda ()
                     (let ((state (org-get-todo-state))
                           (heading (org-get-heading t t t t)))
                       (cond
                        ((string= state "NEXT") (setq has-next t))
                        ((string= state "TODO")
                         (push (cons heading (point-marker)) siblings)))))
                   nil 'tree))
                ;; If no NEXT exists and there are remaining TODOs, prompt
                (when (and (not has-next) siblings)
                  (setq siblings (nreverse siblings))
                  (let ((choice (mr-x/popup-prompt
                                 (format "Set next action for [%s]:" project-name)
                                 "Pick the next task to work on (cancel to skip)"
                                 (mapcar #'car siblings))))
                    (when choice
                      (let ((marker (cdr (assoc choice siblings))))
                        (when (and marker (marker-buffer marker))
                          (with-current-buffer (marker-buffer marker)
                            (goto-char marker)
                            (org-todo "NEXT"))))))))))))

      (add-hook 'org-after-todo-state-change-hook #'mr-x/prompt-for-next-action)

      ;; Stuck projects: custom function that lists Active project names with no NEXT task
      (defun mr-x/stuck-projects-block (&rest _)
        "Insert stuck Active projects into agenda buffer."
        (let ((inhibit-read-only t)
              stuck)
          (dolist (file (org-agenda-files))
            (when-let* ((buf (org-get-agenda-file-buffer file)))
              (with-current-buffer buf
                (org-with-wide-buffer
                 (goto-char (point-min))
                 (when (and (re-search-forward "^#\\+filetags:.*Active" nil t)
                            (not (progn
                                   (goto-char (point-min))
                                   (re-search-forward "^\\*+ NEXT " nil t))))
                   (let ((title (or (cadr (car (org-collect-keywords '("TITLE"))))
                                    (file-name-base (buffer-file-name)))))
                     (push title stuck)))))))
          (insert (mr-x/agenda-header "⚠" "Stuck Projects"))
          (insert (if stuck
                      (mapconcat (lambda (p) (format "  ▲ %s\n" p))
                                 (nreverse stuck) "")
                    "  No stuck projects!\n"))))

      (setq org-agenda-custom-commands
            '(("c" "Classic Agenda"
               ((agenda ""
                        ((org-agenda-overriding-header "Agenda")
                         (org-agenda-prefix-format
                          '((agenda . "  %?-12t% s")
                            (timeline . "  % s")
                            (todo . "  ")
                            (tags . "  ")
                            (search . "  ")))
                         (org-agenda-log-mode-items '(closed clock))))
                (todo "NEXT"
                      ((org-agenda-overriding-header
                        (mr-x/agenda-header "" "Projects"))
                       (org-agenda-files '("~/roaming/notes/stable-elpaca.org"
                                           "~/roaming/notes/omi-live.org"
                                           "~/roaming/notes/customize-org-agenda.org"
                                           "~/roaming/notes/openpair.org"
                                           "~/roaming/notes/rec.org"
                                           "~/roaming/notes/amazon-orders-sorting.org"
                                           "~/roaming/notes/personal-website.org"
                                           "~/roaming/notes/vibe-coding-video.org"
                                           "~/roaming/notes/kountdown.org"
                                           "~/roaming/notes/guitar-fretboard-js.org"
                                           "~/roaming/notes/virtual-museum.org"
                                           "~/roaming/notes/track01-s-w.org"
                                           "~/roaming/notes/typingpracticeapplication.org")))))
               nil)



              ("d" "Dashboard"
               ((alltodo ""
                         ((org-agenda-overriding-header
                           (mr-x/agenda-header "􀌂" "Inbox"))
                          (org-agenda-files '("~/roaming/notes/Inbox.org"))
                          (org-agenda-prefix-format "  ▲ ")))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀋀" "Timeline"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-untimed)))
                         (org-agenda-prefix-format '((agenda . "  %?-12t")))
                         (org-agenda-time-grid '((daily today require-timed)
                                                 (800 1000 1200 1400 1600 1800 2000)
                                                 "" ""))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀋀" "Do Today"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-timed)))
                         (org-agenda-cmp-user-defined #'mr-x/agenda-cmp-next-first)
                         (org-agenda-sorting-strategy '(user-defined-up))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀁑" "Habits"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits t)
                         (org-agenda-skip-function '(mr-x/agenda-skip-non-habits))
                         (org-agenda-prefix-format '((agenda . "  ↻ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (tags-todo "+PRIORITY=\"A\"|+PRIORITY=\"B\""
                           ((org-agenda-overriding-header
                             (mr-x/agenda-header "􀀤" "Priority"))
                            (org-agenda-prefix-format "  ▲ ")
                            (org-agenda-cmp-user-defined #'mr-x/agenda-cmp-next-first)
                            (org-agenda-sorting-strategy '(user-defined-up priority-down))
                            (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))
                            (org-agenda-skip-function
                             '(org-agenda-skip-entry-if 'scheduled)))))
               ((org-agenda-remove-tags t)
                (org-agenda-scheduled-leaders '("" ""))
                (org-agenda-deadline-leaders '("" "In %3d d. " "%2d d. ago "))
                (org-agenda-current-time-string "")
                (org-agenda-compact-blocks nil)
                (org-agenda-format-date "\n  %A, %B %e")))

              ("f" "Focus"
               ((agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀎆" "Schedule"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-untimed)))
                         (org-agenda-prefix-format '((agenda . "  %-12t")))
                         (org-agenda-time-grid '((daily today)
                                                 (800 1000 1200 1400 1600 1800 2000)
                                                 "┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈" "┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈"))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀋀" "Do Today"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-include-diary nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-timed)
                               (mr-x/agenda-skip-if-deadline)))
                         (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))
                         (org-agenda-cmp-user-defined #'mr-x/agenda-cmp-next-first)
                         (org-agenda-sorting-strategy '(user-defined-up))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀞟" "Deadlines"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-include-diary nil)
                         (org-agenda-entry-types '(:deadline))
                         (org-deadline-warning-days 14)
                         (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-deadline-leaders '("Due!  " "In %3d d. " "%2d d. ago "))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (tags-todo "+Active/NEXT"
                           ((org-agenda-overriding-header
                             (mr-x/agenda-header "􀀤" "Do Next"))
                            (org-agenda-skip-function
                             '(org-agenda-skip-entry-if 'scheduled))
                            (org-agenda-prefix-format "  ▲ ")
                            (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀁑" "Habits"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits t)
                         (org-agenda-skip-function '(mr-x/agenda-skip-non-habits))
                         (org-agenda-prefix-format '((agenda . "  ↻ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date ""))))
               ((org-agenda-remove-tags t)
                (org-agenda-scheduled-leaders '("" ""))
                (org-agenda-deadline-leaders '("" "In %3d d. " "%2d d. ago "))
                (org-agenda-skip-deadline-if-done t)
                (org-agenda-skip-scheduled-if-done t)
                (org-agenda-show-log nil)
                (org-agenda-current-time-string "")
                (org-agenda-compact-blocks nil)
                (org-agenda-format-date "\n  %A, %B %e")))

              ("r" "Review"
               ((alltodo ""
                         ((org-agenda-overriding-header
                           (mr-x/agenda-header "􀌂" "Inbox"))
                          (org-agenda-files '("~/roaming/notes/Inbox.org"))
                          (org-agenda-prefix-format "  ▲ ")))
                (mr-x/stuck-projects-block "")
                (todo "WAIT"
                      ((org-agenda-overriding-header
                        (mr-x/agenda-header "⏳" "Waiting On"))
                       (org-agenda-prefix-format "  ▲ ")
                       (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "📋" "Stale Tasks"))
                         (org-agenda-span 1)
                         (org-habit-show-habits nil)
                         (org-agenda-include-diary nil)
                         (org-scheduled-past-days 30)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-routines)
                               (org-agenda-skip-entry-if 'notscheduled)
                               (org-agenda-skip-entry-if 'todo 'done)
                               (org-agenda-skip-entry-if 'notregexp "^.*SCHEDULED:.*<[^>]+>")
                               (let ((scheduled (org-entry-get nil "SCHEDULED")))
                                 (when (and scheduled
                                            (not (time-less-p
                                                  (org-time-string-to-time scheduled)
                                                  (current-time))))
                                   (org-end-of-subtree t)))))
                         (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (todo "DONE"
                      ((org-agenda-overriding-header
                        (mr-x/agenda-header "✓" "Done This Week"))
                       (org-agenda-prefix-format "  ▲ ")
                       (org-super-agenda-groups
                        '((:auto-map mr-x/org-get-category)))
                       (org-agenda-skip-function
                        '(let ((closed (org-entry-get nil "CLOSED")))
                           (if (and closed
                                    (time-less-p
                                     (time-subtract (current-time) (days-to-time 7))
                                     (org-time-string-to-time closed)))
                               nil
                             (org-end-of-subtree t)))))))
               ((org-agenda-remove-tags t)
                (org-agenda-scheduled-leaders '("" "%2d d. ago "))
                (org-agenda-deadline-leaders '("" "In %3d d. " "%2d d. ago "))
                (org-agenda-current-time-string "")
                (org-agenda-compact-blocks nil)
                (org-agenda-format-date "")))

              ("v" "Full View"
               ((alltodo ""
                         ((org-agenda-overriding-header
                           (mr-x/agenda-header "􀌂" "Inbox"))
                          (org-agenda-files '("~/roaming/notes/Inbox.org"))
                          (org-agenda-prefix-format "  ▲ ")))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀋀" "Timeline"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-untimed)))
                         (org-agenda-prefix-format '((agenda . "  %?-12t")))
                         (org-agenda-time-grid '((daily today require-timed)
                                                 (800 1000 1200 1400 1600 1800 2000)
                                                 "" ""))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀋀" "Do Today"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits nil)
                         (org-agenda-skip-function
                          '(or (mr-x/agenda-skip-habits)
                               (mr-x/agenda-skip-timed)))
                         (org-agenda-cmp-user-defined #'mr-x/agenda-cmp-next-first)
                         (org-agenda-sorting-strategy '(user-defined-up))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀁑" "Habits"))
                         (org-agenda-span 'day)
                         (org-habit-show-habits t)
                         (org-agenda-skip-function '(mr-x/agenda-skip-non-habits))
                         (org-agenda-prefix-format '((agenda . "  ▲ ")))
                         (org-agenda-time-grid nil)
                         (org-agenda-format-date "")))
                (todo "TODO|NEXT"
                      ((org-agenda-overriding-header
                        (mr-x/agenda-header "􀋀" "Unscheduled"))
                       (org-agenda-prefix-format "  ▲ ")
                       (org-agenda-cmp-user-defined #'mr-x/agenda-cmp-next-first)
                       (org-agenda-sorting-strategy '(user-defined-up))
                       (org-agenda-skip-function
                        '(or (mr-x/agenda-skip-habits)
                            (org-super-agenda-groups '((:auto-map mr-x/org-get-category)))
                             (org-agenda-skip-entry-if 'scheduled 'deadline)))))
                (agenda ""
                        ((org-agenda-overriding-header
                          (mr-x/agenda-header "􀞟" "Upcoming Deadlines"))
                         (org-agenda-span 7)
                         (org-agenda-entry-types '(:deadline))
                         (org-agenda-time-grid nil)
                         (org-agenda-prefix-format "  %?-12t"))))
               ((org-agenda-remove-tags t)
                (org-agenda-scheduled-leaders '("" ""))
                (org-agenda-deadline-leaders '("" "In %3d d. " "%2d d. ago "))
                (org-agenda-current-time-string "")
                (org-agenda-compact-blocks nil)
                (org-agenda-format-date "\n  %A, %B %e")))))
      (setq org-agenda-format-date (lambda (date)
  				     (concat "\n" mr-x/agenda-separator
  					    "\n" (org-agenda-format-date-aligned date))))

      ;; Agenda visual styling
      (setq org-agenda-todo-keyword-format "")
      (setq org-agenda-block-separator "")

      ;; Custom habit glyphs
      (setq org-habit-completed-glyph ?●
            org-habit-today-glyph ?◌
            org-habit-missed-glyph ?○)

      ;; Overdue indicator advice: replace "Sched.34x:" with clean symbols
      (defun mr-x/agenda-overdue-indicator (orig-fn extra txt &rest args)
        "Replace verbose scheduled leader with visual overdue indicators."
        (let* ((new-extra
                (if (and (stringp extra)
                         (string-match "^-\\([0-9]+\\)$" extra))
                    (let ((d (string-to-number (match-string 1 extra))))
                      (cond
                       ((< d 1)  "")
                       ((< d 3)  " ·")
                       ((< d 7)  " !")
                       ((< d 14) " ‼")
                       (t        " ✖")))
                  (or extra ""))))
          (apply orig-fn new-extra txt args)))

      (advice-add 'org-agenda-format-item :around
                  #'mr-x/agenda-overdue-indicator)

      ;; Priority as exclamation marks
      (defun mr-x/agenda-prettify-priorities ()
        "Replace [#A] [#B] [#C] with exclamation marks."
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward "\\[#A\\]" nil t)
            (replace-match "!!!" t t))
          (goto-char (point-min))
          (while (re-search-forward "\\[#B\\]" nil t)
            (replace-match "!!" t t))
          (goto-char (point-min))
          (while (re-search-forward "\\[#C\\]" nil t)
            (replace-match "!" t t))))

      ;; Strike-through for done items
      (defun mr-x/agenda-strike-through-done ()
        "Apply strike-through to DONE items in agenda."
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when (member (org-get-at-bol 'todo-state) org-done-keywords)
              (let* ((ov (make-overlay (line-beginning-position) (line-end-position)))
                     (existing (get-text-property (point) 'face))
                     (new-face (if existing
                                   (list existing '(:strike-through t))
                                 '(:strike-through t))))
                (overlay-put ov 'face new-face)
                (overlay-put ov 'org-agenda-strike t)))
            (forward-line 1))))

      ;; Section header styling
      (defun mr-x/agenda-style-section-headers ()
        "Style section headers (with SF Symbol icons) with larger, bold text."
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward "^.\\{0,4\\}\\(Schedule\\|Do Today\\|Do Next\\|Deadlines\\|Habits\\|Timeline\\|Inbox\\|Priority\\|Unscheduled\\|Upcoming Deadlines\\)" nil t)
            (let ((ov (make-overlay (line-beginning-position) (match-end 0))))
              (overlay-put ov 'face '(:height 1.3 :weight bold))))))

      (add-hook 'org-agenda-finalize-hook
  		(lambda ()
  		  ;; Centered layout
  		  (setq visual-fill-column-width 110)
  		  (setq visual-fill-column-center-text t)
  		  (visual-fill-column-mode t)
  		  ;; Subtle line spacing
  		  (setq-local line-spacing 0.15)
  		  ;; Hide mode-line
  		  (setq-local mode-line-format nil)
  		  ;; Collapse excessive blank lines
  		  (let ((inhibit-read-only t))
  		    (save-excursion
  		      (goto-char (point-min))
  		      (while (re-search-forward "\n\\(\n\\)\\(\n\\)+" nil t)
  			(replace-match "\n\n"))))
  		  ;; Highlight the time grid line closest to current time
  		  (save-excursion
  		    (goto-char (point-min))
  		    (let* ((now-mins (+ (* (string-to-number (format-time-string "%H")) 60)
  				       (string-to-number (format-time-string "%M"))))
  			   (best-pos nil)
  			   (best-diff 999))
  		      (while (re-search-forward "^  \([0-9]\{1,2\}\):\([0-9]\{2\}\)" nil t)
  			(let* ((h (string-to-number (match-string 1)))
  			       (m (string-to-number (match-string 2)))
  			       (grid-mins (+ (* h 60) m))
  			       (diff (abs (- now-mins grid-mins))))
  			  (when (< diff best-diff)
  			    (setq best-diff diff
  				  best-pos (line-beginning-position)))))
  		      (when best-pos
  			(goto-char best-pos)
  			(let ((ov (make-overlay (line-beginning-position) (line-end-position))))
  			  (overlay-put ov 'face `(:foreground ,(mr-x/color 'gold) :weight bold))))))
  		  ;; Apply visual effects
  		  (mr-x/agenda-prettify-priorities)
  		  (mr-x/agenda-strike-through-done)
  		  (mr-x/agenda-style-section-headers)))






  (defun my-highlight-lowest-goal ()
    "Find and highlight the task in the 'Projects' section with the lowest 'GOAL #' number."
    (when (derived-mode-p 'org-agenda-mode)
      (save-excursion
  	(goto-char (point-min))
  	(let (lowest-goal lowest-pos)
  	  ;; Search for "Projects" section
  	  (when (re-search-forward "^Projects" nil t)
  	    ;; Iterate over tasks under "Projects"
  	    (while (re-search-forward "GOAL #\\([0-9]+\\)" nil t)
  	      (let* ((goal-num (string-to-number (match-string 1)))
  		     (line-start (line-beginning-position))
  		     (line-end (line-end-position)))
  		;; Track the lowest goal number and its position
  		(when (or (not lowest-goal) (< goal-num lowest-goal))
  		  (setq lowest-goal goal-num)
  		  (setq lowest-pos (cons line-start line-end))))))
  	  ;; Apply highlighting to the first occurrence of the lowest goal
  	  (when lowest-pos
  	    (let ((ov (make-overlay (car lowest-pos) (cdr lowest-pos))))
  	      (overlay-put ov 'face '(:background "dark red" :foreground "white" :weight bold))))))))


  (add-hook 'org-agenda-finalize-hook #'my-highlight-lowest-goal)

  ;; Auto-refresh agenda buffers every 5 minutes
  (defvar mr-x/agenda-refresh-timer nil
    "Timer for periodic agenda refresh.")

  (defun mr-x/agenda-refresh-all ()
    "Silently refresh all visible org-agenda buffers."
    (dolist (buf (buffer-list))
      (when (and (get-buffer-window buf t)
                 (with-current-buffer buf
                   (derived-mode-p 'org-agenda-mode)))
        (with-current-buffer buf
          (let ((inhibit-message t))
            (org-agenda-redo t))))))

  (setq mr-x/agenda-refresh-timer
        (run-with-timer 300 300 #'mr-x/agenda-refresh-all))

  ;; toc-org for table of contents generation
  (use-package toc-org
    :ensure t
    :commands toc-org-enable
    :hook (org-mode . toc-org-mode))

  ;; Org HTML Preview with xwidget-webkit
  (defvar mr-x/org-preview-css-file
    (expand-file-name "etc/org-gruvbox.css" user-emacs-directory)
    "CSS file to use for org HTML preview.")

  (defun mr-x/org-preview-html ()
    "Export current org buffer to HTML and preview in xwidget-webkit."
    (interactive)
    (let* ((org-file (buffer-file-name))
           (html-file (concat (file-name-sans-extension org-file) ".html"))
           (org-html-head (format "<link rel=\"stylesheet\" type=\"text/css\" href=\"file://%s\" />"
                                  mr-x/org-preview-css-file))
           (org-html-head-include-default-style nil))
      (org-export-to-file 'html html-file nil nil nil nil nil)
      (xwidget-webkit-browse-url (concat "file://" html-file))))

  ;; Org heading insertion keybindings
  ;; s- (Cmd) = sibling, M- = context-aware (heading/list/etc), adding S- = TODO variant
  (with-eval-after-load 'org
    (define-key org-mode-map (kbd "s-<return>") #'org-insert-heading-respect-content)
    (define-key org-mode-map (kbd "s-S-<return>") #'org-insert-todo-heading-respect-content)
    (define-key org-mode-map (kbd "M-<return>") #'org-meta-return)
    (define-key org-mode-map (kbd "M-S-<return>") #'org-insert-todo-subheading))
  (with-eval-after-load 'evil
    (evil-define-key 'insert org-mode-map
      (kbd "s-<return>") #'org-insert-heading-respect-content
      (kbd "s-S-<return>") #'org-insert-todo-heading-respect-content
      (kbd "M-<return>") #'org-meta-return
      (kbd "M-S-<return>") #'org-insert-todo-subheading)
    (evil-define-key 'normal org-mode-map
      (kbd "s-<return>") #'org-insert-heading-respect-content
      (kbd "s-S-<return>") #'org-insert-todo-heading-respect-content
      (kbd "M-<return>") #'org-meta-return
      (kbd "M-S-<return>") #'org-insert-todo-subheading))



  (use-package ob-typescript
    :ensure t
    (:wait t))

	(org-babel-do-load-languages
	 'org-babel-load-languages
	 '((emacs-lisp . t)
	     (js . t)
	     (typescript . t)
	     (sqlite . t)
	     (sql . t)
	     (latex . t)
	     (python . t)))

	     (setq org-babel-python-command "python3")
  (require 'org-tempo)
  (add-to-list 'org-structure-template-alist '("ts" . "src typescript"))
  (add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))
  (add-to-list 'org-structure-template-alist '("py" . "src python"))
  (add-to-list 'org-structure-template-alist '("C" . "comment"))
  (add-to-list 'org-structure-template-alist '("js" . "src javascript"))
  (add-to-list 'org-structure-template-alist '("l" . "export latex"))

   ;; Automatically tangle our Emacs.org config file when we save it
   (defun mr-x/org-babel-tangle-config ()
     (when (string-equal (buffer-file-name)
			    (expand-file-name "~/.dotfiles/macos/emacs/.emacs.d/emacs.org"))
	 ;; Dynamic scoping to the rescue
	 (let ((org-confirm-babel-evaluate nil))
	    (org-babel-tangle))))

   (add-hook 'org-mode-hook (lambda () (add-hook 'after-save-hook #'mr-x/org-babel-tangle-config)))

   (setq-default prettify-symbols-alist '(("#+BEGIN_SRC" . "†")
					   ("#+END_SRC" . "†")
					   ("#+begin_src" . "†")
					   ("#+end_src" . "†")
					   ("#+BEGIN_LaTeX" . "†")
					   ("#+END_LaTeX" . "†")
					   (">=" . "≥")
					   ("=>" . "⇨")))
(setq prettify-symbols-unprettify-at-point 'right-edge)
(add-hook 'org-mode-hook 'prettify-symbols-mode)



   (use-package org-roam
   :ensure t
   :demand t
   :custom
   (org-roam-directory "~/roaming/notes/")
   (org-roam-completion-everywhere t)
   (org-roam-capture-templates
    '(("d" "default" plain
   	"%?"
   	:if-new (file+head "${slug}.org" "#+title: ${title}\n")
   	:unnarrowed t)))
   ;; (org-roam-dailies-capture-templates
   ;;  '(("d" "default" entry "* %<%I:%M %p>: %?"
   ;; 	:if-new (file+head "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\n"))))

   :bind (("C-c n f" . org-roam-node-find)
	     ("C-c n i" . org-roam-node-insert)
	     ("C-c n I" . org-roam-node-insert-immediate)
					    ; ("C-c n p" . my/org-roam-find-project)
					    ;("C-c n t" . my/org-roam-capture-task)
					    ; ("C-c n b" . my/org-roam-capture-inbox)
	     :map org-mode-map
	     ("C-M-i"   . completion-at-point)
	     :map org-roam-dailies-map
	     ("Y" . org-roam-dailies-capture-yesterday)
	     ("T" . org-roam-dailies-capture-tomorrow))
   :bind-keymap
   ("C-c n d" . org-roam-dailies-map)
   :config
   (require 'org-roam-dailies)

   ;; Clean slugs: hyphens instead of underscores, no timestamp prefix
   (cl-defmethod org-roam-node-slug ((node org-roam-node))
     "Generate a clean hyphenated slug from the node title."
     (let ((title (org-roam-node-title node)))
       (string-join (split-string (downcase title) "[^[:alnum:]]+" t) "-")))

   (org-roam-db-autosync-mode))

(setq org-roam-dailies-directory "journal/")


 ;; Bind this to C-c n I
 (defun org-roam-node-insert-immediate (arg &rest args)
   (interactive "P")
   (let ((args (cons arg args))
	    (org-roam-capture-templates (list (append (car org-roam-capture-templates)
						      '(:immediate-finish t)))))
     (apply #'org-roam-node-insert args)))

(with-eval-after-load 'org-roam
  (require 'org-roam-node)

 (defun my/org-roam-filter-by-tag (tag-name)
   (lambda (node)
     (member tag-name (org-roam-node-tags node))))

 (defun my/org-roam-list-notes-by-tag (tag-name)
   (mapcar #'org-roam-node-file
	      (seq-filter
	       (my/org-roam-filter-by-tag tag-name)
	       (org-roam-node-list))))

 (defun my/org-roam-refresh-agenda-list ()
   (interactive)
   (setq org-agenda-files (my/org-roam-list-notes-by-tag "Project")))

 (my/org-roam-refresh-agenda-list))


 (defun my/org-roam-project-finalize-hook ()
   "Adds the captured project file to `org-agenda-files' if the
	     capture was not aborted."
   ;; Remove the hook since it was added temporarily
   (remove-hook 'org-capture-after-finalize-hook #'my/org-roam-project-finalize-hook)

   ;; Add project file to the agenda list if the capture was confirmed
   (unless org-note-abort
     (with-current-buffer (org-capture-get :buffer)
	  (add-to-list 'org-agenda-files (buffer-file-name)))))


 (defun my/org-roam-find-project ()
   (interactive)
   ;; Add the project file to the agenda after capture is finished
   (add-hook 'org-capture-after-finalize-hook #'my/org-roam-project-finalize-hook)

   ;; Select a project file to open, creating it if necessary
   (org-roam-node-find
    nil
    nil
    (my/org-roam-filter-by-tag "Project")
    nil
    :templates
    '(("p" "project" plain
	  "* Goals\n\n%?\n\n* Tasks\n\n** TODO Add initial tasks\n\n* Dates\n\n"
	  :if-new (file+head "${slug}.org" "#+title: ${title}\n#+category: ${title}\n#+filetags: Project")
	  :unnarrowed t))))

 (global-set-key (kbd "C-c n p") #'my/org-roam-find-project)


 (defun my/org-roam-capture-inbox ()
   (interactive)
   (org-roam-capture- :node (org-roam-node-create)
			 :templates '(("i" "inbox" plain "* %?"
				       :if-new (file+head "Inbox.org" "#+title: Inbox\n")))))

 (global-set-key (kbd "C-c n b") #'my/org-roam-capture-inbox)


 (defun my/org-roam-capture-task ()
   (interactive)
   ;; Add the project file to the agenda after capture is finished
   (add-hook 'org-capture-after-finalize-hook #'my/org-roam-project-finalize-hook)

   ;; Capture the new task, creating the project file if necessary
   (org-roam-capture- :node (org-roam-node-read
				nil
				(my/org-roam-filter-by-tag "Project"))
			 :templates '(("p" "project" plain "** TODO %?"
				       :if-new (file+head+olp "${slug}.org"
							      "#+title: ${title}\n#+category: ${title}\n#+filetags: Project"
							      ("Tasks"))))))

 (global-set-key (kbd "C-c n t") #'my/org-roam-capture-task)



 (defun my/org-roam-copy-todo-to-today ()
   (interactive)
   (let ((org-refile-keep t) ;; Set this to nil to delete the original!
	    (org-roam-dailies-capture-templates
	     '(("t" "tasks" entry "%?"
		:if-new (file+head+olp "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\n" ("Tasks")))))
	    (org-after-refile-insert-hook #'save-buffer)
	    today-file
	    pos)

     ;; Check if the task is a habit by checking the STYLE property
     (unless (string= (org-entry-get nil "STYLE") "habit")
	  (save-window-excursion
	    (org-roam-dailies--capture (current-time) t)
	    (setq today-file (buffer-file-name))
	    (setq pos (point)))

	  ;; Only refile if the target file is different than the current file
	  (unless (equal (file-truename today-file)
			 (file-truename (buffer-file-name)))
	    (org-refile nil nil (list "Tasks" today-file nil pos))))))



 (add-to-list 'org-after-todo-state-change-hook
		 (lambda ()
		   (when (or (equal org-state "DONE")
			     (equal org-state "CANC"))
		     (my/org-roam-copy-todo-to-today))))

(use-package org-roam-ui
  :ensure t
  :after org-roam
  :config
  (setq org-roam-ui-sync-theme t
  org-roam-ui-follow t
  org-roam-ui-update-on-save t
  org-roam-ui-open-on-start t))

;;; ============================================
;;; Mdox Cheatsheet System
;;; ============================================

(define-minor-mode mr-x/mdox-reader-mode
  "Clean, distraction-free reading mode for Mdox documentation."
  :lighter " Mdox"
  (if mr-x/mdox-reader-mode
      (progn
        (read-only-mode 1)
        (org-modern-mode 1)
        (olivetti-mode 1)
        (setq-local olivetti-body-width 80)
        (display-line-numbers-mode 1)
        (visual-line-mode 1)
        (setq-local org-hide-emphasis-markers t)
        (setq-local header-line-format
                    (propertize " Mdox  [q] quit  [n/p] navigate  [/] search  [TAB] fold"
                                'face 'font-lock-comment-face))
        ;; Start collapsed — see everything at a glance
        (org-overview)
        (goto-char (point-min))
        ;; Evil keybindings — buffer-local so they override org-mode's
        (when (bound-and-true-p evil-mode)
          (evil-normal-state)
          (evil-local-set-key 'normal (kbd "q") #'quit-window)
          (evil-local-set-key 'normal (kbd "n") #'mr-x/mdox-next-heading)
          (evil-local-set-key 'normal (kbd "p") #'mr-x/mdox-prev-heading)
          (evil-local-set-key 'normal (kbd "/") #'consult-line)
          (evil-local-set-key 'normal (kbd "TAB") #'org-cycle)
          ))
    ;; Teardown
    (read-only-mode -1)
    (org-modern-mode -1)
    (olivetti-mode -1)
    (setq-local header-line-format nil)))

(defun mr-x/mdox-next-heading ()
  "Navigate to next heading and auto-expand it."
  (interactive)
  (org-next-visible-heading 1)
  (org-show-entry)
  (org-show-children))

(defun mr-x/mdox-prev-heading ()
  "Navigate to previous heading and auto-expand it."
  (interactive)
  (org-previous-visible-heading 1)
  (org-show-entry)
  (org-show-children))

(defun mr-x/mdox-view (id)
  "Open an org-roam node by ID in a pretty popper popup."
  (interactive)
  (let* ((node (org-roam-node-from-id id))
         (file (org-roam-node-file node))
         (buf (find-file-noselect file)))
    (with-current-buffer buf
      (goto-char (point-min))
      (mr-x/mdox-reader-mode 1))
    (select-window
     (display-buffer buf
                     '((display-buffer-in-side-window)
                       (side . bottom)
                       (window-height . 0.45))))))

(defun mr-x/mdox-search ()
  "Fuzzy search all Mdox nodes via org-roam-node-find."
  (interactive)
  (let ((org-roam-node-display-template
         "${title:60} ${tags:20}"))
    (org-roam-node-find nil "mdox")))

(defvar mr-x/shortcuts-file
  "~/roaming/notes/mr-x-rig-mdox.org"
  "Path to the rig reference file (shortcuts, commands, workflows).")

(defun mr-x/view-shortcuts ()
  "Open the shortcuts file in a pretty popper popup."
  (interactive)
  (let ((buf (find-file-noselect mr-x/shortcuts-file)))
    (with-current-buffer buf
      (goto-char (point-min))
      (mr-x/mdox-reader-mode 1))
    (select-window
     (display-buffer buf
                     '((display-buffer-in-side-window)
                       (side . bottom)
                       (window-height . 0.45))))))

(defun mr-x/search-shortcuts ()
  "Open shortcuts file and immediately search with consult-line."
  (interactive)
  (find-file mr-x/shortcuts-file)
  (mr-x/mdox-reader-mode 1)
  (consult-line))

;;; ============================================
;;; Mdox Format Spec & Tooling
;;; ============================================

;; --- Spec (single source of truth) ---
(defvar mr-x/mdox-spec
  '(:title-suffix "--Mdox"
    :directory "~/roaming/notes/"
    :required-headings ("Overview" "Quick Reference" "Concepts" "Patterns" "Gotchas" "Resources")
    :max-depth 3)
  "Canonical specification for Mdox document format.
All Mdox tooling (scaffolder, linter) derives from this spec.")

;; --- Scaffolder ---
(defun mr-x/mdox-new (topic)
  "Create a new Mdox document for TOPIC using the canonical spec."
  (interactive "sTopic: ")
  (let* ((slug (downcase (replace-regexp-in-string "[[:space:]]+" "-" (string-trim topic))))
         (filename (expand-file-name (concat slug "-mdox.org")
                                     (plist-get mr-x/mdox-spec :directory)))
         (id (org-id-uuid))
         (title (concat topic (plist-get mr-x/mdox-spec :title-suffix)))
         (headings (plist-get mr-x/mdox-spec :required-headings)))
    (when (file-exists-p filename)
      (user-error "Mdox already exists: %s" filename))
    (find-file filename)
    (insert ":PROPERTIES:\n"
            ":ID:       " id "\n"
            ":END:\n"
            "#+title: " title "\n")
    (dolist (h headings)
      (insert "\n* " h "\n"))
    (save-buffer)
    (goto-char (point-min))
    (re-search-forward "^\\* Overview$" nil t)
    (forward-line 1)
    (message "Created Mdox: %s" (file-name-nondirectory filename))))




(with-eval-after-load 'transient
  (transient-define-prefix mr-x/cheatsheet ()
    "Mr-X Cheatsheet — Mdox & shortcuts launcher."
    [["Emacs"
      ("e" "Emacs" (lambda () (interactive) (mr-x/mdox-view "60696404-C620-4C10-9B1D-6DA0A4B19514")))
      ("E" "Evil Mode" (lambda () (interactive) (mr-x/mdox-view "2EFEE7F2-9EBE-4588-944E-5E3465477B79")))
      ("o" "Org Agenda" (lambda () (interactive) (mr-x/mdox-view "A6851501-B979-4F4C-9D52-142FCCC8C587")))
      ("p" "Projectile" (lambda () (interactive) (mr-x/mdox-view "C58D019A-3C9F-463C-BAD0-2A77328C5B40")))
      ("l" "Emacs Lisp" (lambda () (interactive) (mr-x/mdox-view "2FB11BB4-5AF7-4200-8D83-0053368BB891")))]
     ["Dev"
      ("j" "Javascript" (lambda () (interactive) (mr-x/mdox-view "067AD924-848B-44B0-B909-5A35D8598E42")))
      ("r" "ReactJS" (lambda () (interactive) (mr-x/mdox-view "247FB555-C20C-4CCB-A42A-F137630A51C1")))
      ("c" "CSS" (lambda () (interactive) (mr-x/mdox-view "C6B93280-2829-4946-AA81-72223332450B")))
      ("P" "Python" (lambda () (interactive) (mr-x/mdox-view "32E94F61-0E46-45C5-AFAD-1EB96534C457")))
      ("C" "CLI & Shell" (lambda () (interactive) (mr-x/mdox-view "EAADE325-69B0-4884-B9DB-0E437316B490")))]
     ["Tools"
      ("y" "Yabai" (lambda () (interactive) (mr-x/mdox-view "D5C1411B-FEEB-402E-92A1-98B58F82AF2F")))
      ("s" "SKHD" (lambda () (interactive) (mr-x/mdox-view "1DB63C28-7F86-42E0-9E60-12D0F370B184")))
      ("k" "Sketchybar" (lambda () (interactive) (mr-x/mdox-view "9470C0E0-458B-48AC-9830-12DC5B6EE0D5")))
      ("d" "Docker" (lambda () (interactive) (mr-x/mdox-view "74250C33-EA8C-49E4-B5AC-B2BE2A062D52")))
      ("b" "Blender" (lambda () (interactive) (mr-x/mdox-view "3BBEC094-A3C9-4F58-9EE6-FC53D56D1987")))
      ("a" "Ableton" (lambda () (interactive) (mr-x/mdox-view "3C319C1A-E64C-4630-A525-4528E734AFBB")))]
     ["Architecture"
      ("A" "Software Arch" (lambda () (interactive) (mr-x/mdox-view "0DA3C504-2CDA-470B-B05C-280FAF6C22E7")))
      ("D" "DTO Pattern" (lambda () (interactive) (mr-x/mdox-view "8378BB8C-6F0F-43B8-9ACC-95E3B9CB780A")))
      ("R" "Repository" (lambda () (interactive) (mr-x/mdox-view "41D87ADB-DB16-46EB-9636-CAD3B28A1C20")))
      ("S" "Service Layer" (lambda () (interactive) (mr-x/mdox-view "6A588C06-3672-4C06-AD65-529B0A800E70")))
      ("F" "Entity Framework" (lambda () (interactive) (mr-x/mdox-view "C38E08C6-A169-41E0-9F38-BC5670227851")))]
     ["Search & Quick Access"
      ("/" "Search all Mdox" mr-x/mdox-search)
      ("?" "Full shortcuts file" mr-x/view-shortcuts)
      ("." "Search in shortcuts" mr-x/search-shortcuts)
      ("N" "New Mdox" mr-x/mdox-new)
      ("M" "Mdox index" (lambda () (interactive) (mr-x/mdox-view "A934531C-9903-4C97-A8D6-B47647B273B3")))]]))



(pcase system-type
  ('gnu/linux "It's Linux!")
  ('windows-nt "It's Windows!")
  ('darwin "It's macOS!"))

(if (daemonp)
    (message "Loading in the daemon!")
  (message "Loading in regular Emacs!"))

(defun mr-x/set-font-faces ()
  (message "Setting faces!")
  ;; Font family differs per machine (mrx has "Iosevka", others may only
  ;; have the Nerd Font build) — pick the first one actually installed.
  (set-face-attribute 'default nil
                      :font (cond ((find-font (font-spec :name "Iosevka")) "Iosevka")
                                  ((find-font (font-spec :name "Iosevka Nerd Font")) "Iosevka Nerd Font")
                                  ((find-font (font-spec :name "IosevkaTermSlab Nerd Font Mono")) "IosevkaTermSlab Nerd Font Mono")
                                  (t "Menlo"))
                      :height 240)
  ;; Enable SF Symbols rendering (macOS)
  (when (eq system-type 'darwin)
    (set-fontset-font t nil "SF Pro Display" nil 'append)))

  ;; Set the fixed pitch face

(if (daemonp)
    (add-hook 'after-make-frame-functions
		(lambda (frame)
		  (setq doom-modeline-icon t)
		  (with-selected-frame frame
		    (mr-x/set-font-faces))))
  (mr-x/set-font-faces))





(use-package exec-path-from-shell
  :ensure t
  :config
  ;; Run on macOS or when running as daemon (window-system is nil in daemon)
  (when (or (daemonp) (memq window-system '(mac ns x)))
    (exec-path-from-shell-initialize)))



(use-package no-littering
  :ensure t
  :config
  (setq custom-file (no-littering-expand-etc-file-name "custom.el"))
  (load custom-file 'noerror)
  (no-littering-theme-backups))




  (use-package vterm
    :ensure t
    :config
    ;; Prevent evil-collection from messing with vterm keys


    (setq vterm-scroll-to-bottom-on-output nil)
    (with-eval-after-load 'evil-collection
      (setq evil-collection-vterm-bind-escape-in-insert nil)
      (delete 'vterm evil-collection-mode-list)))

  (use-package multi-vterm
    :ensure t
    :after (evil vterm)
    :config
    ;; Set buffer name prefix to "vterm"
    (setq multi-vterm-buffer-name "vterm")
    ;; Set dedicated terminal height
    (setq multi-vterm-dedicated-window-height-percent 40)
    
    ;; Setup vterm with evil properly
    (add-hook 'vterm-mode-hook
              (lambda ()
                (setq-local evil-insert-state-cursor 'box)
                (evil-insert-state)))
    
    ;; Basic vterm configuration
    (setq vterm-keymap-exceptions nil)
    
    ;; Define keys after vterm-mode-map exists
    (with-eval-after-load 'vterm
      (define-key vterm-mode-map [return] #'vterm-send-return)
      
      ;; Pass through common terminal keys in insert mode
      (evil-define-key 'insert vterm-mode-map (kbd "C-e")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-f")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-a")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-v")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-b")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-w")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-u")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-d")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-n")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-m")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-p")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-j")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-k")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-r")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-t")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-g")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-c")      #'vterm--self-insert)
      (evil-define-key 'insert vterm-mode-map (kbd "C-SPC")    #'vterm--self-insert)
      
      ;; CMD+Backspace to clear line (send C-u to terminal)
      (evil-define-key 'insert vterm-mode-map (kbd "s-<backspace>") 
        (lambda () (interactive) (vterm-send-key "u" nil nil t)))
      
      ;; Option+Backspace to delete word (send M-DEL to terminal)  
      (evil-define-key 'insert vterm-mode-map (kbd "M-<backspace>")
        (lambda () (interactive) (vterm-send-key "<backspace>" nil t nil)))
      
      ;; Normal mode keys
      (evil-define-key 'normal vterm-mode-map (kbd ",c")       #'multi-vterm)
      (evil-define-key 'normal vterm-mode-map (kbd ",n")       #'multi-vterm-next)
      (evil-define-key 'normal vterm-mode-map (kbd ",p")       #'multi-vterm-prev)
      (evil-define-key 'normal vterm-mode-map (kbd "i")        #'evil-insert-resume)
      (evil-define-key 'normal vterm-mode-map (kbd "o")        #'evil-insert-resume)
      (evil-define-key 'normal vterm-mode-map (kbd "<return>") #'evil-insert-resume)
      
      ;; Paste in normal mode - send clipboard to vterm
      (evil-define-key 'normal vterm-mode-map (kbd "p")
        (lambda () (interactive)
          (vterm-send-string (current-kill 0))))
      
      ;; CMD+Enter to send/execute in both modes
      (evil-define-key 'normal vterm-mode-map (kbd "s-<return>") #'vterm-send-return)
      (evil-define-key 'insert vterm-mode-map (kbd "s-<return>") #'vterm-send-return)))




    ;; Optional: set the shell explicitly if needed
    ;; (setq vterm-shell "/bin/zsh")
    
    ;; Wrapper to open vterm in popper's popup position from the start
    (defun mr-x/vterm-popup ()
      "Open multi-vterm in popper's popup position."
      (interactive)
      (let ((buf (save-window-excursion
                   (multi-vterm)
                   (current-buffer))))
        (display-buffer buf)))

    (defun mr-x/vterm-in-dir ()
      "Open a vterm in a directory chosen via prompt."
      (interactive)
      (let ((default-directory (read-directory-name "vterm dir: ")))
        (multi-vterm)))

    (defun mr-x/vterm-buffer ()
      "Open multi-vterm in current window, bypassing popper."
      (interactive)
      (let ((buf (save-window-excursion
                   (multi-vterm)
                   (current-buffer))))
        (switch-to-buffer buf)))

    (defun mr-x/vterm-frame ()
      "Open multi-vterm in a new dedicated frame, free from popper."
      (interactive)
      (let ((buf (save-window-excursion
                   (multi-vterm)
                   (current-buffer)))
            (frame (make-frame `((name . ,(format "Terminal: %s" default-directory))
                                 (unsplittable . t)))))
        (select-frame-set-input-focus frame)
        (delete-other-windows)
        (switch-to-buffer buf)
        (set-window-dedicated-p (selected-window) t)
        ;; Tell popper this buffer is "raised" — removes POP status
        ;; and prevents popper from re-classifying it
        (setq-local popper-popup-status 'raised)))

    (defun mr-x/vterm-restart ()
      "Restart the current vterm in the same window and directory."
      (interactive)
      (unless (derived-mode-p 'vterm-mode)
        (user-error "Not in a vterm buffer"))
      (let ((dir default-directory)
            (old-buf (current-buffer)))
        (let ((default-directory dir))
          (vterm (generate-new-buffer-name "vterm")))
        (when (buffer-live-p old-buf)
          (kill-buffer old-buf))))

    (defun mr-x/vterm-homelab ()
      "Open a vterm and SSH into homelab."
      (interactive)
      (let ((buf (save-window-excursion
                   (multi-vterm)
                   (current-buffer))))
        (display-buffer buf)
        (with-current-buffer buf
          (vterm-send-string "ssh homelab")
          (vterm-send-return))))


  ;; (use-package multi-vterm
  ;; 	 :config
  ;; 	 (add-hook 'vterm-mode-hook
  ;; 			 (lambda ()
  ;; 			 (setq-local evil-insert-state-cursor 'box)
  ;; 			 (evil-insert-state)))

  ;; 	 (define-key vterm-mode-map [return]                      #'vterm-send-return)

  ;; 	 (setq vterm-keymap-exceptions nil))

(use-package ghostel
  :ensure (:host github :repo "dakra/ghostel"
		 :files ("lisp/*.el" "build.zig" "build.zig.zon" "symbols.map"
			 "src" "vendor" "etc")))





(defun mr-x/ports ()
  "Show listening TCP ports."
  (interactive)
  (async-shell-command "lsof -iTCP -sTCP:LISTEN -P -n" "*Ports*")
  (with-current-buffer "*Ports*"
    (setq-local truncate-lines t)))



    (use-package all-the-icons
      :ensure t
      :if (display-graphic-p)
      :config
      ;; all-the-icons ships its own fonts (not the Nerd fonts); auto-install
      ;; them on a fresh machine so icons render instead of tofu boxes.
      (unless (find-font (font-spec :family "all-the-icons"))
        (all-the-icons-install-fonts t)))

    (use-package doom-themes
      :ensure t
      :config
      (load-theme 'doom-gruvbox)
      ;; Match VSCode gruvbox JSX/TSX highlighting
      ;; Reference: https://github.com/jdinhify/vscode-theme-gruvbox
      ;; Colors: aqua2=#8ec07c, blue2=#83a598, yellow2=#fabd2f, fg2=#d5c4a1, fg4=#a89984
      (custom-set-faces
       ;; JSX tags should be aqua like VSCode (entity.name.tag -> aqua2)
       '(typescript-ts-jsx-tag-face ((t (:foreground "#8ec07c"))))
       ;; JSX attributes (type, placeholder, onChange) should be yellow (yellow2)
       '(typescript-ts-jsx-attribute-face ((t (:foreground "#fabd2f"))))
       ;; Functions aqua in VSCode gruvbox (entity.name.function -> yellow2, but called -> aqua2)
       '(font-lock-function-name-face ((t (:foreground "#8ec07c"))))
       '(font-lock-function-call-face ((t (:foreground "#8ec07c"))))
       ;; Properties/members (e.target.value) should be blue (blue2)
       '(font-lock-property-use-face ((t (:foreground "#83a598"))))
       '(font-lock-property-name-face ((t (:foreground "#83a598"))))
       ;; Variable references (isActive, count, etc.) should be blue (variable -> blue2)
       '(font-lock-variable-use-face ((t (:foreground "#83a598"))))
       ;; Operators (=, =>, etc.) should be aqua (keyword.operator -> aqua2)
       '(font-lock-operator-face ((t (:foreground "#8ec07c"))))
       ;; Brackets/braces {} should be lighter (brace -> fg2)
       '(font-lock-bracket-face ((t (:foreground "#d5c4a1"))))
       ;; General punctuation (fg4)
       '(font-lock-punctuation-face ((t (:foreground "#a89984"))))
       '(font-lock-delimiter-face ((t (:foreground "#a89984"))))
       ;; JSX tag delimiters <, >, </,  /> should be blue (punctuation.definition.tag -> blue2)
       '(jsx-tag-delimiter-face ((t (:foreground "#83a598"))))))

    ;; Define custom face for JSX tag delimiters
    (defface jsx-tag-delimiter-face
      '((t (:foreground "#83a598")))
      "Face for JSX tag delimiters like < > /> </"
      :group 'font-lock-faces)

    ;; Enable extra tree-sitter font-lock features for TSX/TS (like VSCode)
    (defun mr-x/tsx-ts-mode-setup ()
      "Enable additional font-lock features for tsx-ts-mode."
      ;; Enable extra font-lock features (function, bracket, delimiter, operator)
      (treesit-font-lock-recompute-features '(function bracket delimiter operator) nil)
      ;; Add custom tree-sitter rules
      (let ((lang (if (eq major-mode 'tsx-ts-mode) 'tsx 'typescript)))
        (setq treesit-font-lock-settings
          (append treesit-font-lock-settings
            (treesit-font-lock-rules
              ;; Member access properties (e.target.value)
              :language lang
              :feature 'property
              :override t
              '((member_expression
                 property: (property_identifier) @font-lock-property-use-face))
              ;; Variable references should be blue (like VSCode gruvbox)
              :language lang
              :feature 'variable-reference
              :override nil
              '((identifier) @font-lock-variable-use-face))
            ;; JSX tag delimiters - only for tsx
            (when (eq lang 'tsx)
              (treesit-font-lock-rules
                :language 'tsx
                :feature 'jsx-delimiter
                :override t
                '(;; Opening tag: <div>
                  (jsx_opening_element "<" @jsx-tag-delimiter-face)
                  (jsx_opening_element ">" @jsx-tag-delimiter-face)
                  ;; Closing tag: </div>
                  (jsx_closing_element "</" @jsx-tag-delimiter-face)
                  (jsx_closing_element ">" @jsx-tag-delimiter-face)
                  ;; Self-closing: <Input />
                  (jsx_self_closing_element "<" @jsx-tag-delimiter-face)
                  (jsx_self_closing_element "/>" @jsx-tag-delimiter-face)))))))
      ;; Add custom features to feature list level 3
      (unless (memq 'variable-reference (nth 2 treesit-font-lock-feature-list))
        (setf (nth 2 treesit-font-lock-feature-list)
              (cons 'variable-reference (nth 2 treesit-font-lock-feature-list))))
      (treesit-font-lock-recompute-features '(variable-reference) nil)
      ;; Enable jsx-delimiter feature (tsx only)
      (when (eq major-mode 'tsx-ts-mode)
        (unless (memq 'jsx-delimiter (nth 2 treesit-font-lock-feature-list))
          (setf (nth 2 treesit-font-lock-feature-list)
                (cons 'jsx-delimiter (nth 2 treesit-font-lock-feature-list))))
        (treesit-font-lock-recompute-features '(jsx-delimiter) nil))
      (font-lock-flush))
    (add-hook 'tsx-ts-mode-hook #'mr-x/tsx-ts-mode-setup)
    (add-hook 'typescript-ts-mode-hook #'mr-x/tsx-ts-mode-setup)

    (use-package doom-modeline
      :ensure t
      :init (doom-modeline-mode 1)
      :custom
      ;; Make modeline smaller and cleaner
      (doom-modeline-height 25)  ; Smaller height (default is 25)
      (doom-modeline-bar-width 3)  ; Thinner bar
      
      ;; Remove encoding to save space
      (doom-modeline-buffer-encoding nil)  ; Remove encoding indicator
      
      ;; Other space-saving options
      (doom-modeline-indent-info nil)  ; Remove indentation info
      (doom-modeline-minor-modes nil)  ; Hide minor modes (they take lots of space)
      (doom-modeline-buffer-file-name-style 'truncate-upto-root)  ; Shorter file paths
      
      ;; Keep useful stuff
      (doom-modeline-major-mode-icon t)  ; Keep major mode icon
      (doom-modeline-major-mode-color-icon t)  ; Colorful icons
      (doom-modeline-buffer-state-icon t)  ; Modified/saved state
      (doom-modeline-buffer-modification-icon t)  ; Show if modified
      (doom-modeline-lsp t)  ; Keep LSP indicator
      (doom-modeline-github nil)  ; Remove github notifications (saves space)
      (doom-modeline-persp-name nil)  ; Remove perspective name if not using
      (doom-modeline-modal-modern-icon nil)  ; Your existing setting
      
      ;; Performance
      (doom-modeline-checker-simple-format t)  ; Simpler error format
      (doom-modeline-env-version nil)  ; Don't show environment version
      (doom-modeline-unicode-fallback t)  ; Use unicode when icons unavailable

      :config
      ;; Commented out to prevent modeline shrinking when frame loses focus
      ;; (set-face-attribute 'mode-line nil :height 0.9)
      ;; (set-face-attribute 'mode-line-inactive nil :height 0.9)
      
      ;; Minimal modeline for agent-shell (just evil state, buffer name, line number)
      (doom-modeline-def-segment agent-shell-refs
        "Show 📎N when refs are attached in agent-shell."
        (when (and (derived-mode-p 'agent-shell-mode)
                   (bound-and-true-p agent-shell-refs--list))
          (propertize (format " 📎%d" (length agent-shell-refs--list))
                      'face 'agent-shell-refs-modeline-face
                      'help-echo "Attached references — click to preview"
                      'mouse-face 'mode-line-highlight
                      'local-map (let ((map (make-sparse-keymap)))
                                   (define-key map [mode-line mouse-1]
                                               #'agent-shell-refs-preview)
                                   map))))

      (doom-modeline-def-segment agent-shell-inbox
        "Show 📷 with a countdown while armed for an incoming phone screenshot.
The package's 1s poll timer forces modeline updates, so this ticks."
        (when (and (fboundp 'agent-shell-inbox-armed-p)
                   (agent-shell-inbox-armed-p))
          (let ((left (agent-shell-inbox-remaining-seconds)))
            (propertize (format " 📷%s %d:%02d"
                                (if (bound-and-true-p agent-shell-inbox--multi) "+" "")
                                (/ left 60) (% left 60))
                        'face 'shadow
                        'help-echo "Waiting for a phone screenshot — click to disarm"
                        'mouse-face 'mode-line-highlight
                        'local-map (let ((map (make-sparse-keymap)))
                                     (define-key map [mode-line mouse-1]
                                                 #'agent-shell-inbox-disarm)
                                     map)))))

      (doom-modeline-def-modeline 'agent-shell-minimal
        '(bar modals buffer-info agent-shell-refs agent-shell-inbox)
        '(buffer-position))

      (with-eval-after-load 'nerd-icons
        (add-to-list 'nerd-icons-mode-icon-alist
                     '(agent-shell-mode nerd-icons-mdicon "nf-md-robot_happy"
                                        :face nerd-icons-silver :height 1.2)))

      (add-hook 'agent-shell-mode-hook
                (lambda ()
                  (doom-modeline-set-modeline 'agent-shell-minimal)
                  (face-remap-add-relative 'default :background "#1d2021"))))


    ;; (set-face-attribute 'default nil :font "JuliaMono" :height 280)

    (defun mr-x/general-setup ()
      (display-line-numbers-mode 1))

    (defun mr-x/new-scratch ()
      "Create a new scratch buffer with a unique name."
      (interactive)
      (let ((n 1)
            bufname)
        (while (progn
                 (setq bufname (format "*scratch<%d>*" n))
                 (get-buffer bufname))
          (setq n (1+ n)))
        (switch-to-buffer (get-buffer-create bufname))
        (org-mode)))

    (defun mr-x/surf-web ()
      "Open xwidget-webkit with Google."
      (interactive)
      (xwidget-webkit-browse-url "https://google.com"))

    (defun mr-x/surf-web-other-window ()
      "Open xwidget-webkit with Google in other window."
      (interactive)
      (split-window-right)
      (other-window 1)
      (xwidget-webkit-browse-url "https://google.com"))

    (defun mr-x/surf-link-at-point ()
      "Open URL at point in xwidget-webkit."
      (interactive)
      (if-let ((url (thing-at-point 'url)))
          (xwidget-webkit-browse-url url)
        (message "No URL at point")))

    (defun mr-x/surf-url-other-window ()
      "Prompt for URL and open in other window."
      (interactive)
      (split-window-right)
      (other-window 1)
      (call-interactively #'xwidget-webkit-browse-url))


     (use-package xwwp
       :ensure t
       :after evil
       :custom
       (xwwp-follow-link-completion-system 'default)
       :config
       (evil-define-key 'normal xwidget-webkit-mode-map
         "f" 'xwwp-follow-link))


    (add-hook 'text-mode-hook #'mr-x/general-setup)
    (add-hook 'prog-mode-hook #'mr-x/general-setup)

  

  					  ; opacity - same value for focused and unfocused (consistent transparency)
    (set-frame-parameter (selected-frame) 'alpha '(80 80))
    (add-to-list 'default-frame-alist '(alpha-background . 20))

    (defun my/clone-buffer-to-new-frame ()
      "Spawn a new frame showing the current buffer."
      (interactive)
      (let ((buf (current-buffer)))
        (select-frame-set-input-focus (make-frame))
        (switch-to-buffer buf)))
    (global-set-key (kbd "s-M-E") #'my/clone-buffer-to-new-frame)

  					  ; keybindings section
    (global-unset-key (kbd "s-t")) ; Disable macOS font panel (ns-popup-font-panel)
    (global-set-key (kbd "C-<escape>") #'universal-argument)
    (global-set-key (kbd "C-c d") 'diff-buffer-with-file)
    (global-set-key (kbd "<escape>") 'keyboard-escape-quit) ; Make ESC quit prompts
    (global-set-key (kbd "C-c l") #'org-store-link) ; Suggested Key-binding from org-manual
    (global-set-key (kbd "C-c a") #'org-agenda) ; Suggested Key-binding from org-manual
    (global-set-key (kbd "C-c c") #'org-capture) ; Suggested Key-binding from org-manual







    (setq inhibit-startup-message t) ; Disable the startup message
    (scroll-bar-mode -1) ; Disable the visible scrollbar
    (tool-bar-mode -1)   ; Disable the toolbar
    (tooltip-mode -1)    ; Disable tooltips
    (menu-bar-mode -1)   ; Disable the menu bar
    (set-fringe-mode 10) ; Give some breathing room

  ;; Disable native fullscreen behavior
  (setq ns-use-native-fullscreen nil)

  ;; Make new frames tile properly instead of floating
  (setq ns-pop-up-frames nil)

  ;; Prevent Emacs from resizing frames
  (setq frame-resize-pixelwise t)

  ;; Secondary emacsclient frames get title bars with a frame number so
  ;; scratch frames are tellable apart.  The FIRST/main GUI frame stays
  ;; clean — undecorated, no title.  Guard is "am I the sole GUI frame?"
  ;; rather than a counter, so closing the main frame and spawning a new
  ;; one keeps the new main clean too.
  (defvar mr-x/frame-counter 0)
  (defun mr-x/decorate-secondary-frame ()
    "Give secondary client frames a title bar + number; keep the main frame clean."
    (when (> (length (seq-filter #'display-graphic-p (frame-list))) 1)
      (cl-incf mr-x/frame-counter)
      (set-frame-parameter nil 'undecorated-round nil)
      (set-frame-parameter nil 'title
                           (format "Emacs #%d" mr-x/frame-counter))))
  (add-hook 'server-after-make-frame-hook #'mr-x/decorate-secondary-frame)



  (use-package perspective
  :ensure t
  :bind
  ("C-x C-i" . persp-ibuffer)
  :custom
  (persp-mode-prefix-key (kbd "C-x M-x"))  ; keep original prefix for compatibility
  :init
  (setq persp-show-modestring nil)
  (persp-mode)
  :config
  ;; Use consult-buffer with perspective filtering + preview
  (defun mr-x/persp-consult-buffer ()
    "Switch buffer restricted to current perspective, with preview."
    (interactive)
    (consult-buffer '(persp-consult-source)))
  (global-set-key (kbd "C-x C-b") #'mr-x/persp-consult-buffer)
  ;; Hide the GLOBAL perspective (used internally by persp-add-buffer-to-frame-global)
  (define-advice persp-names (:filter-return (names) hide-global)
    (cl-remove persp-frame-global-perspective-name names :test #'string=))

  ;; ── Sketchybar perspective integration ─────────────────────
  (defvar mr-x/sketchybar-persp--timer nil
    "Debounce timer for sketchybar perspective updates.")

  (defun mr-x/sketchybar-update-persp--do ()
    "Actually push perspective state to sketchybar (called by debounce timer)."
    (setq mr-x/sketchybar-persp--timer nil)
    (when (and (bound-and-true-p persp-mode)
               (not (string-match-p "SCRATCHPAD"
                                    (or (frame-parameter nil 'title) ""))))
      (let* ((active (persp-current-name))
             (all-names (persp-names))
             (all-str (mapconcat #'identity all-names ","))
             (frame-title (or (frame-parameter nil 'title) "")))
        (start-process "sketchybar-persp" nil "bash" "-c"
                       (format "sketchybar --trigger emacs_persp_update EMACS_PERSP_NAME=%s EMACS_PERSP_ALL=%s EMACS_PERSP_FRAME_TITLE=%s"
                               (shell-quote-argument active)
                               (shell-quote-argument all-str)
                               (shell-quote-argument frame-title))))))

  (defun mr-x/sketchybar-update-persp (&rest _)
    "Push current perspective name to sketchybar (debounced 0.15s)."
    (when mr-x/sketchybar-persp--timer
      (cancel-timer mr-x/sketchybar-persp--timer))
    (setq mr-x/sketchybar-persp--timer
          (run-at-time 0.15 nil #'mr-x/sketchybar-update-persp--do)))

  (defun mr-x/sketchybar-persp-name-for-title (title)
    "Return the perspective name for the Emacs frame matching TITLE.
Called by sketchybar plugin via emacsclient --eval as fallback."
    (let ((result "main"))
      (dolist (frame (frame-list))
        (when (string= (frame-parameter frame 'title) title)
          (setq result (with-selected-frame frame (persp-current-name)))))
      result))

  (defun mr-x/sketchybar-hide-persp ()
    "Hide all emacs_persp items in sketchybar."
    (start-process "sketchybar-persp-hide" nil "bash" "-c"
                   "for i in {1..10}; do sketchybar --set emacs_persp.$i drawing=off 2>/dev/null; done"))

  (add-hook 'persp-switch-hook #'mr-x/sketchybar-update-persp)
  (add-hook 'persp-activated-hook #'mr-x/sketchybar-update-persp)

  (add-function :after after-focus-change-function
                (lambda ()
                  (when (frame-focus-state)
                    (mr-x/sketchybar-update-persp))))

  (add-hook 'delete-frame-functions
            (lambda (_frame)
              (run-at-time 0.5 nil #'mr-x/sketchybar-update-persp)))

  (add-hook 'kill-emacs-hook #'mr-x/sketchybar-hide-persp))

  ;; ── Sketchybar org-clock integration ──────────────────────
  (defvar mr-x/sketchybar-clock--timer nil
    "Debounce timer for sketchybar clock updates.")

  (defvar mr-x/sketchybar-clock--tick-timer nil
    "Repeating timer to update elapsed time while clocked in.")

  (defun mr-x/sketchybar-update-clock--do ()
    "Push org-clock state to sketchybar."
    (setq mr-x/sketchybar-clock--timer nil)
    (if (and (fboundp 'org-clocking-p) (org-clocking-p))
        (let* ((task (substring-no-properties org-clock-heading))
               (elapsed (org-duration-from-minutes (org-clock-get-clocked-time))))
          (start-process "sketchybar-clock" nil "bash" "-c"
                         (format "sketchybar --trigger emacs_clock_update EMACS_CLOCK_TASK=%s EMACS_CLOCK_TIME=%s"
                                 (shell-quote-argument task)
                                 (shell-quote-argument elapsed))))
      (start-process "sketchybar-clock" nil "bash" "-c"
                     "sketchybar --trigger emacs_clock_update EMACS_CLOCK_TASK=__NONE__")))

  (defun mr-x/sketchybar-update-clock (&rest _)
    "Push org-clock state to sketchybar (debounced 0.15s)."
    (when mr-x/sketchybar-clock--timer
      (cancel-timer mr-x/sketchybar-clock--timer))
    (setq mr-x/sketchybar-clock--timer
          (run-at-time 0.15 nil #'mr-x/sketchybar-update-clock--do)))

  (defun mr-x/sketchybar-clock-start-tick ()
    "Start a 60s repeating timer to update elapsed time in sketchybar."
    (mr-x/sketchybar-clock-stop-tick)
    (setq mr-x/sketchybar-clock--tick-timer
          (run-at-time 60 60 #'mr-x/sketchybar-update-clock))
    (mr-x/sketchybar-update-clock))

  (defun mr-x/sketchybar-clock-stop-tick ()
    "Stop the repeating clock timer and hide the item."
    (when mr-x/sketchybar-clock--tick-timer
      (cancel-timer mr-x/sketchybar-clock--tick-timer)
      (setq mr-x/sketchybar-clock--tick-timer nil))
    (mr-x/sketchybar-update-clock))

  (add-hook 'org-clock-in-hook #'mr-x/sketchybar-clock-start-tick)
  (add-hook 'org-clock-out-hook #'mr-x/sketchybar-clock-stop-tick)
  (add-hook 'org-clock-cancel-hook #'mr-x/sketchybar-clock-stop-tick)
  (add-hook 'kill-emacs-hook
            (lambda ()
              (when mr-x/sketchybar-clock--tick-timer
                (cancel-timer mr-x/sketchybar-clock--tick-timer))
              (start-process "sketchybar-clock-hide" nil "bash" "-c"
                             "sketchybar --trigger emacs_clock_update EMACS_CLOCK_TASK=__NONE__")))

  ;; Global scratch buffer — shared across all perspectives
  (setq mr-x/global-scratch-header
    "# and I've been global, so there's nothing foreign\n\n")

  (defun mr-x/global-scratch ()
    "Switch to a global scratch buffer shared across all perspectives."
    (interactive)
    (let ((buf (get-buffer-create "*global-scratch*")))
      (with-current-buffer buf
        (unless (derived-mode-p 'org-mode)
          (org-mode)
          (insert mr-x/global-scratch-header)
          (goto-char (point-max))))
      (persp-add-buffer-to-frame-global buf)
      (switch-to-buffer buf)))



  (defun mr-x/org-mode-visual-fill ()
    (setq visual-fill-column-width 100
	  visual-fill-column-center-text t)
    (visual-fill-column-mode 1))

  (use-package visual-fill-column
    :ensure t
    :config
    (add-hook 'org-mode-hook #'mr-x/org-mode-visual-fill))

  ;; Progressive ESC — peels back UI state layer by layer instead of hard quit
  ;; Inspired by Gleek's escape-quit (https://github.com/Gleek/.emacs)
  (defvar mr-x/escape-hook nil
    "Hook run by `mr-x/escape-quit'. If any function returns non-nil, stop there.")

  (defun mr-x/escape-quit (&optional interactive)
    "Layered escape: minibuffer > region > escape-hook > keyboard-quit."
    (interactive (list 'interactive))
    (cond
     ;; 1. Quit minibuffer if active
     ((minibuffer-window-active-p (minibuffer-window))
      (when interactive (setq this-command 'abort-recursive-edit))
      (abort-recursive-edit))
     ;; 2. Deactivate active region/selection
     ((region-active-p)
      (let (select-active-regions) (deactivate-mark)) t)
     ;; 3. Let hooked packages (which-key, popups, etc.) handle it
     ((run-hook-with-args-until-success 'mr-x/escape-hook))
     ;; 4. Don't interrupt macros
     ((or defining-kbd-macro executing-kbd-macro) nil)
     ;; 5. Fall back to regular keyboard-quit
     ((unwind-protect (keyboard-quit)
        (when interactive (setq this-command 'keyboard-quit))))))

  (global-set-key [remap keyboard-quit] #'mr-x/escape-quit)
  (global-set-key (kbd "<escape>") #'mr-x/escape-quit)

  ;; Point Stack — cursor breadcrumbs for navigation jumps
  ;; Auto-saves position before xref, imenu, isearch, consult-ripgrep, etc.
  ;; Vendored from https://github.com/Gleek/.emacs/blob/master/packages/point-stack.el
  (use-package point-stack
    :ensure nil
    :bind (("s-[" . point-stack-pop)
           ("s-]" . point-stack-forward-stack-pop))
    :config
    (point-stack-setup-advices))


  ;; Ultra-scroll — smooth pixel scrolling for trackpad/wheel
  (use-package ultra-scroll
    :ensure (:host github :repo "jdtsmith/ultra-scroll")
    :bind (("C-<wheel-down>" . nil)
           ("C-<wheel-up>" . nil)
           ("C-M-<wheel-down>" . nil)
           ("C-M-<wheel-up>" . nil))
    :init
    (setq scroll-conservatively 99
          scroll-margin 0)
    :config
    (ultra-scroll-mode 1))

  ;; Rotate windows — cycle buffer contents across panes
  ;; From Gleek's core-window.el
  (defun mr-x/rotate-windows (arg)
    "Rotate buffer contents across windows. Prefix arg reverses direction."
    (interactive "P")
    (if (not (> (count-windows) 1))
        (message "You can't rotate a single window!")
      (let* ((rotate-times (prefix-numeric-value arg))
             (direction (if (or (< rotate-times 0) (equal arg '(4)))
                            'reverse 'identity)))
        (dotimes (_ (abs rotate-times))
          (dotimes (i (- (count-windows) 1))
            (let* ((w1 (elt (funcall direction (window-list)) i))
                   (w2 (elt (funcall direction (window-list)) (+ i 1)))
                   (b1 (window-buffer w1))
                   (b2 (window-buffer w2))
                   (s1 (window-start w1))
                   (s2 (window-start w2))
                   (p1 (window-point w1))
                   (p2 (window-point w2)))
              (set-window-buffer-start-and-point w1 b2 s2 p2)
              (set-window-buffer-start-and-point w2 b1 s1 p1)))))))

  ;; Toggle window fullscreen — maximize current window or restore layout
(defvar mr-x/window-fullscreen-config nil
  "Saved window config for fullscreen toggle.")

(defun mr-x/toggle-window-fullscreen ()
  "Toggle between single-window fullscreen and previous layout."
  (interactive)
  (if (and mr-x/window-fullscreen-config (= (count-windows) 1))
      (set-window-configuration mr-x/window-fullscreen-config)
    (setq mr-x/window-fullscreen-config (current-window-configuration))
    (delete-other-windows)))

;; Keyfreq — track command usage frequency
  (use-package keyfreq
    :ensure t
    :defer 2
    :config
    (keyfreq-mode 1)
    (keyfreq-autosave-mode 1)
    (setq keyfreq-excluded-commands
          '(self-insert-command
            org-self-insert-command
            next-line
            previous-line
            mwheel-scroll)))

  ;; ESUP — Emacs Start Up Profiler
  (use-package esup
    :ensure t
    :defer t)

  ;; Visual bell — flash an eye icon via Hammerspoon (native macOS transparency)
  (defun mr-x/visual-bell ()
    "Flash an eye icon via Hammerspoon's hs.canvas overlay.
Guarded by a `pgrep' check: the hs CLI pops a blocking \"Hammerspoon is
not running — Launch?\" dialog whenever it can't reach Hammerspoon (e.g.
the login race before Hammerspoon has started), and the bell fires
constantly, so only invoke it when Hammerspoon is actually running."
    (start-process "bell-icon" nil "sh" "-c"
                   "pgrep -xq Hammerspoon && exec hs -c 'showBellIcon()'"))

  (setq ring-bell-function #'mr-x/visual-bell)
  (fset 'yes-or-no-p 'y-or-n-p)

  ;; Auto-revert mode to automatically refresh buffers when files change on disk
  (global-auto-revert-mode 1)
  (setq global-auto-revert-non-file-buffers t)

  ;; DISABLED — this was swallowing echo-area messages too aggressively.
  ;; ;; Suppress echo-area messages while the minibuffer is active so they don't
  ;; ;; clobber what you're typing.  Messages still go to *Messages*.
  ;; (defun mr-x/suppress-message-in-minibuffer (message)
  ;;   "Swallow MESSAGE display when the minibuffer is in use."
  ;;   (when (minibufferp (window-buffer (minibuffer-window)))
  ;;     t))
  ;; (add-to-list 'set-message-functions #'mr-x/suppress-message-in-minibuffer)

  (use-package highlight
    :ensure t)

  ;; Never display acp stderr buffers in a window
  (add-to-list 'display-buffer-alist
               '("\\`acp-client-stderr"
                 (display-buffer-no-window)
                 (allow-no-window . t)))

  ;; Agent-shell conversations always land in the major-pane, no matter
  ;; which code path displays them (agent-shell itself, agent-recall
  ;; resume, anything calling display-buffer/pop-to-buffer).  The action
  ;; fn reuses the pane window when visible, creates it otherwise, and
  ;; keeps major-pane state (chrome, s-i toggle) in sync.  It is
  ;; autoloaded from major-pane's :init, so this entry is safe even
  ;; before major-pane loads.
  (add-to-list 'display-buffer-alist
               '("Claude Agent @" (major-pane-display-buffer-action)))

  ;; The pane window is soft-dedicated: display-buffer/pop-to-buffer
  ;; won't hijack it for random buffers (help, grep, magit, ...).
  ;; 'prompt keeps a deliberate escape hatch for STRONG dedication paths.
  (setq switch-to-buffer-in-dedicated-window 'prompt)

  ;; ...and this flag extends that protection to the ENTIRE
  ;; switch-to-buffer family (SPC b b, consult-buffer, find-file, file
  ;; links, everything) in one shot: switching routes through the
  ;; display-buffer machinery, whose same-window action declines
  ;; dedicated windows — so from the pane, buffers open in the main
  ;; area with focus following.  In normal (undedicated) windows the
  ;; behavior is unchanged.  Deliberate pane takeover: SPC & b
  ;; (major-pane-capture-buffer).
  (setq switch-to-buffer-obey-display-actions t)

  ;; Fallback for code that reads this variable directly; the
  ;; display-buffer-alist entry above takes precedence when it matches.
  (setq agent-shell-display-action
        '((display-buffer-in-direction)
          (direction . left)
          (window-width . 0.30)))

  ;; Popper for popup buffer management
  (use-package popper
    :ensure t
    :demand t  ;; Load at startup so popup rules are active immediately
    :bind (("C-`"     . popper-toggle)
           ("C-<tab>" . popper-cycle)
           ("C-M-`"   . popper-toggle-type))
    :init
    ;; Group popups by perspective
    (setq popper-group-function #'popper-group-by-perspective)
    (setq popper-reference-buffers
          '("\\*Messages\\*"
            "\\*Warnings\\*"
            "\\*Compile-Log\\*"
            "\\*Backtrace\\*"
            "\\*evil-registers\\*"
            "\\*Apropos\\*"
            "\\*scratch\\*"
            "\\*Help\\*"
            "\\*helpful.*\\*"
            "\\*vterm.*\\*"
            "\\*compilation\\*"
            help-mode
            helpful-mode
            compilation-mode
            vterm-mode
            "\\*xref\\*"
            xref--xref-buffer-mode
            ;; Mdox viewer buffers
            ".*--[Mm]dox.*"
            ".*shortcuts.*\\.org$"
            ;; Agent shell manager
            "\\*Agent-Shell Buffers\\*"
            agent-shell-manager-mode
            "\\*Async Shell Command\\*"
            ;; DevDocs
            devdocs-mode))
    :config
    (setq popper-display-control t)
    (setq popper-display-function #'popper-select-popup-at-bottom)
    ;; Use Cmd+Ctrl+N for dispatch keys (macOS intercepts M-N)
    (setq popper-echo-dispatch-keys '("s-C-1" "s-C-2" "s-C-3" "s-C-4" "s-C-5"
                                       "s-C-6" "s-C-7" "s-C-8" "s-C-9" "s-C-0"))
    ;; Give the agent-shell manager a taller popup (~40% of frame)
    (setq popper-window-height
          (lambda (win)
            (let ((buf-name (buffer-name (window-buffer win)))
                  (buf-mode (buffer-local-value 'major-mode (window-buffer win))))
              (cond
               ((string-match-p "\\*Agent-Shell Buffers\\*" buf-name)
                (floor (frame-height) 2.5))
               ((eq buf-mode 'devdocs-mode)
                (floor (frame-height) 2.5))
               (t (popper--fit-window-height win))))))
    (popper-mode +1)
    (popper-echo-mode +1))


(setq initial-major-mode 'org-mode)
(setq initial-scratch-message "\
# Clear your mind young one.")



    (use-package general
      :ensure t
      :demand t
      :config
      ;; allow for shorter bindings -- e.g., just using things like nmap alone without general-* prefix
      (general-evil-setup t)

      ;; To automatically prevent Key sequence starts with a non-prefix key errors without the need to
      ;; explicitly unbind non-prefix keys, you can add (general-auto-unbind-keys) to your configuration
      ;; file. This will advise define-key to unbind any bound subsequence of the KEY. Currently, this
      ;; will only have an effect for general.el key definers. The advice can later be removed with
      ;; (general-auto-unbind-keys t).
      (general-auto-unbind-keys))

    (with-eval-after-load 'general
      (general-create-definer mr-x/leader-def
        :states '(normal visual motion emacs insert)
        :keymaps 'override
        :prefix "SPC"
        :global-prefix "C-SPC"))

    (with-eval-after-load 'general
      (mr-x/leader-def
        "a" '(:ignore t :wk "agenda")
        "a a" '(org-agenda :wk "dispatcher")
        "a c" '(mr-x/org-agenda-custom :wk "classic")
        "a d" '(mr-x/org-agenda-dashboard :wk "dashboard")
        "a f" '(mr-x/org-agenda-focus :wk "focus")
        "a v" '(mr-x/org-agenda-full :wk "full view")
        ;; "m" 'mu4e
        "f" 'link-hint-open-link
        "p" 'projectile-command-map
        "w" '(:keymap evil-window-map :package evil :wk "window")
        "h" 'winner-undo
        "l" 'winner-redo
        ;; "s" 'mr-x/toggle-shortcuts
        "S" '(mr-x/new-scratch :wk "new scratch")
        ;; "v" 'multi-vterm
        "e" '((lambda () (interactive) (find-file (expand-file-name "~/.dotfiles/macos/emacs/.emacs.d/emacs.org"))) :wk "emacs.org")
        "t" '(mr-x/test-environment :wk "Test environment")
        "u" '(universal-argument :wk "universal arg")
        "," '(mr-x/mode-hydra :wk "mode hydra"))

      (with-eval-after-load 'evil
        (define-key evil-window-map "m" #'mr-x/toggle-window-fullscreen))

      (defun mr-x/mode-hydra ()
        "Launch the hydra for the current major mode."
        (interactive)
        (cond
         ((derived-mode-p 'org-agenda-mode) (hydra-org-agenda/body))
         ((derived-mode-p 'org-mode) (hydra-org/body))
         ((derived-mode-p 'pdf-view-mode) (hydra-pdf/body))
         ((derived-mode-p 'agent-shell-manager-mode) (hydra-agent/body))
         ((derived-mode-p 'agent-shell-mode) (hydra-agent/body))
         ((derived-mode-p 'dired-mode) (hydra-dired/body))
         ((derived-mode-p 'Info-mode) (hydra-info/body))
         ((derived-mode-p 'ediff-mode) (hydra-ediff/body))
         ((derived-mode-p 'prog-mode) (hydra-fold/body))
         (t (message "No hydra for %s" major-mode))))

      ;; Dynamic workspace bindings (SPC 1-9)
      (dotimes (i 9)
        (let ((n (1+ i)))
          (eval `(mr-x/leader-def
                   ,(number-to-string n)
                   '((lambda () (interactive) (persp-switch-by-number ,n))
                     :wk ,(format "workspace %d" n)))
                t)))


      (defun mr-x/test-environment ()
        "Spawn agent-shell on left, dired ~/roaming/sandbox on right."
        (interactive)
        (delete-other-windows)
        (dired "~/roaming/sandbox")
        (split-window-horizontally)
        (agent-shell)
        (balance-windows))

      (mr-x/leader-def
        "d" '(:ignore t :wk "Dired")
        "d d" '(dired :wk "Open Dired")
        "d j" '(dired-jump :wk "Dired jump to current")
        "d h" '((lambda () (interactive) (dired "~/")) :wk "Dired home")
        "d r" '((lambda () (interactive) (dired "~/roaming")) :wk "Dired roaming")
        "d e" '((lambda () (interactive) (dired "~/.dotfiles")) :wk "Dired dotfiles")
        "d s" '((lambda () (interactive) (dired "~/shared")) :wk "Dired shared")
        "d w" '((lambda () (interactive) (dired "/ssh:vengeance:/c/Users/mnand/dotfiles/")) :wk "Dired Windows dotfiles")
        "d H" '(dired-omit-mode :wk "Dired Omit Mode")
        "d p" '(dired-preview-global-mode :wk "Toggle preview")
        "d f" '(dwim-shell-commands-macos-reveal-in-finder :wk "Reveal in Finder")
        "d o" '(dwim-shell-commands-macos-open-with :wk "Open with..."))

      (mr-x/leader-def
        "o" '(:ignore t :wk "OS")
        "o d" '(dwim-shell-commands-macos-toggle-dark-mode :wk "Toggle dark mode")
        "o c" '(dwim-shell-commands-macos-caffeinate :wk "Caffeinate")
        "o s" '(dwim-shell-commands-macos-screenshot-window :wk "Screenshot window")
        "o r" '(dwim-shell-commands-macos-ocr-text-from-image :wk "OCR from image")
        "o R" '(dwim-shell-commands-macos-ocr-text-from-desktop-region :wk "OCR from screen")
        "o k" '(dwim-shell-commands-kill-process :wk "Kill process")
        "o t" '(dwim-shell-commands-macos-empty-trash :wk "Empty trash"))

      (mr-x/leader-def
        "b" '(:ignore t :wk "buffer")
        "b b" '(mr-x/persp-consult-buffer :wk "switch buffer")
        "b k" '(kill-current-buffer :wk "kill this buffer")
        "b K" '(kill-buffer-and-window :wk "kill buffer and window")
        "b r" '(revert-buffer :wk "revert buffer")
        "b e" '(eval-buffer :wk "eval buffer")
        "b g" '(mr-x/global-scratch :wk "global scratch"))

      (defun mr-x/copy-last-message ()
        "Copy the last line from *Messages* to the kill ring and clipboard."
        (interactive)
        (with-current-buffer "*Messages*"
          (goto-char (point-max))
          (forward-line -1)
          (let ((line (string-trim (thing-at-point 'line t))))
            (kill-new line)
            (message "Copied: %s" line))))

      (mr-x/leader-def
        "y" '(:ignore t :wk "yank")
        "y m" '(mr-x/copy-last-message :wk "copy last message"))

      (mr-x/leader-def
        "v" '(:ignore t :wk "vterm")
        "v v" '(mr-x/vterm-popup :wk "vterm popup")
        "v b" '(mr-x/vterm-buffer :wk "vterm buffer")
        "v f" '(mr-x/vterm-frame :wk "vterm frame")
        "v d" '(mr-x/vterm-in-dir :wk "vterm in dir")
        "v n" '(multi-vterm-next :wk "multi-vterm-next")
        "v p" '(multi-vterm-prev :wk "multi-vterm-prev")
        "v `" '(multi-vterm-dedicated-toggle :wk "multi-vterm-dedicated-toggle")
        "v V" '(mr-x/spawn-project-terminal-frame :wk "project terminal frame")
        "v r" '(mr-x/vterm-restart :wk "restart vterm")
        "v h" '(mr-x/vterm-homelab :wk "homelab"))

      (mr-x/leader-def
        "s" '(:ignore t :wk "streaming")
        "s y" '(ytr :wk "YouTube radio"))

      ;; Smart new shell: replace window when already in agent-shell
      (defun mr-x/agent-shell--display-new (shell-buffer)
        "Show SHELL-BUFFER: replace current window when already in an
agent-shell, otherwise pop to it. Honours viewport interaction."
        (if (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                            'agent-shell-viewport-edit-mode)
            ;; Already in agent-shell: replace current window
            (if agent-shell-prefer-viewport-interaction
                (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
              (switch-to-buffer shell-buffer))
          ;; Not in agent-shell: use normal display
          (if agent-shell-prefer-viewport-interaction
              (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
            (pop-to-buffer shell-buffer))))

      (defun mr-x/agent-shell-new-smart ()
        "Create new agent shell, replacing current window if already in agent-shell."
        (interactive)
        (require 'agent-shell)
        (let* ((config (or (and (fboundp 'agent-shell--resolve-preferred-config)
                                (agent-shell--resolve-preferred-config))
                           (agent-shell-select-config :prompt "Start new agent: ")
                           (error "No agent config found")))
               (shell-buffer (agent-shell--start :config config
                                                 :no-focus t
                                                 :new-session t)))
          (mr-x/agent-shell--display-new shell-buffer)))

      ;; ------------------------------------------------------------------
      ;; Launch presets: model + permission-mode in one keystroke.
      ;;
      ;; Both `:default-model-id' and `:default-session-mode-id' are config-level
      ;; and applied automatically the instant a session starts (see
      ;; agent-shell.el's init handler). So a "preset" is nothing more than the
      ;; preferred config with those two overridden — each spawns a FRESH shell
      ;; already wearing that model + permission profile.
      ;;
      ;; Valid IDs (from the live ACP session, `agent-shell--get-available-*'):
      ;;   models: "default" (Opus 4.8 1M) "opus[1m]" "claude-fable-5[1m]"
      ;;           "sonnet" "haiku"
      ;;   modes:  "auto" "default" "acceptEdits" "plan" "dontAsk"
      ;;           "bypassPermissions"
      ;; Add a preset = add one line here.
      (defvar mr-x/agent-shell-presets
        '((?f "Fable · Bypass"  "claude-fable-5[1m]" "bypassPermissions")
          (?o "Opus · Bypass"   "opus[1m]"           "bypassPermissions")
          (?s "Sonnet · Accept" "sonnet"             "acceptEdits")
          (?p "Opus · Plan"     "default"            "plan")
          (?h "Haiku · Auto"    "haiku"              "auto"))
        "Agent-shell launch presets: (CHAR LABEL MODEL-ID MODE-ID).
Each launches a fresh shell with that model and permission mode.")

      (defun mr-x/agent-shell--config-with (model-id mode-id)
        "Copy the preferred agent config, overriding model + session mode.
Returns a fresh config alist so the original is left untouched."
        (let ((config (copy-alist
                       (or (and (fboundp 'agent-shell--resolve-preferred-config)
                                (agent-shell--resolve-preferred-config))
                           (agent-shell-select-config :prompt "Start new agent: ")
                           (error "No agent config found")))))
          (setf (alist-get :default-model-id config) (lambda () model-id))
          (setf (alist-get :default-session-mode-id config) (lambda () mode-id))
          config))

      (defun mr-x/agent-shell--read-preset (&optional char)
        "Return a preset tuple from `mr-x/agent-shell-presets'.
Reads a preset CHAR interactively (e.g. ?f) unless supplied, erroring
if it matches no preset."
        (let ((char (or char
                        (read-char-choice
                         (concat "Preset  "
                                 (mapconcat (lambda (p)
                                              (format "[%c] %s" (nth 0 p) (nth 1 p)))
                                            mr-x/agent-shell-presets "   ")
                                 ": ")
                         (mapcar #'car mr-x/agent-shell-presets)))))
          (or (assq char mr-x/agent-shell-presets)
              (user-error "No preset for %c" char))))

      (defun mr-x/agent-shell-start-preset (&optional char)
        "Start a fresh agent shell from a launch preset.
Reads a preset CHAR from `mr-x/agent-shell-presets' (e.g. ?f) unless
supplied, then spawns a new shell locked to that model + permission mode."
        (interactive)
        (require 'agent-shell)
        (let* ((preset (mr-x/agent-shell--read-preset char))
               (config (mr-x/agent-shell--config-with (nth 2 preset) (nth 3 preset)))
               (shell-buffer (agent-shell--start :config config
                                                 :no-focus t
                                                 :new-session t)))
          (mr-x/agent-shell--display-new shell-buffer)
          (message "Agent preset: %s" (nth 1 preset))))

      (defun mr-x/agent-shell-apply-preset (&optional char)
        "Apply a preset's model + permission mode to the CURRENT agent shell.
Reads a preset CHAR from `mr-x/agent-shell-presets' unless supplied, then
switches the live session's model and session mode to match — no new shell
is spawned. The two changes are async ACP requests, so they are chained:
set the model first, then the mode, then report the applied preset."
        (interactive)
        (require 'agent-shell)
        (unless (derived-mode-p 'agent-shell-mode)
          (user-error "Not in an agent-shell buffer"))
        (unless (map-nested-elt (agent-shell--state) '(:session :id))
          (user-error "No active session"))
        (let* ((preset (mr-x/agent-shell--read-preset char))
               (label (nth 1 preset))
               (model-id (nth 2 preset))
               (mode-id (nth 3 preset))
               (buffer (current-buffer)))
          (agent-shell--config-option-set-model-id
           :model-id model-id
           :on-success
           (lambda ()
             (with-current-buffer buffer
               (agent-shell--config-option-set-mode-id
                :mode-id mode-id
                :on-success
                (lambda () (message "Agent preset applied: %s" label))))))))

      (defun mr-x/agent-shell-preset-dwim (&optional arg)
        "Apply a preset to the current chat, or launch a fresh preset shell.
Bare call applies the preset's model + permission mode to the current
agent-shell session in place. With prefix ARG (`C-u'), instead spawn a
fresh shell locked to that preset."
        (interactive "P")
        (if arg
            (call-interactively #'mr-x/agent-shell-start-preset)
          (call-interactively #'mr-x/agent-shell-apply-preset)))

      (defun mr-x/agent-shell-in-project ()
        "Pick a project, then start a new agent shell there.
Dashboard projects shown by name with path annotation; remaining
projectile projects appended below."
        (interactive)
        (let* ((dashboard (when (boundp 'project-dashboard-projects)
                            project-dashboard-projects))
               ;; dashboard paths (expanded) so we can de-dup projectile
               (dash-paths (mapcar (lambda (p) (expand-file-name (cdr p))) dashboard))
               ;; projectile projects not already in dashboard (skip remote/TRAMP)
               (extra (cl-remove-if (lambda (p) (or (file-remote-p p)
                                                    (member (expand-file-name p) dash-paths)))
                                    projectile-known-projects))
               ;; build candidates: ((display . path) ...)
               (candidates (append
                            (mapcar (lambda (p) (cons (car p) (expand-file-name (cdr p))))
                                    dashboard)
                            (mapcar (lambda (p) (cons (abbreviate-file-name p) (expand-file-name p)))
                                    extra)))
               ;; annotation function shows path for dashboard entries
               (annotate (lambda (cand)
                           (when-let ((path (cdr (assoc cand candidates))))
                             (concat "  " (propertize (abbreviate-file-name path)
                                                      'face 'completions-annotations)))))
               (choice (completing-read "Agent shell in: "
                                        (lambda (str pred action)
                                          (if (eq action 'metadata)
                                              `(metadata (annotation-function . ,annotate))
                                            (complete-with-action action candidates str pred)))))
               (default-directory (or (cdr (assoc choice candidates))
                                      (expand-file-name choice))))
          (mr-x/agent-shell-new-smart)))

      (defun mr-x/agent-shell-roaming ()
        "Start a new agent shell in ~/roaming/claude."
        (interactive)
        (let ((default-directory "/Users/marcosandrade/roaming/claude/"))
          (agent-shell-new-shell)))

      (mr-x/leader-def
        "c" '(:ignore t :wk "Agent Shell")
        "c c" '(agent-shell :wk "Start Agent Shell")
        "c C" '(mr-x/agent-shell-roaming :wk "Claude (roaming)")
        "c n" '(mr-x/agent-shell-new-smart :wk "New shell")
        "c N" '(mr-x/agent-shell-in-project :wk "New shell (pick project)")
        "c P" '(mr-x/agent-shell-preset-dwim :wk "Preset in-place (C-u: new shell)")
        "c t" '(mr-x/agent-shell-toggle :wk "Toggle Agent Shell")
        "c w" '(mr-x/focus-ai-window :wk "Focus AI window")
        "c b" '(major-pane-swap-buffer :wk "Swap panel buffer")
        "c B" '(agent-shell-manager-toggle :wk "Buffer manager")
        "c z" '(agent-shell-manager-toggle-frame :wk "Manager frame")
        "c S" '(mr-x/agent-panel-spawn-test-env :wk "Spawn test env")
        "c j" '(agent-shell-attention-jump :wk "Jump to pending")
        "c ," '(:ignore t :wk "Prompts")
        "c , p" '(agent-shell-prompt-compose :wk "Compose prompt")
        "c , r" '(mr-x/agent-shell-test-prompt :wk "Random test prompt")
        "c , t" '(:ignore t :wk "Taskmaster")
        "c , t n" '(mr-x/taskmaster-next-task :wk "Next task")
        "c , t s" '(mr-x/taskmaster-summary :wk "Summary")
        "c , t a" '(mr-x/taskmaster-add-task :wk "Add task")
        "c p" '(agent-shell-yank-dwim :wk "Paste (smart)")
        "c r" '(major-pane-send-region-no-switch :wk "Send region (stay)")
        "c R" '(major-pane-send-region :wk "Send region (go)")
        "c f" '(major-pane-send-file :wk "Send file")
        "c F" '(major-pane-send-other-file :wk "Send other file")
        "c d" '(agent-shell-send-dwim :wk "Send DWIM (region/error)")
        "c s" '(major-pane-send-screenshot :wk "Send screenshot")
        "c i" '(agent-shell-interrupt :wk "Interrupt")
        "c I" '(agent-shell-inbox-arm :wk "Arm phone inbox")
        "c o" '(agent-shell-other-buffer :wk "Other buffer (viewport/shell)")
        "c m" '(:ignore t :wk "Mode")
        "c m m" '(agent-shell-set-session-mode :wk "Pick mode...")
        "c m c" '(agent-shell-cycle-session-mode :wk "Cycle")
        "c m d" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "default")) :wk "Default")
        "c m e" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "acceptEdits")) :wk "Accept Edits")
        "c m p" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "plan")) :wk "Plan")
        "c m a" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "dontAsk")) :wk "Don't Ask")
        "c m b" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "bypassPermissions")) :wk "Bypass Perms")
        "c ." '(agent-shell-set-session-model :wk "Set model")
        "c T" '(agent-shell-open-transcript :wk "Open transcript")
        "c q" '(agent-shell-queue-request :wk "Queue request")
        "c l" '(:ignore t :wk "Logs")
        "c l l" '(agent-shell-toggle-logging :wk "Toggle logging")
        "c l v" '(agent-shell-view-traffic :wk "View traffic")
        "c l a" '(agent-shell-view-acp-logs :wk "View ACP logs")
        "c l r" '(agent-shell-reset-logs :wk "Reset logs")
        "c l W" '(mr-x/bash-watcher-toggle :wk "Bash watcher")
        "c 1" '(mr-x/agent-shell-allow :wk "Allow")
        "c 2" '(mr-x/agent-shell-deny :wk "Deny")
        "c 3" '(mr-x/agent-shell-allow-always :wk "Allow always")
        "c 0" '(mr-x/agent-shell-view-diff :wk "View diff")
        "c a" '(:ignore t :wk "Recall")
        "c a s" '(:ignore t :wk "Search")
        "c a s c" '(agent-recall-consult-search :wk "Consult")
        "c a s d" '(agent-recall-search :wk "Deadgrep")
        "c a b" '(:ignore t :wk "Browse")
        "c a b a" '(agent-recall-browse :wk "All")
        "c a b d" '(agent-recall-browse-project :wk "Directory")
        "c a r" '(agent-recall-resume :wk "Resume")
        "c a B" '(agent-recall-backfill :wk "Backfill")
        "c a t" '(agent-recall-stats :wk "Stats"))


      (mr-x/leader-def
        "s" '(:ignore t :wk "surf")
        "s s" '(mr-x/surf-web :wk "Surf web (Google)")
        "s S" '(mr-x/surf-web-other-window :wk "Surf web (other window)")
        "s u" '(xwidget-webkit-browse-url :wk "Surf URL")
        "s U" '(mr-x/surf-url-other-window :wk "Surf URL (other window)")
        "s l" '(mr-x/surf-link-at-point :wk "Surf link at point")
        "s o" '(mr-x/org-preview-html :wk "Preview org as HTML"))

      (mr-x/leader-def
        "g" '(:ignore t :wk "git")
        "g g" '(magit-status :wk "magit status (fullframe)")
        "g G" '(mr-x/magit-status-side-window :wk "magit status (side window)")
        "g d" '(magit-diff-unstaged :wk "diff unstaged")
        "g D" '(difftastic-magit-diff :wk "structural diff (difftastic)")
        "g c" '(magit-branch-or-checkout :wk "branch or checkout")
        "g l" '(magit-log-current :wk "log current")
        "g L" '(magit-log-oneline :wk "log oneline")
        "g b" '(magit-blame :wk "blame")
        "g p" '(magit-push-current :wk "push current")
        "g P" '(magit-pull-branch :wk "pull branch")
        "g f" '(magit-fetch :wk "fetch"))

      ;; Bind after agent-shell loads
      (with-eval-after-load 'agent-shell
        (defun mr-x/agent-shell-set-mode-direct (mode-id)
          "Set agent-shell session mode directly by MODE-ID, skipping the picker."
          (let* ((buf (or (and (derived-mode-p 'agent-shell-mode) (current-buffer))
                         (seq-first (agent-shell-project-buffers))))
                 (state (and buf (buffer-local-value 'agent-shell--state buf))))
            (unless buf (user-error "No agent-shell buffer found"))
            (with-current-buffer buf
              (unless (map-nested-elt state '(:session :id))
                (user-error "No active session"))
              (let ((current (map-nested-elt state '(:session :mode-id))))
                (when (and current (string= mode-id current))
                  (user-error "Already in %s mode" (or (agent-shell--resolve-session-mode-name
                                                        mode-id (agent-shell--get-available-modes state))
                                                       mode-id)))
                (agent-shell--send-request
                 :state state
                 :client (map-elt state :client)
                 :request (acp-make-session-set-mode-request
                           :session-id (map-nested-elt state '(:session :id))
                           :mode-id mode-id)
                 :buffer buf
                 :on-success (lambda (_)
                               (let ((session (map-elt (agent-shell--state) :session)))
                                 (map-put! session :mode-id mode-id)
                                 (map-put! (agent-shell--state) :session session)
                                 (message "Session mode: %s"
                                          (or (agent-shell--resolve-session-mode-name
                                               mode-id (agent-shell--get-available-modes (agent-shell--state)))
                                              mode-id)))
                               (agent-shell--update-header-and-mode-line))
                 :on-failure (lambda (err _)
                               (message "Failed to set mode: %s" err)))))))

        (mr-x/leader-def
          "g m" '(mr-x/ai-commit-message :wk "AI commit message")))

      (mr-x/leader-def
        "x" '(:keymap perspective-map :wk "perspective"))

      (mr-x/leader-def
        "$" '(:ignore t :wk "finances")
        "$ q" '(my/ledger-quick-add :wk "quick add")
        "$ s" '(my/ledger-simplefin-sync :wk "sync from bank")
        "$ o" '((lambda () (interactive) (find-file (my/ledger-current-year-file))) :wk "open ledger")
        "$ b" '(:ignore t :wk "balances/reports")
        "$ b b" '(my/ledger-report-balance :wk "all balances")
        "$ b e" '(my/ledger-report-expenses :wk "expenses by amount")
        "$ b m" '(my/ledger-report-monthly :wk "monthly spending")
        "$ b s" '(my/ledger-report-subscriptions :wk "subscriptions")
        "$ b r" '(my/ledger-report-register :wk "full register")
        "$ b n" '(my/ledger-report-net-worth :wk "net worth"))

      (mr-x/leader-def
        "&" '(:ignore t :wk "Pane")
        "& n" '(major-pane-new-chat :wk "New chat")
        "& l" '(major-pane-set-label :wk "Label conversation")
        "& b" '(major-pane-capture-buffer :wk "Capture buffer into pane")
        "& h" '(major-pane-set-home-frame :wk "Lock pane to this frame")
        "& k" '(major-pane-close-conversation :wk "Close conversation")
        "& K" '(major-pane-close-all-conversations :wk "Close all")
        "& f" '((lambda () (interactive)
                  (let ((current-prefix-arg '(4)))
                    (call-interactively #'major-pane-toggle)))
                :wk "Toggle fullscreen"))

      (mr-x/leader-def
        "r" '(:ignore t :wk "reading")
        "r r" '(mr-x/select-reading-book :wk "select book")
        "r n" '(mr-x/book-new :wk "new book")
        "r f" '(mr-x/book-mark-finished :wk "mark finished")
        "r s" '(mr-x/book-update-progress :wk "save progress")
        "r l" '((lambda () (interactive) (dired mr-x/books-directory)) :wk "browse books")
        "r o" '(mr-x/book-open-notes :wk "open notes"))

      (mr-x/leader-def
        "P" '(:ignore t :wk "Project Dashboard")
        "P p" '(project-dashboard-launch :wk "Launch project")
        "P a" '(project-dashboard-add-project :wk "Add project")
        "P d" '(project-dashboard-open :wk "Dashboard for current"))

      ;; Claude task output viewer
      (defun mr-x/claude-watch-task (task-id)
        "Watch output from a Claude background task in real-time.
TASK-ID is the ID shown when Claude runs a background command."
        (interactive "sTask ID: ")
        (let ((output-file (format "/tmp/claude/tasks/%s.output" task-id)))
          (if (file-exists-p output-file)
              (let ((buf (get-buffer-create (format "*claude-task:%s*" task-id))))
                (with-current-buffer buf
                  (read-only-mode -1)
                  (erase-buffer)
                  (insert-file-contents output-file)
                  (goto-char (point-max))
                  (ansi-color-apply-on-region (point-min) (point-max))
                  ;; Auto-revert to follow updates
                  (setq-local auto-revert-interval 1)
                  (auto-revert-mode 1)
                  (read-only-mode 1))
                (display-buffer buf)
                (message "Watching task %s (auto-refreshes every 1s)" task-id))
            (message "Task output file not found: %s" output-file))))

      (defun mr-x/claude-watch-latest-task ()
        "Watch the most recent Claude background task."
        (interactive)
        (let* ((task-dir "/tmp/claude/tasks/")
               (files (and (file-directory-p task-dir)
                           (directory-files task-dir nil "\\.output$" t))))
          (if files
              (let* ((latest (car (last (sort files #'string<))))
                     (task-id (file-name-sans-extension latest)))
                (mr-x/claude-watch-task task-id))
            (message "No Claude task output files found"))))

      (mr-x/leader-def
        "c o" '(mr-x/claude-watch-task :wk "Watch task output")
        "c O" '(mr-x/claude-watch-latest-task :wk "Watch latest task"))

      ;; SANDBOX TEST: Quick test environment setup
      (defun mr-x/sandbox-test-env ()
        "Spawn agent-shell on left, dired ~/roaming/sandbox on right."
        (interactive)
        (delete-other-windows)
        ;; Open dired on the right first (will become right after split)
        (dired "~/roaming/sandbox")
        ;; Split and put agent-shell on left
        (split-window-horizontally)
        (agent-shell)
        ;; Balance windows
        (balance-windows))

      (mr-x/leader-def
        "t" '(mr-x/sandbox-test-env :wk "Test environment")
        "?" '(mr-x/view-shortcuts :wk "Rig reference")
        "q" '(mr-x/quick-ask :wk "Quick question (AI)"))

      ;; LSP commands under SPC ;
      (mr-x/leader-def
        ";" '(:ignore t :wk "LSP")
        "; s" '(consult-lsp-symbols :wk "Search symbol")
        "; S" '(consult-lsp-symbols :wk "Search symbol (global)")
        "; d" '(lsp-find-definition :wk "Find definition")
        "; D" '(lsp-find-declaration :wk "Find declaration")
        "; r" '(lsp-find-references :wk "Find references")
        "; i" '(lsp-find-implementation :wk "Find implementation")
        "; t" '(lsp-goto-type-definition :wk "Type definition")
        "; R" '(lsp-rename :wk "Rename")
        "; a" '(lsp-execute-code-action :wk "Code action")
        "; f" '(lsp-format-buffer :wk "Format buffer")
        "; F" '(lsp-format-region :wk "Format region")
        "; o" '(lsp-organize-imports :wk "Organize imports")
        "; h" '(lsp-describe-thing-at-point :wk "Describe at point")
        "; H" '(lsp-ui-doc-glance :wk "Doc glance")
        "; e" '(lsp-ui-flycheck-list :wk "Error list")
        "; p" '(lsp-ui-peek-find-definitions :wk "Peek definition")
        "; P" '(lsp-ui-peek-find-references :wk "Peek references")
        "; l" '(lsp :wk "Start LSP")
        "; q" '(lsp-disconnect :wk "Disconnect LSP")
        "; w" '(lsp-restart-workspace :wk "Restart workspace")
        "; I" '(:ignore t :wk "Imenu")
        "; I i" '(consult-imenu :wk "Imenu")
        "; I I" '(lsp-ui-imenu :wk "LSP Imenu"))

  )

    (defun mr-x/org-agenda-day ()
      (interactive)
      (org-agenda nil "a"))

    (defun mr-x/org-agenda-custom ()
      (interactive)
      (org-agenda nil "c"))

    (defun mr-x/org-agenda-dashboard ()
      (interactive)
      (org-agenda nil "d"))

    (defun mr-x/org-agenda-focus ()
      (interactive)
      (org-agenda nil "f"))

    (defun mr-x/org-agenda-full ()
      (interactive)
      (org-agenda nil "v"))



(winner-mode 1)



(use-package persistent-scratch
  :ensure t
  :config
  (setq persistent-scratch-scratch-buffer-p-function
        (lambda ()
          (string-match-p "\\*\\(scratch\\|global-scratch\\)\\(<[0-9]+>\\)?\\*"
                          (buffer-name))))
  :hook (elpaca-after-init . (lambda () (persistent-scratch-setup-default))))



  (defvar mr-x/session-file
    (expand-file-name "session-state.el" user-emacs-directory)
    "File to store session state before daemon restart.")

  (defun mr-x/--buffer-restore-spec (buffer)
    "Return a restore-spec for BUFFER, or nil for plain buffers.
Each spec is a list whose car is a type tag dispatched on at restore time.
Stateful buffers (vterm, agent-shell, etc.) that can't survive a daemon
restart are reconstructed by their respective restore handler.

Handlers in mr-x/--restore-buffer-from-spec must stay in sync with this."
    (with-current-buffer buffer
      (cond
       ((eq major-mode 'vterm-mode)
        `(vterm :dir ,default-directory))
       ((derived-mode-p 'agent-shell-mode)
        (when (fboundp 'agent-shell--state)
          (let ((session-id (ignore-errors
                              (map-nested-elt (agent-shell--state) '(:session :id)))))
            (when session-id
              `(agent-shell :session-id ,session-id :dir ,default-directory)))))
       ((eq major-mode 'project-dashboard-mode)
        (when (boundp 'project-dashboard--project-root)
          `(project-dashboard :project ,project-dashboard--project-root)))
       ((eq major-mode 'magit-status-mode)
        `(magit-status :dir ,default-directory))
       ((eq major-mode 'dired-mode)
        `(dired :dir ,default-directory))
       (t nil))))

  (defun mr-x/--serialize-window-tree (window)
    "Serialize WINDOW tree into a readable sexp of splits and buffer info."
    (if (window-live-p window)
        (list :type 'leaf
              :buffer (buffer-name (window-buffer window))
              :file (buffer-file-name (window-buffer window))
              :restore-spec (mr-x/--buffer-restore-spec (window-buffer window))
              :point (window-point window)
              :start (window-start window)
              :dedicated (window-dedicated-p window))
      ;; Internal node — has children
      (let* ((horizontal (window-left-child window))
             (children (window-child-windows-recursive
                        (or horizontal (window-top-child window))))
             (sizes (mapcar (lambda (w)
                              (if horizontal
                                  (window-total-width w)
                                (window-total-height w)))
                            children)))
        (list :type 'split
              :direction (if horizontal :horizontal :vertical)
              :sizes sizes
              :children (mapcar #'mr-x/--serialize-window-tree children)))))

  (defun window-child-windows-recursive (first-child)
    "Return list of sibling windows starting from FIRST-CHILD."
    (let ((windows nil)
          (w first-child))
      (while w
        (push w windows)
        (setq w (window-next-sibling w)))
      (nreverse windows)))

  (defun mr-x/save-session-state ()
    "Save buffer list, window configurations, and frame geometry for restore after daemon restart."
    (interactive)
    (let* ((frames (filtered-frame-list (lambda (f)
                                          (and (frame-visible-p f)
                                               (not (string= "F1" (frame-parameter f 'name)))))))
           (frame-data
            (mapcar (lambda (f)
                      (list :left (frame-parameter f 'left)
                            :top (frame-parameter f 'top)
                            :width (frame-parameter f 'width)
                            :height (frame-parameter f 'height)
                            :fullscreen (frame-parameter f 'fullscreen)
                            :window-tree (mr-x/--serialize-window-tree
                                          (frame-root-window f))))
                    frames)))
      (with-temp-file mr-x/session-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 frame-data (current-buffer))))
      (message "Session saved: %d frames" (length frame-data))))

  (defun mr-x/--collect-tree-buffers (tree)
    "Collect all buffer names from a serialized window TREE."
    (if (eq (plist-get tree :type) 'leaf)
        (list (plist-get tree :buffer))
      (apply #'append
             (mapcar #'mr-x/--collect-tree-buffers
                     (plist-get tree :children)))))

  (defun mr-x/session-state-summary ()
    "Return a human-readable summary of saved session state."
    (if (not (file-exists-p mr-x/session-file))
        "No session state file"
      (with-temp-buffer
        (insert-file-contents mr-x/session-file)
        (let* ((data (read (current-buffer))))
          (mapconcat
           (lambda (fd)
             (let ((bufs (mr-x/--collect-tree-buffers
                          (plist-get fd :window-tree))))
               (format "Frame [%dx%d]: %s"
                       (plist-get fd :width) (plist-get fd :height)
                       (string-join bufs " | "))))
           data "\n")))))

  (defun mr-x/--restore-buffer-from-spec (spec)
    "Reconstruct a stateful buffer from SPEC. Returns the new buffer or nil.
Errors are swallowed per-handler so one bad spec doesn't abort the whole restore."
    (condition-case err
        (pcase (car spec)
          ('vterm
           (when (require 'vterm nil t)
             (let ((default-directory (or (plist-get (cdr spec) :dir)
                                          default-directory)))
               (save-window-excursion (vterm)))))
          ('agent-shell
           (when (and (fboundp 'agent-shell--start)
                      (fboundp 'agent-shell--resolve-preferred-config))
             (let* ((default-directory (or (plist-get (cdr spec) :dir)
                                           default-directory))
                    (config (agent-shell--resolve-preferred-config))
                    (session-id (plist-get (cdr spec) :session-id)))
               (when (and config session-id)
                 (agent-shell--start :config config
                                     :session-id session-id
                                     :session-strategy 'new
                                     :no-focus t
                                     :new-session t)))))
          ('project-dashboard
           (when (fboundp 'project-dashboard-open)
             (save-window-excursion
               (project-dashboard-open (plist-get (cdr spec) :project)))
             (get-buffer (format "*Project: %s*"
                                 (file-name-nondirectory
                                  (directory-file-name
                                   (plist-get (cdr spec) :project)))))))
          ('magit-status
           (when (fboundp 'magit-status-setup-buffer)
             (let ((default-directory (plist-get (cdr spec) :dir)))
               (save-window-excursion (magit-status-setup-buffer)))))
          ('dired
           (dired-noselect (plist-get (cdr spec) :dir)))
          (_ nil))
      (error
       (message "Restore handler failed for %S: %S" (car spec) err)
       nil)))

  (defun mr-x/--restore-window-tree (window tree)
    "Restore TREE into WINDOW, splitting as needed.
Each leaf tries restore strategies in order: file path -> restore-spec
handler (vterm/agent-shell/dashboard/etc.) -> existing buffer by name ->
*scratch* fallback. This ensures stateful buffers reconstruct themselves
when possible rather than silently becoming scratch."
    (if (eq (plist-get tree :type) 'leaf)
        (let* ((file (plist-get tree :file))
               (buf-name (plist-get tree :buffer))
               (spec (plist-get tree :restore-spec))
               (buf (or (and file (file-exists-p file) (find-file-noselect file))
                        (and spec (mr-x/--restore-buffer-from-spec spec))
                        (get-buffer buf-name)
                        (get-buffer-create "*scratch*"))))
          (set-window-buffer window buf)
          (set-window-point window (or (plist-get tree :point) 1))
          (set-window-start window (or (plist-get tree :start) 1)))
      ;; Split node
      (let* ((direction (plist-get tree :direction))
             (children-data (plist-get tree :children))
             (sizes (plist-get tree :sizes))
             (total (apply #'+ sizes))
             (windows (list window)))
        ;; Create splits for each child after the first
        (dotimes (i (1- (length children-data)))
          (let* ((size (nth (1+ i) sizes))
                 (fraction (- (round (* (/ (float size) total)
                                        (if (eq direction :horizontal)
                                            (window-total-width window)
                                          (window-total-height window)))))))
            (push (split-window (car (last windows))
                                fraction
                                (if (eq direction :horizontal) 'right 'below))
                  windows)))
        (setq windows (nreverse windows))
        ;; Recurse into each child
        (cl-loop for w in windows
                 for child in children-data
                 do (mr-x/--restore-window-tree w child)))))

  (defun mr-x/restore-session-state ()
    "Restore frames, buffers, and window configurations from saved session state.
Frames are created on the NS (macOS native) window system regardless of the
caller's terminal — important because emacsclient -e runs in a TTY context
where make-frame would otherwise error with \"Unknown terminal type\"."
    (interactive)
    (if (not (file-exists-p mr-x/session-file))
        (message "No session state file found")
      (let ((frame-data (with-temp-buffer
                          (insert-file-contents mr-x/session-file)
                          (read (current-buffer))))
            (errors nil))
        (dolist (fd frame-data)
          (condition-case err
              (let ((frame (make-frame
                            (list (cons 'window-system 'ns)
                                  (cons 'left (plist-get fd :left))
                                  (cons 'top (plist-get fd :top))
                                  (cons 'width (plist-get fd :width))
                                  (cons 'height (plist-get fd :height))
                                  (cons 'fullscreen (plist-get fd :fullscreen))))))
                (select-frame frame)
                (mr-x/--restore-window-tree
                 (frame-root-window frame)
                 (plist-get fd :window-tree)))
            (error
             (push (format "Frame restore failed: %S" err) errors))))
        (if errors
            (format "Restored %d frames, %d errors: %s"
                    (- (length frame-data) (length errors))
                    (length errors)
                    (string-join errors "; "))
          (format "Session restored: %d frames" (length frame-data))))))



(use-package helpful
  :ensure t)

(global-set-key (kbd "C-h v") #'helpful-variable)
(global-set-key (kbd "C-h k") #'helpful-key)
(global-set-key (kbd "C-h x") #'helpful-command)



(use-package devdocs
  :ensure t
  :commands (devdocs-lookup devdocs-install devdocs-update-all)
  :config
  ;; Gruvbox styling for shr (applies to devdocs, eww, etc.)
  (custom-set-faces
   '(shr-h1 ((t (:foreground "#fb4934" :weight bold :height 1.4))))
   '(shr-h2 ((t (:foreground "#fabd2f" :weight bold :height 1.2))))
   '(shr-h3 ((t (:foreground "#b8bb26" :weight bold :height 1.1))))
   '(shr-h4 ((t (:foreground "#8ec07c" :weight bold))))
   '(shr-code ((t (:foreground "#fe8019" :background "#3c3836"))))
   '(shr-link ((t (:foreground "#83a598" :underline t))))
   '(devdocs-code-block ((t (:background "#3c3836" :extend t)))))
  (add-hook 'devdocs-mode-hook
            (lambda ()
              (setq-local shr-max-width 90)
              (setq-local shr-use-fonts nil)
              (setq-local shr-bullet "  • ")
              (display-line-numbers-mode 1))))



(use-package link-hint
  :ensure t)



(use-package which-key
  :ensure t
  :config
  (which-key-mode)
  (setq which-key-separator " → ")
  (setq which-key-idle-delay 1)
  (setq which-key-sort-order 'which-key-prefix-then-key-order)
  (setq which-key-max-display-columns 4)
  (setq which-key-add-column-padding 2)

  ;; Hide noisy digit-argument entries (0-9)
  (push '(("\\`[0-9]\\'" . "digit-argument") . t) which-key-replacement-alist))



(use-package evil
  :ensure t
  :demand t
  :init (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  (setq evil-respect-visual-line-mode t)
  :config
  (evil-mode 1)
  ;; ESC in normal state → progressive escape instead of evil-force-normal-state
  (define-key evil-normal-state-map [escape] #'mr-x/escape-quit)
  ;; Make M-backspace delete word without saving to register (like normal editors)
  (define-key evil-insert-state-map (kbd "M-<backspace>")
    (lambda () (interactive) (delete-region (point) (progn (backward-word) (point))))))




  (use-package evil-collection
    :ensure t
    :after evil
    :init
    (setq evil-collection-repl-submit-state '(normal insert))
    :config
    (evil-collection-init))

(use-package evil-org
  :ensure t
  :after org
  :hook (org-mode . evil-org-mode)
  :config
  (require 'evil-org-agenda)
  (evil-org-agenda-set-keys))

(use-package evil-snipe
  :ensure t
  :after evil
  :config
  (evil-snipe-mode +1)
  (evil-snipe-override-mode +1))  ;; Replace default f/F/t/T with snipe

(use-package evil-nerd-commenter
  :ensure t
  :after evil
  :config
  (define-key evil-normal-state-map "gc" 'evilnc-comment-operator)
  (define-key evil-visual-state-map "gc" 'evilnc-comment-operator)
  (global-set-key (kbd "s-/") 'evilnc-comment-or-uncomment-lines))

(use-package evil-visual-mark-mode
  :ensure t
  :after evil
  :config
  (evil-visual-mark-mode))

(use-package bm
  :ensure t
  :demand t
  :init
  (setq bm-repository-file (expand-file-name "bm-repository" user-emacs-directory))
  (setq bm-buffer-persistence t)
  (setq bm-restore-repository-on-load t)
  :config
  (setq bm-cycle-all-buffers t)
  (setq bm-highlight-style 'bm-highlight-only-fringe)
  (add-hook 'after-init-hook 'bm-repository-load)
  (add-hook 'kill-buffer-hook 'bm-buffer-save)
  (add-hook 'kill-emacs-hook 'bm-buffer-save)
  (add-hook 'kill-emacs-hook 'bm-repository-save)
  (add-hook 'after-save-hook 'bm-buffer-save)
  (add-hook 'find-file-hook 'bm-buffer-restore)
  (add-hook 'after-revert-hook 'bm-buffer-restore)
  (with-eval-after-load 'general
    (mr-x/leader-def
      "m" '(:ignore t :wk "bookmarks")
      "m m" '(bm-toggle :wk "toggle bookmark")
      "m n" '(bm-next :wk "next bookmark")
      "m p" '(bm-previous :wk "prev bookmark")
      "m l" '(bm-show-all :wk "list all bookmarks"))))

(use-package bookmark+
  :ensure (:host github :repo "emacsmirror/bookmark-plus")
  :after general
  :config
  (mr-x/leader-def
    "m s" '(bookmark-set :wk "set named bookmark")
    "m j" '(bookmark-jump :wk "jump to bookmark")
    "m d" '(bookmark-delete :wk "delete bookmark")
    "m L" '(bookmark-bmenu-list :wk "list named bookmarks")
    "m u" '(bmkp-url-target-set :wk "set URL bookmark")))



  (use-package dired
  :ensure nil  
  :commands (dired dired-jump)
  :after evil
  :config
  (setq dired-kill-when-opening-new-dired-buffer t)
  (setq insert-directory-program "gls")
  (setq dired-use-ls-dired t)
  (setq dired-listing-switches "-al --group-directories-first")
  (evil-define-key 'normal dired-mode-map
    "h" 'dired-up-directory
    "l" 'dired-find-file)

  ;; Bind Y in dired-mode-hook so it always wins over evil-collection
  (add-hook 'dired-mode-hook
    (lambda ()
      (evil-local-set-key 'normal "Y"
        (lambda () (interactive) (dired-copy-filename-as-kill 0)))))

  (add-hook 'dired-mode-hook
	  (lambda ()
	    (dired-hide-details-mode 1)
	    (display-line-numbers-mode 1)
	    ;; Show dotfiles in git repos, hide them elsewhere
	    (unless (locate-dominating-file default-directory ".git")
	      (dired-omit-mode 1)))))

(use-package dired-x
  :ensure nil 
  :after dired
  :config
  (setq dired-omit-files (rx (seq bol "."))))

(add-hook 'dired-mode-hook
	    (lambda () (setq-local dired-omit-verbose t)))
(setq dired-omit-verbose nil)



  (use-package all-the-icons-dired
    :ensure t
    :hook (dired-mode . all-the-icons-dired-mode))

  (use-package dired-preview
    :ensure t
    :config
    (setq dired-preview-delay 0.2)
    (setq dired-preview-display-action-alist
          '((display-buffer-in-side-window)
            (side . right)
            (window-width . 0.5))))

  (use-package dwim-shell-command
    :ensure t
    :commands (dwim-shell-command dwim-shell-command-on-marked-files)
    :config
    (require 'dwim-shell-commands))

  (setq display-line-numbers-type 'visual)
  (dolist (mode '(text-mode-hook prog-mode-hook conf-mode-hook Info-mode-hook))
    (add-hook mode (lambda () (display-line-numbers-mode 1))))

  (use-package tramp
    :ensure nil
    :defer t
    :config
    ;; PTY by default — gives remote hosts an interactive shell so TRAMP
    ;; can find a prompt.  Windows/ConPTY needs pipe mode to avoid escape
    ;; code pollution, so we scope that per-host via advice.
    (defun mr-x/tramp-windows-pipe-a (orig-fun vec)
      "Use pipe instead of PTY for hosts whose shell pollutes the PTY.
Windows/ConPTY emits escape codes; mrx runs zsh with a fancy PS1 that
TRAMP can't match under a PTY — both need pipe mode."
      (let ((tramp-process-connection-type
             (if (string-match-p "vengeance\\|100\\.67\\.67\\.61\\|mrx"
                                  (tramp-file-name-host vec))
                 nil    ; pipe — avoids ConPTY / fancy-prompt escape codes
               t)))    ; PTY  — interactive shell for other Linux hosts
        (funcall orig-fun vec)))
    (advice-add 'tramp-maybe-open-connection :around #'mr-x/tramp-windows-pipe-a)
    (setq tramp-use-ssh-controlmaster-options nil)
    ;; Don't let vc-mode check version control over TRAMP
    (setq vc-ignore-dir-regexp
          (format "%s\\|%s" vc-ignore-dir-regexp tramp-file-name-regexp))
    ;; Disable auto-revert for remote files
    (setq auto-revert-remote-files nil)
    ;; Disable projectile for remote files
    (defun mr-x/projectile-ignore-remote-a (orig-fn &rest args)
      "Skip `projectile-project-root' on remote files."
      (unless (file-remote-p default-directory)
        (apply orig-fn args)))
    (with-eval-after-load 'projectile
      (advice-add 'projectile-project-root :around #'mr-x/projectile-ignore-remote-a)))


;; Vertico + Consult + Orderless + Marginalia + Embark
;; (compat is declared early, near the elpaca bootstrap, so it's queued
;; before everything that depends on it.)

(use-package vertico
  :ensure t
  :init
  (vertico-mode 1)
  :config
  (setq vertico-count 15)
  (setq vertico-cycle t)
  ;; Evil-friendly navigation in minibuffer
  (define-key vertico-map (kbd "C-j") #'vertico-next)
  (define-key vertico-map (kbd "C-k") #'vertico-previous)
  (define-key vertico-map (kbd "C-l") #'vertico-insert))

;; Saner filename completion: RET drills into directories instead of
;; opening dired, DEL deletes whole path components, and typing ~/ or /
;; mid-path tidies the shadowed prefix.  Only affects file completion —
;; RET everywhere else keeps normal accept-and-exit.
(use-package vertico-directory
  :ensure nil            ;; ships inside the vertico package
  :after vertico
  :bind (:map vertico-map
         ("RET"   . vertico-directory-enter)
         ("DEL"   . vertico-directory-delete-char)
         ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

(use-package marginalia
  :ensure t
  :init
  (marginalia-mode 1)
  :config
  ;; Bookmark+ URL bookmarks store the placeholder "   - no file -" in
  ;; `filename' and the real URL in `location', so marginalia's stock
  ;; annotator shows the placeholder.  Prefer `location' when filename
  ;; is missing or the bmkp placeholder.
  (defun mr-x/marginalia-annotate-bookmark (cand)
    "Like `marginalia-annotate-bookmark', but show URLs for bookmark+ URL bookmarks."
    (when-let* ((bm (assoc cand (bound-and-true-p bookmark-alist))))
      (marginalia--fields
       ((marginalia--bookmark-type bm) :width 10 :face 'marginalia-type)
       ((let ((file (bookmark-prop-get bm 'filename)))
          (if (or (null file) (string-match-p "- no file -" file))
              (or (bookmark-prop-get bm 'location) "")
            file))
        :truncate 0.5 :face 'marginalia-file-name))))
  (setf (alist-get 'bookmark marginalia-annotators)
        '(mr-x/marginalia-annotate-bookmark marginalia-annotate-bookmark builtin none)))

(use-package consult
  :ensure t
  :bind (("C-s"     . consult-line)
         ("C-x b"   . consult-buffer)
         ("M-g g"   . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-s r"   . consult-ripgrep)
         ("M-s l"   . consult-line)
         ("M-s f"   . consult-find))
  :config
  ;; Use consult for xref
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)
  ;; Preview on consult-line: grab symbol at point
  (consult-customize consult-line :add-history (thing-at-point 'symbol))
  ;; Auto-preview in consult-imenu
  (consult-customize consult-imenu :preview-key 'any))

(use-package embark
  :ensure t
  :bind (("s-r" . embark-act)
         ("s-;" . embark-dwim))
  :config
  (setq prefix-help-command #'embark-prefix-help-command)

  ;; Use which-key popup instead of a buffer split for embark actions
  (defun embark-which-key-indicator ()
    "Embark indicator that shows actions via which-key popup."
    (lambda (&optional keymap targets prefix)
      (if (null keymap)
          (which-key--hide-popup-ignore-command)
        (which-key--show-keymap
         (if (eq (plist-get (car targets) :type) 'embark-become)
             "Become"
           (format "Act on %s '%s'"
                   (plist-get (car targets) :type)
                   (plist-get (car targets) :target)))
         (if prefix
             (lookup-key keymap prefix)
           keymap)
         nil nil t (lambda (binding)
                     (not (string-suffix-p "-argument" (cdr binding))))))))

  (setq embark-indicators '(embark-which-key-indicator
                            embark-highlight-indicator
                            embark-isearch-highlight-indicator))

  ;; Short display names for project-dashboard embark actions
  (dolist (entry '(("m" . "project-dashboard--action-magit")
                   ("d" . "project-dashboard--action-dired")
                   ("v" . "project-dashboard--action-vterm")
                   ("a" . "project-dashboard--action-agent-shell")
                   ("f" . "project-dashboard--action-find-file")
                   ("RET" . "project-dashboard--action-open")))
    (push `((nil . ,(cdr entry))
            nil . ,(replace-regexp-in-string
                    "project-dashboard--action-" "" (cdr entry)))
          which-key-replacement-alist))

  ;; macOS file actions
  (defun embark-open-in-finder (file)
    "Reveal FILE in Finder."
    (call-process "open" nil 0 nil "-R" (expand-file-name file)))
  (defun embark-open-externally (file)
    "Open FILE with default macOS app."
    (call-process "open" nil 0 nil (expand-file-name file)))
  (define-key embark-file-map (kbd "O") #'embark-open-externally)
  (define-key embark-file-map (kbd "F") #'embark-open-in-finder)

  ;; Hide which-key popup when embark action completes/aborts
  (advice-add #'embark--quit :after
              (lambda (&rest _) (which-key--hide-popup-ignore-command))))

(use-package embark-consult
  :ensure t
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))



  ;; with-editor must be configured BEFORE magit loads
  (use-package with-editor
    :ensure t
    :hook ((shell-mode . with-editor-export-editor)
           (eshell-mode . with-editor-export-editor)
           (term-exec . with-editor-export-editor)
           (vterm-mode . with-editor-export-editor))
    :config
    ;; Fix for daemon mode - explicitly set the emacsclient path
    (setq with-editor-emacsclient-executable
          "/opt/homebrew/opt/emacs-plus@30/bin/emacsclient"))

  ;; Pane-aware magit display: fullcolumn-most-v1 splits below the
  ;; selected window and deletes the rest of the column — invoked from
  ;; the major-pane, that demolishes the conversation (soft dedication
  ;; only blocks window REUSE, not split-and-delete).  From the pane,
  ;; route magit to another window instead; elsewhere, fullcolumn as usual.
  (defun mr-x/magit-display-buffer-pane-aware (buffer)
    "Display magit BUFFER, keeping it out of the major-pane."
    (if (window-parameter (selected-window) 'major-pane)
        (display-buffer buffer '((display-buffer-use-some-window)
                                 (inhibit-same-window . t)))
      (magit-display-buffer-fullcolumn-most-v1 buffer)))

  (use-package magit
    :ensure t
    :after with-editor
    :commands (magit-status magit-get-current-branch)
    :custom
    ;; Fullframe by default - magit takes over, restores on quit;
    ;; but never at the major-pane's expense (see wrapper above)
    (magit-display-buffer-function #'mr-x/magit-display-buffer-pane-aware)
    :init
    ;; Fix for daemon mode - set EDITOR globally so git uses emacsclient
    (setenv "EDITOR" "/opt/homebrew/opt/emacs-plus@30/bin/emacsclient")
    :bind
    (:map magit-mode-map
          ("s-<return>" . magit-diff-visit-worktree-file-other-window)))

  ;; Side-window magit for IDE-style peek
  (defun mr-x/magit-status-side-window ()
    "Open magit-status in a side window on the right."
    (interactive)
    (let ((magit-display-buffer-function
           (lambda (buffer)
             (display-buffer buffer
                             '((display-buffer-in-side-window)
                               (side . right)
                               (window-width . 0.4))))))
      (magit-status)))

  ;; Syntax highlighting in Magit diffs via delta
  (use-package magit-delta
    :ensure t
    :hook (magit-mode . magit-delta-mode)
    :config
    (setq magit-delta-delta-args '("--syntax-theme" "gruvbox-dark")))

  ;; diff-hl — inline git diff markers in the fringe
  (use-package diff-hl
    :ensure t
    :hook ((prog-mode . diff-hl-mode)
           (text-mode . diff-hl-mode)
           (dired-mode . diff-hl-dired-mode)
           (magit-post-refresh . diff-hl-magit-post-refresh))
    :config
    (diff-hl-flydiff-mode 1))

  ;; treesit-fold — code folding via tree-sitter
  (use-package treesit-fold
    :ensure (:host github :repo "emacs-tree-sitter/treesit-fold")
    :hook ((prog-mode . treesit-fold-mode))
    :config
    (defhydra hydra-fold (:color pink :hint nil)
      "
 _o_: open   _c_: close   _t_: toggle   _O_: open all   _C_: close all   _q_: quit
"
      ("o" treesit-fold-open)
      ("c" treesit-fold-close)
      ("t" treesit-fold-toggle)
      ("O" treesit-fold-open-all)
      ("C" treesit-fold-close-all)
      ("q" nil :exit t))
    (evil-define-key 'normal prog-mode-map (kbd "z f") #'hydra-fold/body))

  ;; Hydra — persistent key hint popups
  (use-package hydra
    :ensure t
    :config

    ;; ── Window Management Hydra ──────────────────────────────────
    ;; SPC w enters evil-window-map; press W from there to enter this hydra.
    ;; Stay in the hydra to resize/split/navigate repeatedly with single keys.
    (defhydra hydra-window (:hint nil :foreign-keys run)
      "
  ╭─── Window ─────────────────────────────────────────╮
   Navigate      Resize           Split/Layout
   _h_: ←  _l_: →    _H_: shrink-h  _L_: grow-h  _s_: horizontal  _=_: balance
   _j_: ↓  _k_: ↑    _J_: shrink-v  _K_: grow-v  _v_: vertical    _o_: only
                                               _d_: delete     _u_: undo layout
                                               _r_: rotate     _R_: rotate ←
  ╰────────────────────────────── _q_: quit ────────────╯"
      ("h" evil-window-left)
      ("j" evil-window-down)
      ("k" evil-window-up)
      ("l" evil-window-right)
      ("H" shrink-window-horizontally)
      ("J" shrink-window)
      ("K" enlarge-window)
      ("L" enlarge-window-horizontally)
      ("s" evil-window-split)
      ("v" evil-window-vsplit)
      ("=" balance-windows)
      ("o" delete-other-windows :exit t)
      ("d" evil-window-delete)
      ("u" winner-undo)
      ("r" mr-x/rotate-windows)
      ("R" (mr-x/rotate-windows '(4)))
      ("q" nil :exit t))

    ;; ── Text Zoom Hydra ──────────────────────────────────────────
    (defhydra hydra-zoom (:hint nil)
      "
  ╭─── Zoom ────────────────╮
   _+_/_=_: in   _-_: out   _0_: reset
  ╰──────── _q_: quit ──────╯"
      ("+" text-scale-increase)
      ("=" text-scale-increase)
      ("-" text-scale-decrease)
      ("0" (text-scale-set 0) :exit t)
      ("q" nil :exit t))

    ;; ── Org-Mode Hydra ──────────────────────────────────────────
    (defhydra hydra-org (:hint nil :foreign-keys run)
      "
  ╭─── Org ────────────────────────────────────────────────╮
   Navigate          Heading           Misc
   _n_: next heading   _H_: promote        _t_: cycle TODO
   _p_: prev heading   _L_: demote         _T_: set TODO keyword
   _u_: up heading     _K_: move up        _x_: toggle checkbox
   _N_: next visible   _J_: move down      _,_: set priority
   _P_: prev visible   _h_: promote tree   _:_: set tags
                      _l_: demote tree    _d_: deadline
                                         _s_: schedule
  ╰──────────────────────────── _q_: quit ─────────────────╯"
      ("n" org-next-visible-heading)
      ("p" org-previous-visible-heading)
      ("u" outline-up-heading)
      ("N" org-forward-heading-same-level)
      ("P" org-backward-heading-same-level)
      ("H" org-do-promote)
      ("L" org-do-demote)
      ("h" org-promote-subtree)
      ("l" org-demote-subtree)
      ("K" org-move-subtree-up)
      ("J" org-move-subtree-down)
      ("t" org-todo)
      ("T" org-todo :exit t)
      ("x" org-toggle-checkbox)
      ("," org-priority)
      (":" org-set-tags-command :exit t)
      ("d" org-deadline :exit t)
      ("s" org-schedule :exit t)
      ("q" nil :exit t))

    ;; ── Agent Shell Manager Hydra ─────────────────────────────
    (defhydra hydra-agent (:hint nil :foreign-keys run)
      "
  ╭─── Agent Shell Manager ──────────────────────────────────────────╮
   Navigate          Actions            Settings
   _j_: next           _c_: new shell       _m_: set mode
   _k_: prev           _i_: interrupt       _M_: set model
   _RET_: select       _K_: kill            _n_: set label
   _v_/_<S-return>_: peek   _r_: restart         _l_: toggle logging
   _p_: preview        _d_: delete killed   _t_: view traffic

   Frame/Filter
   _F_: toggle frame   _f_: cycle filter    _g_: refresh
  ╰──────────────────────────────── _q_: quit ────────────────────────╯"
      ("j" next-line)
      ("k" previous-line)
      ("RET" agent-shell-manager-select :exit t)
      ("v" agent-shell-manager-peek)
      ("<S-return>" agent-shell-manager-peek)
      ("p" agent-shell-manager-enter-preview)
      ("c" agent-shell-manager-new)
      ("i" agent-shell-manager-interrupt)
      ("K" agent-shell-manager-kill)
      ("r" agent-shell-manager-restart)
      ("d" agent-shell-manager-delete-killed)
      ("m" agent-shell-manager-set-mode)
      ("M" agent-shell-manager-set-model)
      ("n" agent-shell-manager-set-label)
      ("l" agent-shell-manager-toggle-logging)
      ("t" agent-shell-manager-view-traffic :exit t)
      ("F" agent-shell-manager-toggle-frame)
      ("f" agent-shell-manager-cycle-filter)
      ("g" agent-shell-manager-refresh)
      ("q" nil :exit t))

    ;; ── Org-Agenda Hydra ──────────────────────────────────────
    (defun mr-x/agenda-next-section ()
      "Jump to next section header (org-agenda-structure face)."
      (interactive)
      (forward-line 1)
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (when (eq (get-text-property (point) 'face) 'org-agenda-structure)
            (setq found t))
          (unless found (forward-line 1)))
        (unless found (message "No more sections"))))

    (defun mr-x/agenda-prev-section ()
      "Jump to previous section header (org-agenda-structure face)."
      (interactive)
      (forward-line -1)
      (let ((found nil))
        (while (and (not found) (not (bobp)))
          (when (eq (get-text-property (point) 'face) 'org-agenda-structure)
            (setq found t))
          (unless found (forward-line -1)))
        (unless found (message "No more sections"))))

    (defun mr-x/agenda-next-header ()
      "Jump to next category header (org-super-agenda-header face)."
      (interactive)
      (forward-line 1)
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (when (eq (get-text-property (point) 'face) 'org-super-agenda-header)
            (setq found t))
          (unless found (forward-line 1)))
        (unless found (message "No more headers"))))

    (defun mr-x/agenda-prev-header ()
      "Jump to previous category header (org-super-agenda-header face)."
      (interactive)
      (forward-line -1)
      (let ((found nil))
        (while (and (not found) (not (bobp)))
          (when (eq (get-text-property (point) 'face) 'org-super-agenda-header)
            (setq found t))
          (unless found (forward-line -1)))
        (unless found (message "No more headers"))))

    (defhydra hydra-org-agenda (:hint nil :foreign-keys run)
      "
  ╭─── Agenda Cheatsheet ───────────────────────────────────────╮
   Navigate              Actions               Clock
   _j_/_k_: line up/down    _t_: cycle TODO         _I_: clock in
   _g j_/_g k_: item ↑/↓   _p_: schedule date      _O_: clock out
   _TAB_: goto entry      _H_/_L_: date earlier/    _R_: clock report
   _RET_: switch to            later
   _._: goto today        _u_: undo              Filter
   _g d_: goto date        _C_: capture            _s s_: filter
                                                _S_: clear filters
   Views                  Bulk                  _*_: mark all
   _d a_: archive          _m_: toggle mark        _%_: mark regexp
   _d d_: kill entry       _x_: bulk action        _M_: unmark all
   _r_/_g r_: refresh
  ╰──────────────────────────── _q_: quit ──────────────────────╯"
      ("j" org-agenda-next-line)
      ("k" org-agenda-previous-line)
      ("g j" org-agenda-next-item)
      ("g k" org-agenda-previous-item)
      ("TAB" org-agenda-goto :exit t)
      ("RET" org-agenda-switch-to :exit t)
      ("." org-agenda-goto-today)
      ("g d" org-agenda-goto-date)
      ("t" org-agenda-todo)
      ("p" org-agenda-date-prompt)
      ("H" org-agenda-do-date-earlier)
      ("L" org-agenda-do-date-later)
      ("u" org-agenda-undo)
      ("C" org-agenda-capture :exit t)
      ("I" org-agenda-clock-in)
      ("O" org-agenda-clock-out)
      ("R" org-agenda-clockreport-mode)
      ("s s" org-agenda-limit-interactively)
      ("S" org-agenda-filter-remove-all)
      ("*" org-agenda-bulk-mark-all)
      ("%" org-agenda-bulk-mark-regexp)
      ("M" org-agenda-bulk-unmark-all)
      ("m" org-agenda-bulk-toggle)
      ("x" org-agenda-bulk-action)
      ("d a" org-agenda-archive-default-with-confirmation)
      ("d d" org-agenda-kill)
      ("r" org-agenda-redo)
      ("g r" org-agenda-redo)
      ("q" nil :exit t))

    (with-eval-after-load 'evil
      (evil-define-key 'motion org-agenda-mode-map
        (kbd ",") 'hydra-org-agenda/body
        (kbd "j") 'evil-next-line
        (kbd "k") 'evil-previous-line))

    ;; ── Dired Hydra ──────────────────────────────────────────────
    (defhydra hydra-dired (:hint nil :foreign-keys run)
      "
  ╭─── Dired ──────────────────────────────────────────────────╮
   Navigate           Mark                File Operations
   _h_: up directory    _m_: mark             _C_: copy
   _l_: open file       _u_: unmark           _R_: rename/move
   _o_: sort toggle     _U_: unmark all       _D_: delete
   _g r_: refresh       _t_: toggle marks     _+_: new directory
   _g j_: next dir                          _S_: symlink
   _g k_: prev dir     View                 _Z_: compress
   _(_: hide details    _M_: chmod
   _I_: insert subdir  Misc                 _!_: shell command
   _i_: edit (wdired)  _Y_: copy filename    _&_: async shell cmd
                      _W_: browse URL       _=_: diff
  ╰──────────────────────────── _q_: quit ─────────────────────╯"
      ("h" dired-up-directory)
      ("l" dired-find-file :exit t)
      ("o" dired-sort-toggle-or-edit)
      ("g r" revert-buffer)
      ("g j" dired-next-dirline)
      ("g k" dired-prev-dirline)
      ("(" dired-hide-details-mode)
      ("I" dired-maybe-insert-subdir)
      ("i" dired-toggle-read-only :exit t)
      ("m" dired-mark)
      ("u" dired-unmark)
      ("U" dired-unmark-all-marks)
      ("t" dired-toggle-marks)
      ("C" dired-do-copy :exit t)
      ("R" dired-do-rename :exit t)
      ("D" dired-do-delete :exit t)
      ("+" dired-create-directory :exit t)
      ("S" dired-do-symlink :exit t)
      ("Z" dired-do-compress)
      ("M" dired-do-chmod :exit t)
      ("!" dired-do-shell-command :exit t)
      ("&" dired-do-async-shell-command :exit t)
      ("Y" dired-copy-filename-as-kill)
      ("W" browse-url-of-dired-file :exit t)
      ("=" dired-diff :exit t)
      ("q" nil :exit t))

    ;; ── Info-Mode Hydra (evil-collection cheatsheet) ─────────────
    (defhydra hydra-info (:hint nil :color pink :foreign-keys run)
      "
  ╭─── Info (evil-collection) ──────────────────────────────────╮
   Scroll                  Traverse              Go to
   _C-u_/_C-d_: half page    _gj_/_gk_: next/prev     _d_: directory
   _DEL_: scroll up          node               _u_: up (parent)
   Follow                  _C-j_/_C-k_: fwd/back    _gt_: top of manual
   _RET_/_C-]_: follow link   node               _gT_: table of contents
   _TAB_/_S-TAB_: next/prev _C-o_/_C-t_: hist back    _gG_: goto node
     link                  _C-i_: hist forward    _gm_/_J_: menu item
   _gf_: follow xref                            g1‥g9: nth menu item
                          History               Search
                          _gL_: full history      _s_: search
   Help                                        _S_: search (case)
   _M-h_: Info help                              _i_/_I_: index / virtual
   _g?_: summary                                _a_: apropos
                                               _g,_: index next
  ╰──────────────────────────── _q_: quit ──────────────────────╯"
      ("C-u" evil-scroll-up)
      ("C-d" evil-scroll-down)
      ("DEL" Info-scroll-down)
      ("gj" Info-next)
      ("gk" Info-prev)
      ("C-j" Info-forward-node)
      ("C-k" Info-backward-node)
      ("u" Info-up)
      ("C-o" Info-history-back)
      ("C-t" Info-history-back)
      ("C-i" Info-history-forward)
      ("RET" Info-follow-nearest-node :exit t)
      ("C-]" Info-follow-nearest-node :exit t)
      ("TAB" Info-next-reference)
      ("S-TAB" Info-prev-reference)
      ("gf" Info-follow-reference :exit t)
      ("d" Info-directory)
      ("gt" Info-top-node)
      ("gT" Info-toc :exit t)
      ("gG" Info-goto-node :exit t)
      ("gm" Info-menu :exit t)
      ("J" Info-menu :exit t)
      ("gL" Info-history :exit t)
      ("s" Info-search :exit t)
      ("S" Info-search-case-sensitively :exit t)
      ("i" Info-index :exit t)
      ("I" Info-virtual-index :exit t)
      ("a" info-apropos :exit t)
      ("g," Info-index-next)
      ("M-h" Info-help :exit t)
      ("g?" Info-summary :exit t)
      ("q" nil :exit t))

    (with-eval-after-load 'evil
      (evil-define-key 'normal Info-mode-map (kbd ",") #'hydra-info/body))

    ;; ── Ediff Hydra ──────────────────────────────────────────────
    ;; Fires via SPC , while in the *Ediff Control Panel* (evil is in normal
    ;; state there, so the leader works — same entry point as every other mode
    ;; hydra). Every head is a command taken straight from ediff's own keymap
    ;; (ediff-util.el) and verified to run cleanly from the control buffer.
    ;; Note: q quits the HYDRA (consistent with the other hydras); Q quits EDIFF.
    (defhydra hydra-ediff (:hint nil :foreign-keys run)
      "
  ╭─── Ediff ──────────────────────────────────────────╮
   Navigate          Copy              View
   _n_: next diff      _a_: A→B           _|_: toggle split
   _p_: prev diff      _b_: B→A           _h_: toggle hilite
   _j_: jump to N      _*_: fine diffs    _~_: swap A/B
                     _!_: recompute     _z_: recenter
  ╰──────── _Q_: quit ediff ──────────── _q_: quit hydra ─╯"
      ("n" ediff-next-difference)
      ("p" ediff-previous-difference)
      ("j" ediff-jump-to-difference)
      ("a" ediff-copy-A-to-B)
      ("b" ediff-copy-B-to-A)
      ("*" ediff-make-or-kill-fine-diffs)
      ("!" ediff-update-diffs)
      ("|" ediff-toggle-split)
      ("h" ediff-toggle-hilit)
      ("~" ediff-swap-buffers)
      ("z" ediff-recenter)
      ("Q" ediff-quit :exit t)
      ("q" nil :exit t))

    ;; Wire them into leader keys after general loads
    (with-eval-after-load 'general
      (mr-x/leader-def
        "W" '(hydra-window/body :wk "Window hydra")
        "z" '(hydra-zoom/body :wk "Zoom hydra")
        "c h" '(hydra-agent/body :wk "Agent hydra"))
      ;; Info hydra available in Info-mode via SPC ,
      (general-define-key
       :states '(normal visual)
       :keymaps 'Info-mode-map
       :prefix "SPC"
       "," '(hydra-info/body :wk "Info hydra"))
      ;; Org hydra available in org-mode via SPC o
      (general-define-key
       :states '(normal visual)
       :keymaps 'org-mode-map
       :prefix "SPC"
       "o" '(hydra-org/body :wk "Org hydra"))))

  ;; Side-by-side diffs with vdiff + hydra
  (use-package vdiff
    :ensure t
    :after hydra
    :config
    (evil-define-key 'normal vdiff-mode-map "\\" vdiff-mode-prefix-map)
    (evil-define-key 'normal vdiff-mode-map "q" #'vdiff-quit)
    (evil-define-key 'normal vdiff-mode-map "?" #'vdiff-hydra/body)
    ;; Background-only faces so syntax highlighting shows through (delta-style)
    (set-face-attribute 'vdiff-addition-face nil :background "#2e3b2e" :foreground 'unspecified :inherit nil)
    (set-face-attribute 'vdiff-subtraction-face nil :background "#3b2626" :foreground 'unspecified :inherit nil)
    (set-face-attribute 'vdiff-change-face nil :background "#3b3520" :foreground 'unspecified :inherit nil))

  ;; difftastic — structural (AST-aware) diffs. Needs the `difft' binary
  ;; (brew install difftastic). Bound to SPC g D.
  (use-package difftastic
    :ensure t
    :after magit
    :commands (difftastic-magit-diff difftastic-magit-show difftastic-dired-diff))

  ;; Forge - GitHub/GitLab PR and issue management
  (use-package forge
    :ensure t
    :after magit
    :init
    (setq forge-add-default-bindings t)
    :config
    (setq forge-pull-notifications t))



(setq ediff-split-window-function 'split-window-horizontally)
(setq ediff-window-setup-function 'ediff-setup-windows-plain)

;; Fix doom-gruvbox ediff faces (theme sets everything to the same red)
(custom-set-faces
 '(ediff-current-diff-A ((t (:background "#3b2626"))))  ; red = old/removed
 '(ediff-current-diff-B ((t (:background "#2e3b2e"))))  ; green = new/added
 '(ediff-current-diff-C ((t (:background "#3b3520"))))  ; yellow = ancestor
 '(ediff-fine-diff-A ((t (:background "#5c3030"))))     ; brighter red for word-level
 '(ediff-fine-diff-B ((t (:background "#3d5c3d"))))     ; brighter green for word-level
 '(ediff-even-diff-A ((t (:background "#3c3836"))))
 '(ediff-even-diff-B ((t (:background "#3c3836"))))
 '(ediff-odd-diff-A ((t (:background "#32302f"))))
 '(ediff-odd-diff-B ((t (:background "#32302f")))))

;; diff-ansi for beautiful delta-powered diffs
(use-package diff-ansi
  :ensure (:host codeberg :repo "ideasman42/emacs-diff-ansi")
  :config
  (setq diff-ansi-tool 'delta)
  ;; Optional: extra delta args for side-by-side
  (setq diff-ansi-tool-delta-args '("--side-by-side" "--width" "180")))


  ;; Load project-dashboard from lisp directory
  (add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
  (add-to-list 'load-path (expand-file-name "lisp/project-dashboard" user-emacs-directory))

  (use-package projectile
    :ensure t
    :init
    (projectile-mode +1)
    :config
    (setq projectile-completion-system 'default)
    ;; Configure project search paths
    (setq projectile-project-search-path '("~/roaming" "~/work"))
    ;; Set default action when switching projects (overridden below after project-dashboard loads)
    (setq projectile-switch-project-action #'projectile-dired)
    ;; Use alien indexing (git ls-files, fd, etc.) for fast uncached lookups
    (setq projectile-indexing-method 'alien)
    ;; No caching needed with alien — new files show up immediately
    (setq projectile-enable-caching nil)
    :bind (:map projectile-mode-map
                ("C-c p" . projectile-command-map)))


  ;; Add dev environment keybindings to projectile-command-map
  (with-eval-after-load 'projectile
    (define-key projectile-command-map (kbd "C-d") #'mr-x/spawn-dev-environment)
    (define-key projectile-command-map (kbd "C-r") #'mr-x/restart-dev-environment)
    (define-key projectile-command-map (kbd "C-R") #'mr-x/clear-and-restart-dev-environment)
    ;; Load project-dashboard
    (require 'project-dashboard)
    ;; Use project dashboard when switching projects (for other projectile commands)
    (setq projectile-switch-project-action #'project-dashboard--projectile-switch-action))

  ;; dedicated vterm for project
      (defun mr-x/spawn-project-terminal-frame ()
      "Spawn a new frame with a vterm in the current project directory.
    Use SPC c r from this frame to send regions to your agent-shell."

      (interactive)
      (let* ((project-root (or (projectile-project-root) default-directory))
    	 (frame (make-frame `((name . ,(format "Terminal: %s"
    					       (file-name-nondirectory
  						(directory-file-name project-root))))))))
        (select-frame-set-input-focus frame)
        (let ((default-directory project-root))

  	(multi-vterm))
        (delete-other-windows)))

  (defun mr-x/spawn-dev-environment ()
    "Spawn a new frame with two horizontal vterms for rec dev and queue.
Creates a frame named 'Dev: rec' with:
  - Top: vterm running `pnpm run dev` (named *rec: dev*)
  - Bottom: vterm running `pnpm queue:dev` (named *rec: queue*)
If the buffers already exist, kills them first."
    (interactive)
    (let* ((project-root "~/roaming/projects/rec/")
           (project-name "rec")
           (dev-buf-name (format "*%s: dev*" project-name))
           (queue-buf-name (format "*%s: queue*" project-name)))
      ;; Kill existing buffers if they exist
      (when (get-buffer dev-buf-name) (kill-buffer dev-buf-name))
      (when (get-buffer queue-buf-name) (kill-buffer queue-buf-name))
      (let ((frame (make-frame `((name . ,(format "Dev: %s" project-name))))))
        (select-frame-set-input-focus frame)
        (let ((default-directory project-root))
          ;; Create first vterm for dev server
          (multi-vterm)
          (rename-buffer dev-buf-name)
          (let ((dev-buf (current-buffer)))
            ;; Split horizontally (top/bottom)
            (split-window-below)
            ;; Create second vterm for queue in bottom window
            (other-window 1)
            (multi-vterm)
            (rename-buffer queue-buf-name)
            ;; Send commands to both vterms
            (vterm-send-string "pnpm queue:dev")
            (vterm-send-return)
            ;; Switch to dev buffer and send its command
            (select-window (get-buffer-window dev-buf))
            (vterm-send-string "pnpm run dev")
            (vterm-send-return)))
        (message "Dev environment spawned for %s" project-name))))

  (defun mr-x/restart-dev-environment ()
    "Restart rec project dev processes by sending C-c and re-running commands."
    (interactive)
    (let ((dev-buf (get-buffer "*rec: dev*"))
          (queue-buf (get-buffer "*rec: queue*")))
      (when dev-buf
        (with-current-buffer dev-buf
          (vterm-send-C-c)
          (run-at-time "0.5 sec" nil
            (lambda (buf)
              (with-current-buffer buf
                (vterm-send-string "pnpm run dev")
                (vterm-send-return)))
            dev-buf)))
      (when queue-buf
        (with-current-buffer queue-buf
          (vterm-send-C-c)
          (run-at-time "0.5 sec" nil
            (lambda (buf)
              (with-current-buffer buf
                (vterm-send-string "pnpm queue:dev")
                (vterm-send-return)))
            queue-buf)))
      (message "Restarting rec dev environment")))

  (defun mr-x/clear-and-restart-dev-environment ()
    "Clear both dev terminals and restart dev processes."
    (interactive)
    (let ((dev-buf (get-buffer "*rec: dev*"))
          (queue-buf (get-buffer "*rec: queue*")))
      (when dev-buf
        (with-current-buffer dev-buf
          (vterm-send-C-c)
          (run-at-time "0.3 sec" nil
            (lambda (buf)
              (with-current-buffer buf
                (vterm-send-string "clear")
                (vterm-send-return)
                (run-at-time "0.3 sec" nil
                  (lambda (buf2)
                    (with-current-buffer buf2
                      (vterm-send-string "pnpm run dev")
                      (vterm-send-return)))
                  buf)))
            dev-buf)))
      (when queue-buf
        (with-current-buffer queue-buf
          (vterm-send-C-c)
          (run-at-time "0.3 sec" nil
            (lambda (buf)
              (with-current-buffer buf
                (vterm-send-string "clear")
                (vterm-send-return)
                (run-at-time "0.3 sec" nil
                  (lambda (buf2)
                    (with-current-buffer buf2
                      (vterm-send-string "pnpm queue:dev")
                      (vterm-send-return)))
                  buf)))
            queue-buf)))
      (message "Clearing and restarting rec dev environment")))


(use-package ox-hugo
  :ensure t
  :after (ox))

(use-package simple-httpd
  :ensure t)



;; Remember last position in files (like a real bookmark)
(save-place-mode 1)
(setq bookmark-set-fringe-mark nil)


(use-package pdf-tools
  :ensure t
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :config
  (pdf-tools-install)
  (evil-define-key 'normal pdf-view-mode-map (kbd "SPC") nil)  ;; compiles the epdfinfo server
  ;; Auto-refresh PDF buffers when the file changes on disk (e.g. after LaTeX recompile)
  (add-hook 'pdf-view-mode-hook #'auto-revert-mode))

;; Extend save-place to remember PDF page positions
(use-package saveplace-pdf-view
  :ensure t
  :after pdf-tools)

(use-package org-noter
  :ensure (:host github :repo "org-noter/org-noter")
  :after pdf-tools)

;;; Book Reading Feature
;;; Quick access to currently reading books via org-roam + pdf-tools

(defvar mr-x/books-directory "~/Documents/Books/"
  "Directory where PDF books are stored.")

(defun mr-x/org-roam-get-reading-books ()
  "Return list of org-roam nodes tagged with 'reading'."
  (seq-filter
   (lambda (node)
     (member "reading" (org-roam-node-tags node)))
   (org-roam-node-list)))

(defun mr-x/book-format-candidate (node)
  "Format NODE as 'Title - Author' for completion display."
  (let* ((title (org-roam-node-title node))
         (author (or (cdr (assoc "AUTHOR" (org-roam-node-properties node)))
                     "Unknown")))
    (cons (format "%s - %s" title author) node)))

(defun mr-x/info-reading-bookmarks ()
  "Return alist of (display . bookmark-name) for Info reading bookmarks."
  (require 'bookmark)
  (bookmark-maybe-load-default-file)
  (mapcar
   (lambda (bm)
     (let* ((name (car bm))
            (manual (string-remove-prefix "info-reading/" name))
            (node (bookmark-prop-get name 'info-node)))
       (cons (format "%s @ %s [Info]" manual (or node "Top")) name)))
   (seq-filter
    (lambda (bm) (string-prefix-p "info-reading/" (car bm)))
    bookmark-alist)))

(defun mr-x/select-reading-book ()
  "Select a currently reading book or Info manual."
  (interactive)
  (let* ((books (mr-x/org-roam-get-reading-books))
         (book-candidates (mapcar #'mr-x/book-format-candidate books))
         (info-candidates (mr-x/info-reading-bookmarks))
         (all-candidates (append book-candidates info-candidates)))
    (if (null all-candidates)
        (user-error "Nothing currently being read. Use SPC r n to add a book")
      (let* ((choice (completing-read "Select: " all-candidates nil t))
             (value (cdr (assoc choice all-candidates))))
        (cond
         ((org-roam-node-p value) (mr-x/book-open-pdf value))
         ((stringp value) (bookmark-jump value)))))))

(defun mr-x/book-open-pdf (node)
  "Open the PDF for org-roam NODE at the saved page."
  (let* ((props (org-roam-node-properties node))
         (pdf-path (cdr (assoc "PDF_PATH" props)))
         (page (string-to-number (or (cdr (assoc "CURRENT_PAGE" props)) "1"))))
    (if (and pdf-path (file-exists-p (expand-file-name pdf-path)))
        (progn
          (find-file (expand-file-name pdf-path))
          (pdf-view-goto-page page))
      (user-error "PDF not found: %s" pdf-path))))

(defun mr-x/book-open-notes ()
  "Open the org-roam note for a reading book."
  (interactive)
  (let* ((books (mr-x/org-roam-get-reading-books))
         (candidates (mapcar #'mr-x/book-format-candidate books)))
    (if (null candidates)
        (user-error "No books currently being read")
      (let* ((choice (completing-read "Open notes for: " candidates nil t))
             (node (cdr (assoc choice candidates))))
        (find-file (org-roam-node-file node))))))

(defun mr-x/book-new ()
  "Create a new book note by selecting a PDF interactively."
  (interactive)
  (let* ((pdf (read-file-name "Select book PDF: " mr-x/books-directory nil t nil
                               (lambda (f) (or (directory-name-p f)
                                               (string-suffix-p ".pdf" f t)))))
         (pdf-path (abbreviate-file-name pdf))
         (default-title (file-name-sans-extension (file-name-nondirectory pdf)))
         (title (read-string (format "Book title [%s]: " default-title) nil nil default-title))
         (author (read-string "Author: "))
         (total-pages (let ((n (string-trim
                                (shell-command-to-string
                                 (format "mdls -name kMDItemNumberOfPages -raw %s"
                                         (shell-quote-argument (expand-file-name pdf)))))))
                        (if (string-match-p "^[0-9]+$" n) n
                          (number-to-string (read-number "Total pages: "))))))
    (org-roam-capture-
     :node (org-roam-node-create :title title)
     :templates
     `(("b" "book" plain
        "* Summary\n\n%?"
        :if-new (file+head
                 "${slug}.org"
                 ,(format ":PROPERTIES:\n:AUTHOR: %s\n:PDF_PATH: %s\n:CURRENT_PAGE: 1\n:TOTAL_PAGES: %s\n:NOTER_DOCUMENT: %s\n:END:\n#+title: ${title}\n#+filetags: reading\n"
                          author pdf-path total-pages pdf-path))
        :unnarrowed t)))))

(defun mr-x/book-update-progress ()
  "Save reading progress in current buffer (PDF or Info)."
  (interactive)
  (cond
   ((derived-mode-p 'Info-mode)
    (let* ((manual (file-name-sans-extension
                    (file-name-nondirectory Info-current-file)))
           (bm-name (format "info-reading/%s" manual)))
      (bookmark-set bm-name)
      (message "Saved progress: %s @ %s" manual Info-current-node)))
   ((derived-mode-p 'pdf-view-mode)
    (let* ((current-page (pdf-view-current-page))
           (pdf-file (expand-file-name (buffer-file-name)))
           (books (mr-x/org-roam-get-reading-books))
           (node (seq-find
                  (lambda (n)
                    (let ((p (cdr (assoc "PDF_PATH" (org-roam-node-properties n)))))
                      (and p (string= (expand-file-name p) pdf-file))))
                  books)))
      (unless node
        (user-error "No reading note found for this PDF"))
      (let ((org-file (org-roam-node-file node)))
        (with-current-buffer (find-file-noselect org-file)
          (goto-char (point-min))
          (org-entry-put (point) "CURRENT_PAGE" (number-to-string current-page))
          (save-buffer))
        (message "Progress saved: page %d" current-page))))
   (t (user-error "Not in a PDF or Info buffer"))))

(defun mr-x/book-mark-finished ()
  "Mark a reading book or Info manual as finished."
  (interactive)
  (let* ((books (mr-x/org-roam-get-reading-books))
         (book-candidates (mapcar #'mr-x/book-format-candidate books))
         (info-candidates (mr-x/info-reading-bookmarks))
         (all-candidates (append book-candidates info-candidates)))
    (if (null all-candidates)
        (user-error "Nothing currently being read")
      (let* ((choice (completing-read "Mark finished: " all-candidates nil t))
             (value (cdr (assoc choice all-candidates))))
        (cond
         ((org-roam-node-p value)
          (let ((file (org-roam-node-file value)))
            (with-current-buffer (find-file-noselect file)
              (goto-char (point-min))
              (when (re-search-forward "^#\\+filetags:.*\\breading\\b" nil t)
                (replace-match
                 (replace-regexp-in-string
                  "\\breading\\b" "read" (match-string 0)))
                (save-buffer)
                (message "Marked '%s' as finished!"
                         (org-roam-node-title value))))))
         ((stringp value)
          (bookmark-delete value)
          (message "Removed Info bookmark: %s"
                   (string-remove-prefix "info-reading/" value))))))))

(with-eval-after-load 'pdf-tools
  (defhydra hydra-pdf (:hint nil :color pink :foreign-keys run)
    "
PDF View
─────────────────────────────────────────────────
_j_/_k_: next/prev page     _+_/_-_: zoom in/out
_J_/_K_: scroll down/up     _0_: reset zoom
_g_: goto page               _f_: fit page
_G_: last page               _w_: fit width
                             _H_: fit height

_s_: search    _d_: dark mode     _o_: org-noter
_r_: revert    _a_: annotations   _c_: copy region

_q_: quit
"
    ("j" pdf-view-next-page)
    ("k" pdf-view-previous-page)
    ("J" pdf-view-scroll-up-or-next-page)
    ("K" pdf-view-scroll-down-or-previous-page)
    ("g" pdf-view-goto-page)
    ("G" pdf-view-last-page)
    ("+" pdf-view-enlarge)
    ("-" pdf-view-shrink)
    ("0" pdf-view-scale-reset)
    ("f" pdf-view-fit-page-to-window)
    ("w" pdf-view-fit-width-to-window)
    ("H" pdf-view-fit-height-to-window)
    ("s" isearch-forward :color blue)
    ("d" pdf-view-midnight-minor-mode)
    ("o" org-noter :color blue)
    ("a" pdf-annot-list-annotations :color blue)
    ("r" revert-buffer)
    ("c" pdf-view-kill-ring-save :color blue)
    ("q" nil :color blue))

  (evil-define-key 'normal pdf-view-mode-map (kbd ",") #'hydra-pdf/body))


(use-package sicp
  :ensure t)


(use-package markdown-mode
  :ensure t
  ;; Don't register .md here - poly-markdown-mode handles it (with code block highlighting)
  :custom
  (markdown-command "pandoc")
  :config
  ;; Gruvbox-styled markdown faces (matches preview CSS)
  (custom-set-faces
   ;; Headings - orange
   '(markdown-header-face-1 ((t (:foreground "#fe8019" :weight bold :height 1.4))))
   '(markdown-header-face-2 ((t (:foreground "#fe8019" :weight bold :height 1.3))))
   '(markdown-header-face-3 ((t (:foreground "#fe8019" :weight bold :height 1.2))))
   '(markdown-header-face-4 ((t (:foreground "#fabd2f" :weight bold :height 1.1))))
   '(markdown-header-face-5 ((t (:foreground "#fabd2f" :weight bold))))
   '(markdown-header-face-6 ((t (:foreground "#928374" :weight bold))))
   ;; Code - aqua
   '(markdown-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   '(markdown-inline-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   '(markdown-pre-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   ;; Links - blue
   '(markdown-link-face ((t (:foreground "#83a598"))))
   '(markdown-url-face ((t (:foreground "#83a598" :underline t))))
   ;; Bold/Italic - yellow/purple
   '(markdown-bold-face ((t (:foreground "#fabd2f" :weight bold))))
   '(markdown-italic-face ((t (:foreground "#d3869b" :slant italic))))
   ;; Lists - green
   '(markdown-list-face ((t (:foreground "#b8bb26"))))
   ;; Blockquote - gray
   '(markdown-blockquote-face ((t (:foreground "#928374" :slant italic))))
   ;; Markup characters - dimmed
   '(markdown-markup-face ((t (:foreground "#665c54"))))))

;; Syntax highlighting in markdown code blocks
(use-package polymode
  :ensure t)

(use-package poly-markdown
  :ensure t
  :after (polymode markdown-mode)
  :mode ("\\.md\\'" . poly-markdown-mode)
  :config
  ;; Suppress org-element parser errors in polymode indirect buffers
  ;; (org-mode chokes on markdown ** syntax in ```org code blocks)
  (add-to-list 'warning-suppress-types '(org-element)))

(use-package markdown-xwidget
  :ensure (:host github
           :repo "cfclrk/markdown-xwidget"
           :files (:defaults "resources"))
  :after markdown-mode
  :bind (:map markdown-mode-map
         ("C-c C-c x" . markdown-xwidget-preview-mode))
  :custom
  (markdown-xwidget-code-block-theme "gruvbox-dark-medium")
  (markdown-xwidget-github-theme "dark")
  :config
  ;; Custom CSS files for markdown preview
  (defvar mr-x/markdown-gruvbox-css-file
    (expand-file-name "etc/markdown-gruvbox-claude.css" user-emacs-directory))
  (defvar mr-x/agent-recall-css-file
    (expand-file-name "etc/agent-recall-transcript.css" user-emacs-directory))
  (defvar mr-x/agent-recall-js-file
    (expand-file-name "etc/agent-recall-transcript.js" user-emacs-directory))

  (defun mr-x/agent-recall-transcript-p ()
    "Return non-nil if current buffer is an agent-shell transcript."
    (and (buffer-file-name)
         (fboundp 'agent-recall--transcript-file-p)
         (agent-recall--transcript-file-p (buffer-file-name))))

  ;; Override the enable function to include custom CSS
  ;; and inject transcript JS when viewing agent-shell transcripts.
  ;; The original function overwrites markdown-css-paths with only 2 files,
  ;; so we must override it to include our custom CSS from the start.
  (defun markdown-xwidget-preview-mode--enable ()
    "Enable `markdown-xwidget-preview-mode' with custom CSS."
    (let* ((github-theme (markdown-xwidget-github-css-path
                          markdown-xwidget-github-theme))
           (code-block-theme (markdown-xwidget-highlightjs-css-path
                              markdown-xwidget-code-block-theme))
           (header-html (markdown-xwidget-header-html
                         markdown-xwidget-mermaid-theme))
           (command (or markdown-xwidget-command markdown-command))
           (is-transcript (mr-x/agent-recall-transcript-p))
           (custom-css (if is-transcript
                           mr-x/agent-recall-css-file
                         mr-x/markdown-gruvbox-css-file)))

      (if (not (featurep 'xwidget-internal))
          (user-error "This Emacs does not support xwidgets!"))

      ;; Save original and set CSS paths with appropriate custom CSS
      (setq markdown-xwidget--markdown-css-paths-original markdown-css-paths)
      (setq markdown-css-paths (list github-theme code-block-theme custom-css))

      ;; Temporarily set markdown-command
      (setq markdown-xwidget--markdown-command-original markdown-command)
      (setq markdown-command command)

      ;; Temporarily set markdown-live-preview-window-function
      ;; Use xwidget-preview but display in same window
      (setq markdown-xwidget--markdown-live-preview-window-function-original
            markdown-live-preview-window-function)
      (setq markdown-live-preview-window-function
            (lambda (file)
              (let ((buf (markdown-xwidget-preview file)))
                (display-buffer buf '(display-buffer-same-window))
                buf)))

      ;; Temporarily set markdown-xhtml-header-content
      ;; For transcripts, append the DOM-restructuring script
      (setq markdown-xwidget--markdown-xhtml-header-content-original
            markdown-xhtml-header-content)
      (setq markdown-xhtml-header-content
            (if is-transcript
                (concat header-html
                        "\n<script>\n"
                        "window.addEventListener('load', function() {\n"
                        (with-temp-buffer
                          (insert-file-contents mr-x/agent-recall-js-file)
                          (buffer-string))
                        "\n});\n</script>")
              header-html)))

    (markdown-live-preview-mode 1))
  
  ;; Redirect preview HTML files to a dedicated directory
  (defvar mr-x/markdown-preview-directory
    (expand-file-name "var/markdown-previews" user-emacs-directory)
    "Directory for markdown preview HTML files.")
  
  (defun mr-x/markdown-export-file-name-redirect (orig-fn &optional extension)
    "Redirect markdown export files to `mr-x/markdown-preview-directory'."
    (when-let ((original (funcall orig-fn extension)))
      (unless (file-exists-p mr-x/markdown-preview-directory)
        (make-directory mr-x/markdown-preview-directory t))
      (expand-file-name (file-name-nondirectory original)
                        mr-x/markdown-preview-directory)))
  
  (advice-add 'markdown-export-file-name :around
              #'mr-x/markdown-export-file-name-redirect))

  ;; Export markdown to gruvbox-themed PDF via pandoc
  (defun my/md-to-pdf ()
    "Export current markdown buffer to gruvbox PDF."
    (interactive)
    (let* ((input (buffer-file-name))
           (output (concat (file-name-sans-extension input) ".pdf"))
           (script (expand-file-name "~/roaming/futura-renaissance/pax-paints/to-pdf.sh")))
      (save-buffer)
      (shell-command (format "%s %s %s" script (shell-quote-argument input) (shell-quote-argument output)))
      (message "Exported: %s" output)))




;; Cache treesit-auto's remap alist — without this, the expensive
;; treesit-language-available-p gets called for all 53 languages on
;; EVERY file open (~0.7s each), destroying org-agenda perf (87 files).
;; See: https://github.com/renzmann/treesit-auto/issues/135
(defvar my/treesit-remap-cache nil)
(defun my/cache-treesit-remap (fn &rest args)
  (or my/treesit-remap-cache
      (setq my/treesit-remap-cache (apply fn args))))
(advice-add #'treesit-auto--build-major-mode-remap-alist
            :around #'my/cache-treesit-remap)

(use-package treesit-auto
  :ensure t
  :custom
  (treesit-auto-install 'prompt)  ;; Ask before installing grammars
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode))

(use-package yasnippet
  :ensure t
  :config
  (setq yas-snippet-dirs '("~/.emacs.d/snippets"))
  (define-key yas-minor-mode-map (kbd "<tab>") yas-maybe-expand)
  (define-key yas-minor-mode-map (kbd "TAB") yas-maybe-expand)
  (yas-global-mode 1))

(use-package yasnippet-snippets
  :ensure t
  :after yasnippet)

(use-package emmet-mode
  :ensure t
  :hook ((web-mode . emmet-mode)
         (html-mode . emmet-mode)
         (mhtml-mode . emmet-mode)
         (css-mode . emmet-mode)
         (tsx-ts-mode . emmet-mode))
  :config
  (setq emmet-move-cursor-between-quotes t
        emmet-expand-jsx-className? t))

;; Corfu for in-buffer completion
;; TAB-and-Go completion style:
;;   RET   → just inserts a newline, ignores the popup
;;   TAB   → cycles through candidates
;;   C-g   → dismisses the popup
;;   Keep typing → popup filters/dismisses naturally
(use-package corfu
  :ensure t
  :custom
  (corfu-cycle t)                ;; Enable cycling for `corfu-next/previous'
  (corfu-auto t)                 ;; Enable auto completion
  (corfu-auto-prefix 2)          ;; Minimum length of prefix
  (corfu-auto-delay 0.2)         ;; Delay before auto completion
  (corfu-quit-at-boundary nil)   ;; Never quit at completion boundary
  (corfu-quit-no-match t)        ;; Quit when there is no match
  (corfu-preview-current 'insert) ;; TAB-and-Go: cycling inserts the candidate
                                  ;; as a preview; keep typing to accept,
                                  ;; C-g to undo.  RET stays unbound on purpose
                                  ;; so it always sends/newlines in agent-shell.
  (corfu-on-exact-match nil)     ;; Configure handling of exact matches
  (corfu-preselect 'prompt)      ;; Don't preselect first candidate
  :bind (:map corfu-map
         ("TAB" . corfu-next)
         ([tab] . corfu-next)
         ("S-TAB" . corfu-previous)
         ([backtab] . corfu-previous))
  :init
  (global-corfu-mode)
  (keymap-unset corfu-map "RET"))

;; Extensions for Corfu
(use-package corfu-terminal
  :ensure t
  :after corfu
  :config
  (unless (display-graphic-p)
    (corfu-terminal-mode +1)))

;; Cape - extra completion-at-point backends for Corfu
(use-package cape
  :ensure t
  :config
  (require 'cape-keyword)
  ;; (add-hook 'completion-at-point-functions #'cape-dabbrev)  ;; heavy: scans all buffers
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-keyword)
  ;; (add-hook 'completion-at-point-functions #'cape-line)    ;; heavy: scans all buffers
  ;; (add-hook 'completion-at-point-functions #'cape-dict)    ;; heavy: reads system dictionary
  (add-hook 'completion-at-point-functions #'cape-history)
  (add-hook 'completion-at-point-functions #'cape-elisp-block)
  (add-hook 'completion-at-point-functions #'cape-elisp-symbol)
  (add-hook 'completion-at-point-functions #'cape-abbrev))

;; LSP Mode for Language Server Protocol support
(use-package lsp-mode
  :ensure t
  :commands (lsp lsp-deferred)
  :hook ((typescript-ts-mode . lsp-deferred)
         (tsx-ts-mode . lsp-deferred)
         (js-ts-mode . lsp-deferred)
         (web-mode . lsp-deferred))
  :init
  (setq lsp-keymap-prefix "C-c l")
  :config
  ;; Performance tuning
  (setq gc-cons-threshold 100000000)
  (setq read-process-output-max (* 1024 1024)) ;; 1mb
  (setq lsp-idle-delay 0.500)
  
  ;; UI settings
  (setq lsp-lens-enable nil)              ;; No code lens
  (setq lsp-headerline-breadcrumb-enable nil)  ;; No breadcrumbs
  (setq lsp-modeline-code-actions-enable nil)
  (setq lsp-modeline-diagnostics-enable t)
  (setq lsp-signature-auto-activate t)
  (setq lsp-signature-render-documentation nil)
  (setq lsp-eldoc-enable-hover t)
  (setq lsp-completion-provider :none)  ;; Let Corfu handle completion
  (setq lsp-enable-snippet t))

;; LSP UI for better LSP experience
(use-package lsp-ui
  :ensure t
  :commands (lsp-ui-mode lsp-ui-imenu)
  :hook (lsp-mode . lsp-ui-mode)
  :config
  (setq lsp-ui-sideline-enable nil)       ;; No sideline
  (setq lsp-ui-doc-enable t)              ;; Keep documentation
  (setq lsp-ui-doc-show-with-cursor nil)  ;; Don't show automatically
  (setq lsp-ui-doc-show-with-mouse t)     ;; Show on mouse hover
  (setq lsp-ui-doc-position 'at-point)
  (setq lsp-ui-peek-enable t))

(use-package consult-lsp
  :ensure t
  :after (lsp-mode consult))

;; Optional: Kind icon for completion candidates
(use-package kind-icon
  :ensure t
  :after corfu
  :custom
  (kind-icon-default-face 'corfu-default)
  (kind-icon-default-style '(:padding 0 :stroke 0 :margin 0 :radius 0 :height 0.8 :scale 1.0))
  :config
  (add-to-list 'corfu-margin-formatters #'kind-icon-margin-formatter))


(use-package rainbow-delimiters
  :ensure t
  :hook (prog-mode . rainbow-delimiters-mode))

(electric-indent-mode -1)

;; Flycheck for syntax checking
(use-package flycheck
  :ensure t
  :hook ((emacs-lisp-mode . flycheck-mode)
         (emacs-lisp-mode . (lambda ()
                              ;; Disable checkdoc nagging about docstrings
                              (setq-local flycheck-disabled-checkers '(emacs-lisp-checkdoc)))))
  :config
  (setq flycheck-indication-mode 'right-fringe)
  (setq flycheck-emacs-lisp-load-path 'inherit))

(use-package suggest
  :ensure t
  :defer t)

(use-package elisp-demos
  :ensure t
  :config
  (advice-add 'describe-function-1 :after #'elisp-demos-advice-describe-function-1))


;; Modern TypeScript setup with tree-sitter and LSP

;; Use built-in tree-sitter modes for TypeScript/TSX (Emacs 29+)
;; These provide better syntax highlighting and structural editing
(use-package typescript-ts-mode
  :mode (("\\.ts\\'" . typescript-ts-mode)
         ("\\.tsx\\'" . tsx-ts-mode))
  :config
  (setq typescript-indent-level 2))

;; Add LSP support for TypeScript
(add-hook 'typescript-ts-mode-hook #'lsp-deferred)
(add-hook 'tsx-ts-mode-hook #'lsp-deferred)
(add-hook 'js-ts-mode-hook #'lsp-deferred)

;; Configure LSP for TypeScript
(with-eval-after-load 'lsp-mode
  ;; TypeScript/JavaScript specific settings
  (setq lsp-typescript-preferences-import-module-specifier "relative"
        lsp-typescript-preferences-quote-style "single"
        lsp-typescript-format-enable t
        lsp-javascript-format-enable t
        lsp-typescript-tsserver-log-verbosity "off"
        lsp-javascript-display-return-type-hints t
        lsp-typescript-display-return-type-hints t))

;; Optional: Prettier formatting for TypeScript/JavaScript
(use-package prettier
  :ensure t
  :hook ((typescript-ts-mode . prettier-mode)
         (tsx-ts-mode . prettier-mode)
         (js-ts-mode . prettier-mode)
         (json-ts-mode . prettier-mode)
         (css-mode . prettier-mode))
  :config
  (setenv "NODE_PATH" "/opt/homebrew/lib/node_modules")

  (setq prettier-enabled-parsers '(typescript tsx javascript json css scss)))

;; Web-mode for legacy support and template files
(use-package web-mode
  :ensure t
  :mode (("\\.html?\\'" . web-mode)
         ("\\.phtml\\'" . web-mode)
         ("\\.php\\'" . web-mode)
         ("\\.[agj]sp\\'" . web-mode)
         ("\\.as[cp]x\\'" . web-mode)
         ("\\.erb\\'" . web-mode)
         ("\\.mustache\\'" . web-mode)
         ("\\.djhtml\\'" . web-mode)
         ("\\.vue\\'" . web-mode))
  :config
  (setq web-mode-markup-indent-offset 2
        web-mode-css-indent-offset 2
        web-mode-code-indent-offset 2
        web-mode-enable-auto-pairing t
        web-mode-enable-css-colorization t))

;; Optional: Tailwind CSS LSP support
(use-package lsp-tailwindcss
  ;; not on MELPA (:ensure t can't resolve it) — pin the upstream repo
  :ensure (:host github :repo "merrickluo/lsp-tailwindcss")
  :init
  (setq lsp-tailwindcss-add-on-mode t)
  ;; resolve the server on PATH (nvm on some machines, brew on others) rather
  ;; than hardcoding a brew path — exec-path-from-shell makes it findable.
  (when-let ((server (executable-find "tailwindcss-language-server")))
    (setq lsp-tailwindcss-server-path server))
  :config
  (add-to-list 'lsp-tailwindcss-major-modes 'tsx-ts-mode)
  (add-to-list 'lsp-tailwindcss-major-modes 'typescript-ts-mode))




  ;; Add the tree-sitter grammar source
(add-to-list 'treesit-language-source-alist
             '(prisma "https://github.com/victorhqc/tree-sitter-prisma"))

;; Kotlin tree-sitter grammar + mode
(add-to-list 'treesit-language-source-alist
             '(kotlin "https://github.com/fwcd/tree-sitter-kotlin"))

(use-package kotlin-ts-mode
  :ensure (:host gitlab :repo "bricka/emacs-kotlin-ts-mode")
  :mode "\\.kt\\'")

;; Install the mode from GitHub
(use-package prisma-ts-mode
  :ensure (:host github :repo "nverno/prisma-ts-mode")
  :mode "\\.prisma\\'")







(use-package dotenv-mode
  :ensure t
  :mode ("\\.env\\..*\\'" . dotenv-mode))


(use-package auctex
  :ensure (auctex :pre-build (("./autogen.sh")
                              ("./configure"
                               "--without-texmf-dir"
                               "--with-packagelispdir=."
                               "--with-packagedatadir=.")
                              ("make"))
                  :build (:not elpaca--compile-info)
                  :files ("*.el" "doc" "etc" "images" "latex" "style"))
  :mode ("\\.tex\\'" . LaTeX-mode)
  :config
  (setq TeX-auto-save t
        TeX-parse-self t
        TeX-PDF-mode t)
  (setq-default TeX-engine 'default)
  (setq TeX-view-program-selection '((output-pdf "PDF Tools")))
  (setq TeX-source-correlate-start-server t)
  ;; Auto-revert PDF buffer after AUCTeX compilation
  (add-hook 'TeX-after-compilation-finished-functions #'TeX-revert-document-buffer))

;; Compile .tex on save with latexmk
(defun mr-x/latex-compile-on-save ()
  "Compile current LaTeX file with latexmk in the background."
  (let ((tex-file (buffer-file-name)))
    (when (and tex-file (string-suffix-p ".tex" tex-file))
      (let ((default-directory (file-name-directory tex-file)))
        (start-process "latexmk" "*latexmk*"
                       "/Library/TeX/texbin/latexmk" "-pdf"
                       "-interaction=nonstopmode"
                       (file-name-nondirectory tex-file))))))

;; Hook into both built-in latex-mode and AUCTeX's LaTeX-mode
(dolist (hook '(latex-mode-hook LaTeX-mode-hook))
  (add-hook hook
            (lambda ()
              (add-hook 'after-save-hook #'mr-x/latex-compile-on-save nil t))))



  (use-package monet
    :ensure (:host github :repo "https://github.com/stevemolitor/monet")
    :config
    ;; Use ediff as the diff tool
    (setq monet-diff-tool 'ediff)
    
    ;; Comment out Delta functions for now - will deal with later
    ;; ;; Custom Delta-powered diff function for beautiful syntax highlighting
    ;; (defun mr-x/monet-delta-diff (old-file-path new-file-path new-file-contents on-accept on-quit &optional session)
    ;;   "Display diff using Delta for beautiful syntax highlighting."
    ;;   ;; Write new content to the new file path
    ;;   (with-temp-file new-file-path
    ;;     (insert new-file-contents))
    ;;   
    ;;   ;; Just run the delta diff command and let Emacs handle the display
    ;;   (let ((cmd (format "git diff --no-index %s %s | delta --paging=never"
    ;;                      (shell-quote-argument old-file-path)
    ;;                      (shell-quote-argument new-file-path))))
    ;;     (async-shell-command cmd "*Monet Delta Diff*"))
    ;;   
    ;;   ;; Return simple context
    ;;   (list :buffer-name "*Monet Delta Diff*"))

    ;; 
    ;; ;; Simple cleanup function
    ;; (defun mr-x/monet-delta-diff-cleanup (context)
    ;;   "Cleanup function for Delta diff."
    ;;   (when context
    ;;     (let ((diff-buffer (plist-get context :diff-buffer)))
    ;;       (when (and diff-buffer (buffer-live-p diff-buffer))
    ;;         (kill-buffer diff-buffer)))))

    ;;
    ;; ;; Set Delta as the diff tool with proper cleanup
    ;; (setq monet-diff-tool #'mr-x/monet-delta-diff)
    ;; (setq monet-diff-cleanup-tool #'mr-x/monet-delta-diff-cleanup)
    )

  ;;; Agent Shell - Native Emacs buffer for Claude Code
  ;; ACP (Agent Client Protocol) implementation for Emacs
  ;; Permission keys (1/2/3/0) only activate when a permission is pending;
  ;; otherwise they pass through to evil's digit-argument for motion counts (e.g., 13j).


;; ask-user-mcp lives under ~/roaming (Syncthing); load only when present so
;; a machine without ~/roaming yet doesn't abort all of init.
(let ((ask-user-dir "~/roaming/projects/MCP servers/ask-user-mcp/emacs"))
  ;; Guard on the actual files, not just the dir: Syncthing can create an
  ;; empty `emacs/' folder before the .el files sync, and a bare
  ;; `file-directory-p' check would then let `load-file' throw and abort
  ;; the rest of init (taking agent-shell, agent-recall, etc. down with it).
  (dolist (f '("ask-user.el" "ask-user-popup.el"))
    (let ((path (expand-file-name f ask-user-dir)))
      (when (file-exists-p path)
        (load-file path)))))

  (use-package acp
    :ensure (:host github :repo "xenodium/acp.el"))

  ;; Shell infrastructure for agent-shell
  (use-package shell-maker
    :ensure t)

  ;; Agent-shell ecosystem tangles to its own file
  (load (expand-file-name "agent-shell-config" user-emacs-directory))



  (use-package ledger-mode
    :ensure t
    :mode ("\\.dat\\'"
	   "\\.ledger\\'")
    :bind (:map ledger-mode-map
		("C-x C-s" . my/ledger-save))
    :preface
    (defvar my/ledger-finances-dir "~/roaming/personal/finances/"
      "Directory containing year-based ledger transaction files.")

    (defun my/ledger-current-year-file ()
      "Return path to current year's transaction file."
      (expand-file-name
       (format "%s-transactions.dat" (format-time-string "%Y"))
       my/ledger-finances-dir))

    (defun my/ledger-save ()
      "Automatically clean the ledger buffer at each save."
      (interactive)
      (save-excursion
	(when (buffer-modified-p)
	  (with-demoted-errors (ledger-mode-clean-buffer))
	  (save-buffer))))

    (defun my/ledger-get-accounts ()
      "Extract account names from current and previous year ledger files."
      (require 'ledger-mode)
      (let ((files (list (my/ledger-current-year-file)))
            (prev-year-file
             (expand-file-name
              (format "%s-transactions.dat"
                      (number-to-string (1- (string-to-number (format-time-string "%Y")))))
              my/ledger-finances-dir)))
        (when (file-exists-p prev-year-file)
          (push prev-year-file files))
        (with-temp-buffer
          (dolist (f files)
            (when (file-exists-p f)
              (goto-char (point-max))
              (insert-file-contents f nil nil nil t)))
          (let ((delay-mode-hooks t))
            (ledger-mode))
          (ledger-accounts-list-in-buffer))))

    (defun my/ledger-quick-add ()
      "Quickly add a ledger transaction from anywhere in Emacs.
Prompts for payee, amount, expense account, and payment source.
Appends to the current year's transaction file."
      (interactive)
      (require 'ledger-mode)
      (let* ((accounts (my/ledger-get-accounts))
             (date (format-time-string "%Y/%m/%d"))
             (payee (read-string "Payee: "))
             (amount (read-string "Amount: $"))
             (expense-account (completing-read "Expense account: " accounts nil nil "Expenses:"))
             (payment-source (completing-read "Payment source: " accounts nil nil))
             (file (my/ledger-current-year-file))
             (transaction (format "%s %s\n    %s  $%s\n    %s\n"
                                  date payee expense-account amount payment-source)))
        (with-temp-buffer
          (when (file-exists-p file)
            (insert-file-contents file)
            (goto-char (point-max)))
          (unless (or (bobp) (looking-back "\n\n" nil))
            (insert "\n"))
          (insert transaction)
          (write-region (point-min) (point-max) file))
        (when-let ((buf (find-buffer-visiting file)))
          (with-current-buffer buf
            (revert-buffer t t t)))
        (message "Added: %s %s | %s $%s -> %s"
                 date payee expense-account amount payment-source)))

    (defun my/ledger-simplefin-sync ()
      "Sync transactions from SimpleFIN into ledger."
      (interactive)
      (unless (y-or-n-p "Pull transactions from SimpleFIN? ")
        (user-error "Sync cancelled"))
      (let* ((script (expand-file-name "~/.dotfiles/macos/scripts/simplefin-sync.py"))
             (buf (get-buffer-create "*simplefin-sync*")))
        (with-current-buffer buf
          (erase-buffer)
          (insert "Syncing from SimpleFIN...\n\n"))
        (display-buffer buf)
        (set-process-sentinel
         (start-process "simplefin-sync" buf "python3" script)
         (lambda (proc _event)
           (when (eq (process-status proc) 'exit)
             (let ((file (my/ledger-current-year-file)))
               (when-let ((visited (find-buffer-visiting file)))
                 (with-current-buffer visited
                   (revert-buffer t t t))))
             (with-current-buffer (process-buffer proc)
               (goto-char (point-max))
               (insert "\nDone.")))))))

    (defun my/ledger-report-run (name cmd)
      "Run a ledger report CMD and display in buffer NAME."
      (let ((buf (get-buffer-create (format "*ledger: %s*" name)))
            (file (my/ledger-current-year-file)))
        (with-current-buffer buf
          (erase-buffer)
          (insert (format "── %s ──\n\n" name))
          (call-process-shell-command
           (format "ledger -f %s %s" (shell-quote-argument file) cmd)
           nil buf t)
          (goto-char (point-min)))
        (display-buffer buf)))

    (defun my/ledger-report-balance ()
      "Show all account balances."
      (interactive)
      (my/ledger-report-run "Balances" "balance"))

    (defun my/ledger-report-expenses ()
      "Show expenses sorted by amount."
      (interactive)
      (my/ledger-report-run "Expenses" "balance Expenses --sort \"-amount\""))

    (defun my/ledger-report-monthly ()
      "Show monthly spending breakdown."
      (interactive)
      (my/ledger-report-run "Monthly Spending" "register Expenses --monthly --collapse"))

    (defun my/ledger-report-subscriptions ()
      "Show subscription spending."
      (interactive)
      (my/ledger-report-run "Subscriptions" "balance Expenses:Subscriptions"))

    (defun my/ledger-report-register ()
      "Show full transaction register."
      (interactive)
      (my/ledger-report-run "Register" "register"))

    (defun my/ledger-report-net-worth ()
      "Show net worth (Assets + Liabilities)."
      (interactive)
      (my/ledger-report-run "Net Worth" "balance Assets Liabilities")))


(with-eval-after-load 'transient
  (require 'trakt-sync))

(use-package page-break-lines
  :ensure t)

(use-package posframe
  :ensure t)

(use-package ytr
  :vc (:url "https://github.com/xenodium/ytr" :rev :newest)
  :commands (ytr)
  :hook (ytr-mode . evil-emacs-state))
