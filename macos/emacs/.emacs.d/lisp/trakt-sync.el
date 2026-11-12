;;; trakt-sync.el --- Sync movies-watched.org to Trakt -*- lexical-binding: t; -*-

;;; Commentary:
;; Interactive Trakt sync with poster display.
;; M-x trakt-sync to start, M-x trakt-sync-test-ui to preview styling.

;;; Code:

(require 'json)
(require 'url)
(require 'cl-lib)
(require 'transient)
(require 'mr-x-popup)

(defcustom trakt-sync-script-dir
  (expand-file-name "~/roaming/code/trakt-sync/")
  "Directory containing the Python sync scripts."
  :type 'directory
  :group 'applications)

(defcustom trakt-sync-org-file
  (expand-file-name "~/roaming/notes/movies-watched.org")
  "Path to movies-watched.org."
  :type 'file
  :group 'applications)

(defcustom trakt-sync-watchlist-org-file
  (expand-file-name "~/roaming/notes/movies-to-watch.org")
  "Path to movies-to-watch.org."
  :type 'file
  :group 'applications)

(defcustom trakt-sync-python "python3"
  "Python executable."
  :type 'string
  :group 'applications)

(defcustom trakt-sync-after-log-command
  (expand-file-name "letterboxd-kick.sh" trakt-sync-script-dir)
  "Program run in the background after `log-watched' syncs to Trakt.
The default mirrors the new play to Letterboxd.  Skipped when the file is
not executable; set to nil to turn it off."
  :type '(choice (const :tag "None" nil) file)
  :group 'applications)

(defcustom trakt-sync-poster-width 100
  "Width of poster thumbnails in pixels."
  :type 'integer
  :group 'applications)

;;; --- State ---

(defvar trakt-sync--window-config nil "Saved window config to restore on quit.")
(defvar trakt-sync--entries nil "All entries from the candidates call.")
(defvar trakt-sync--unmatched nil "Unmatched entries queue.")
(defvar trakt-sync--current nil "Current entry being resolved.")
(defvar trakt-sync--selected 0 "Currently highlighted candidate index.")
(defvar trakt-sync--resolved 0 "Count of resolved entries.")
(defvar trakt-sync--skipped 0 "Count of skipped entries.")
(defvar trakt-sync--poster-cache (make-hash-table :test 'equal))
(defvar trakt-sync--continuation nil "What to do after current pick.")
(defvar trakt-sync--mode 'history "Current mode: `history' or `watchlist'.")

;;; --- Faces ---

(defface trakt-sync-org-title
  '((t :inherit font-lock-string-face :height 1.3 :weight bold))
  "Your org entry title.")

(defface trakt-sync-movie-title
  '((t :inherit font-lock-keyword-face :weight bold))
  "Candidate movie title.")

(defface trakt-sync-year
  '((t :inherit font-lock-constant-face))
  "Movie year.")

(defface trakt-sync-overview
  '((t :inherit font-lock-comment-face :slant italic))
  "Movie overview.")

(defface trakt-sync-url
  '((t :inherit link :underline t))
  "Trakt URL.")

(defface trakt-sync-selected
  '((t :inverse-video t :extend t))
  "Selected candidate.")

(defface trakt-sync-keyhint
  '((t :inherit font-lock-doc-face))
  "Keybinding hints.")

(defface trakt-sync-header
  '((t :inherit font-lock-preprocessor-face :height 1.1 :weight bold))
  "Header.")

(defface trakt-sync-progress
  '((t :inherit shadow))
  "Progress indicator.")

(defface trakt-sync-separator
  '((t :inherit shadow))
  "Separator line.")

;;; --- Keymap (suppress-keymap so Evil normal keys work, numbers don't count) ---

(defvar trakt-sync-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "j") #'trakt-sync-next-candidate)
    (define-key map (kbd "k") #'trakt-sync-prev-candidate)
    (define-key map (kbd "C-n") #'trakt-sync-next-candidate)
    (define-key map (kbd "C-p") #'trakt-sync-prev-candidate)
    (define-key map (kbd "RET") #'trakt-sync-confirm)
    (define-key map (kbd "<return>") #'trakt-sync-confirm)
    (define-key map (kbd "s") #'trakt-sync-search-again)
    (define-key map (kbd "l") #'trakt-sync-lookup)
    (define-key map (kbd "x") #'trakt-sync-skip)
    (define-key map (kbd "C") #'trakt-sync-commit)
    (define-key map (kbd "q") #'trakt-sync-quit)
    (define-key map (kbd "C-g") #'trakt-sync-quit)
    map))

(define-derived-mode trakt-sync-mode special-mode "Trakt"
  "Mode for Trakt sync candidate picker."
  (setq buffer-read-only t
        truncate-lines nil
        cursor-type nil)
  (setq-local mode-line-format nil))

;; Evil integration
(with-eval-after-load 'evil-snipe
  (add-to-list 'evil-snipe-disabled-modes 'trakt-sync-mode))

(with-eval-after-load 'evil
  (evil-set-initial-state 'trakt-sync-mode 'normal)
  (evil-define-key 'normal trakt-sync-mode-map
    (kbd "j") #'trakt-sync-next-candidate
    (kbd "k") #'trakt-sync-prev-candidate
    (kbd "RET") #'trakt-sync-confirm
    (kbd "<return>") #'trakt-sync-confirm
    (kbd "s") #'trakt-sync-search-again
    (kbd "l") #'trakt-sync-lookup
    (kbd "x") #'trakt-sync-skip
    (kbd "C") #'trakt-sync-commit
    (kbd "q") #'trakt-sync-quit
    (kbd "<escape>") #'trakt-sync-quit))

;;; --- Poster fetching ---

(defun trakt-sync--fetch-poster (url callback)
  "Fetch poster from URL, call CALLBACK with image or nil."
  (when url
    (let ((cached (gethash url trakt-sync--poster-cache)))
      (if cached
          (funcall callback cached)
        (url-retrieve
         url
         (lambda (status cb-url cb-fn)
           (if (plist-get status :error)
               (funcall cb-fn nil)
             (goto-char (point-min))
             (when (re-search-forward "\r?\n\r?\n" nil t)
               (let* ((raw (buffer-substring-no-properties (point) (point-max)))
                      (img (create-image raw nil t
                                         :width trakt-sync-poster-width
                                         :ascent 'center)))
                 (puthash cb-url img trakt-sync--poster-cache)
                 (funcall cb-fn img)))))
         (list url callback)
         t t)))))

(defun trakt-sync--insert-poster-async (url marker)
  "Fetch poster at URL, replace placeholder at MARKER."
  (when url
    (trakt-sync--fetch-poster
     url
     (lambda (img)
       (when (and img (buffer-live-p (marker-buffer marker)))
         (with-current-buffer (marker-buffer marker)
           (let ((inhibit-read-only t))
             (save-excursion
               (goto-char marker)
               (when (looking-at "\\[loading\\.\\.\\.]")
                 (delete-region (match-beginning 0) (match-end 0))
                 (insert-image img "[poster]"))))))))))

;;; --- Selection overlay ---

(defvar-local trakt-sync--selection-overlay nil)

(defun trakt-sync--move-selection ()
  "Move the selection overlay to the title line of the current candidate."
  (when trakt-sync--selection-overlay
    (let ((pos (text-property-any (point-min) (point-max)
                                  'trakt-title-idx trakt-sync--selected)))
      (when pos
        (save-excursion
          (goto-char pos)
          (move-overlay trakt-sync--selection-overlay
                        (line-beginning-position)
                        (1+ (line-end-position)))))))
  ;; Update poster preview
  (trakt-sync--update-poster-preview))

;;; --- Rendering ---

(defvar-local trakt-sync--poster-marker nil "Marker where poster image lives.")
(defvar-local trakt-sync--current-candidates nil "Candidates for current render.")

(defun trakt-sync--fetch-poster-sync (url)
  "Fetch poster at URL synchronously. Return image or nil."
  (when url
    (let ((cached (gethash url trakt-sync--poster-cache)))
      (if cached cached
        (condition-case _
            (let ((buf (url-retrieve-synchronously url t t 5)))
              (when buf
                (unwind-protect
                    (with-current-buffer buf
                      (goto-char (point-min))
                      (when (re-search-forward "\r?\n\r?\n" nil t)
                        (let* ((raw (buffer-substring-no-properties (point) (point-max)))
                               (img (ignore-errors
                                      (create-image raw nil t
                                                     :width trakt-sync-poster-width
                                                     :ascent 'center))))
                          (when img
                            (puthash url img trakt-sync--poster-cache))
                          img)))
                  (kill-buffer buf))))
          (error nil))))))

(defun trakt-sync--update-poster-preview ()
  "Update the poster preview area to show the selected candidate's poster."
  (when (and trakt-sync--poster-marker
             trakt-sync--current-candidates
             (< trakt-sync--selected (length trakt-sync--current-candidates)))
    (let* ((c (nth trakt-sync--selected trakt-sync--current-candidates))
           (poster-url (let ((v (alist-get 'poster c))) (and (stringp v) v)))
           (overview (let ((v (alist-get 'overview c))) (if (stringp v) v "")))
           (slug (let ((v (alist-get 'slug c))) (and (stringp v) v)))
           (inhibit-read-only t))
      (save-excursion
        (goto-char trakt-sync--poster-marker)
        ;; Clear poster region (everything between poster marker and candidates list)
        (let ((end (text-property-any (point) (point-max) 'trakt-candidates-start t)))
          (when end
            (delete-region trakt-sync--poster-marker end)))
        ;; Insert poster
        (insert "\n")
        (let ((img (trakt-sync--fetch-poster-sync poster-url)))
          (if img
              (progn (insert "  ") (insert-image img "[poster]"))
            (insert "  [no poster]")))
        (insert "\n\n")
        ;; Overview
        (when (and overview (not (string-empty-p overview)))
          (let* ((max-len 200)
                 (short (if (> (length overview) max-len)
                            (concat (substring overview 0 (min max-len (length overview))) "...")
                          overview)))
            (insert "  " (propertize short 'face 'trakt-sync-overview) "\n")))
        ;; URL
        (when slug
          (insert "  " (propertize (format "trakt.tv/movies/%s" slug) 'face 'trakt-sync-url) "\n"))
        (insert "\n")))))

(defun trakt-sync--render (entry candidates &optional total-unmatched current-num)
  "Render the picker buffer for ENTRY with CANDIDATES."
  (let ((buf (get-buffer-create "*trakt-sync*"))
        (inhibit-read-only t)
        (org-title (alist-get 'org_title entry))
        (watched (alist-get 'watched_date entry)))
    (with-current-buffer buf
      (trakt-sync-mode)
      (erase-buffer)
      (remove-overlays)
      (setq trakt-sync--current-candidates candidates)

      ;; Header
      (insert "\n ")
      (insert (propertize (pcase trakt-sync--mode
                            ('watchlist "TRAKT WATCHLIST")
                            ('log-watched "LOG WATCHED")
                            (_ "TRAKT SYNC"))
                          'face 'trakt-sync-header))
      (when (and current-num total-unmatched)
        (insert (propertize (format "  %d/%d" current-num total-unmatched)
                            'face 'trakt-sync-progress)))
      (insert "\n")
      (insert " " (propertize (make-string 50 ?─) 'face 'trakt-sync-separator) "\n\n")

      ;; Your entry
      (insert "  ")
      (insert (propertize (if (stringp org-title) org-title "?") 'face 'trakt-sync-org-title))
      (when (stringp watched)
        (insert "  " (propertize watched 'face 'trakt-sync-year)))
      (insert "\n")

      ;; Poster preview area (for selected candidate)
      (setq trakt-sync--poster-marker (point-marker))
      (set-marker-insertion-type trakt-sync--poster-marker nil)
      ;; Placeholder — will be filled by trakt-sync--update-poster-preview
      (insert "\n\n")

      ;; Candidates list marker
      (insert " ")
      (put-text-property (1- (point)) (point) 'trakt-candidates-start t)

      (insert (propertize (make-string 50 ?─) 'face 'trakt-sync-separator) "\n\n")

      ;; Candidates list (compact — just number + title + year)
      (if (null candidates)
          (insert (propertize "  No results found. Press [s] to search again.\n" 'face 'error))
        (let ((idx 0))
          (dolist (c candidates)
            (let* ((title (let ((v (alist-get 'title c))) (if (stringp v) v "?")))
                   (year (let ((v (alist-get 'year c))) (and (numberp v) v)))
                   (title-start (point)))

              (insert (format "  %d  " (1+ idx)))
              (insert (propertize title 'face 'trakt-sync-movie-title))
              (when year
                (insert " " (propertize (format "(%s)" year) 'face 'trakt-sync-year)))

              ;; Tag title line only
              (put-text-property title-start (point) 'trakt-title-idx idx)
              (put-text-property title-start (point) 'trakt-candidate-idx idx)
              (insert "\n")

              (setq idx (1+ idx))))))

      (insert "\n")

      ;; Keybindings
      (insert " " (propertize (make-string 50 ?─) 'face 'trakt-sync-separator) "\n")
      (insert "  "
              (propertize "j/k" 'face 'trakt-sync-keyhint) " navigate  "
              (propertize "RET" 'face 'trakt-sync-keyhint) " confirm  "
              (propertize "s" 'face 'trakt-sync-keyhint) " search  "
              (propertize "l" 'face 'trakt-sync-keyhint) " lookup  "
              (propertize "x" 'face 'trakt-sync-keyhint) " skip  "
              (propertize "C" 'face 'trakt-sync-keyhint) " commit  "
              (propertize "q" 'face 'trakt-sync-keyhint) " quit"
              "\n")

      ;; Selection overlay (title line only)
      (setq trakt-sync--selection-overlay (make-overlay 1 1))
      (overlay-put trakt-sync--selection-overlay 'face 'trakt-sync-selected)
      (setq trakt-sync--selected 0)
      (trakt-sync--move-selection)

      (goto-char (point-min)))

    ;; Full screen (save layout first)
    (unless trakt-sync--window-config
      (setq trakt-sync--window-config (current-window-configuration)))
    (switch-to-buffer buf)
    (delete-other-windows)))

;;; --- Commands ---

(defun trakt-sync-next-candidate ()
  "Move to next candidate."
  (interactive)
  (let ((entry (or trakt-sync--current (car trakt-sync--unmatched))))
    (when entry
      (let ((n (length (alist-get 'candidates entry))))
        (when (> n 0)
          (setq trakt-sync--selected (mod (1+ trakt-sync--selected) n))
          (trakt-sync--move-selection))))))

(defun trakt-sync-prev-candidate ()
  "Move to previous candidate."
  (interactive)
  (let ((entry (or trakt-sync--current (car trakt-sync--unmatched))))
    (when entry
      (let ((n (length (alist-get 'candidates entry))))
        (when (> n 0)
          (setq trakt-sync--selected (mod (1- trakt-sync--selected) n))
          (trakt-sync--move-selection))))))

(defun trakt-sync-confirm ()
  "Confirm the currently selected candidate."
  (interactive)
  (let* ((entry (or trakt-sync--current (car trakt-sync--unmatched)))
         (candidates (alist-get 'candidates entry))
         (choice (nth trakt-sync--selected candidates)))
    (when choice
      (if (eq trakt-sync--mode 'log-watched)
          (trakt-sync--log-watched-finish choice)
        (let ((org-title (alist-get 'org_title entry)))
          (trakt-sync--save-mapping org-title choice)
          (setq trakt-sync--resolved (1+ trakt-sync--resolved))
          (message "Mapped \"%s\" -> %s (%s)"
                   org-title
                   (alist-get 'title choice)
                   (alist-get 'year choice))
          (trakt-sync--advance))))))

(defun trakt-sync-skip ()
  "Skip the current entry."
  (interactive)
  (setq trakt-sync--skipped (1+ trakt-sync--skipped))
  (message "Skipped.")
  (trakt-sync--advance))

(defun trakt-sync-search-again ()
  "Search with a new query."
  (interactive)
  (let* ((entry (or trakt-sync--current (car trakt-sync--unmatched)))
         (org-title (alist-get 'org_title entry))
         (query (read-string (format "Search (was \"%s\"): " org-title) org-title))
         (results (trakt-sync--run-python "search" (shell-quote-argument query))))
    (when results
      (setf (alist-get 'candidates entry) results)
      (setq trakt-sync--selected 0)
      (trakt-sync--render entry results
                          (length trakt-sync--unmatched)
                          (1+ (- (length trakt-sync--unmatched)
                                 (length (memq entry trakt-sync--unmatched))))))))

(defun trakt-sync-lookup ()
  "Look up a movie by Trakt URL or slug."
  (interactive)
  (let* ((entry (or trakt-sync--current (car trakt-sync--unmatched)))
         (input (read-string "Trakt URL or slug: "))
         (results (trakt-sync--run-python "lookup" (shell-quote-argument input))))
    (if (or (null results) (= (length results) 0))
        (message "Not found: %s" input)
      (setf (alist-get 'candidates entry) results)
      (setq trakt-sync--selected 0)
      (trakt-sync--render entry results
                          (length trakt-sync--unmatched)
                          (1+ (- (length trakt-sync--unmatched)
                                 (length (memq entry trakt-sync--unmatched))))))))

(defun trakt-sync-quit ()
  "Quit trakt-sync and restore window layout."
  (interactive)
  (when (or (eq trakt-sync--mode 'log-watched)
            (y-or-n-p "Quit trakt-sync? Mappings so far are saved. "))
    (kill-buffer "*trakt-sync*")
    (when trakt-sync--window-config
      (set-window-configuration trakt-sync--window-config)
      (setq trakt-sync--window-config nil))))

(defun trakt-sync--advance ()
  "Move to the next unmatched entry."
  (setq trakt-sync--unmatched (cdr trakt-sync--unmatched))
  (if trakt-sync--unmatched
      (let ((entry (car trakt-sync--unmatched)))
        (setq trakt-sync--current entry)
        (setq trakt-sync--selected 0)
        (trakt-sync--render entry (alist-get 'candidates entry)
                            (+ (length trakt-sync--unmatched) trakt-sync--resolved trakt-sync--skipped)
                            (+ 1 trakt-sync--resolved trakt-sync--skipped)))
    (trakt-sync--show-done)))

(defun trakt-sync--show-done ()
  "Show completion message."
  (let ((buf (get-buffer-create "*trakt-sync*"))
        (inhibit-read-only t))
    (with-current-buffer buf
      (erase-buffer)
      (remove-overlays)
      (trakt-sync-mode)
      (insert "\n")
      (insert "  " (propertize "TRAKT SYNC" 'face 'trakt-sync-header) "\n")
      (insert "  " (propertize (make-string 50 ?─) 'face 'trakt-sync-separator) "\n\n")
      (insert (format "  %d resolved, %d skipped\n\n"
                      trakt-sync--resolved trakt-sync--skipped))
      (insert "  " (propertize "C" 'face 'trakt-sync-keyhint) " commit to Trakt  "
              (propertize "q" 'face 'trakt-sync-keyhint) " quit\n")
      (goto-char (point-min)))))

;;; --- Python interface ---

(defun trakt-sync--run-python (command &rest args)
  "Run sync_emacs.py with COMMAND and ARGS, return parsed JSON."
  (let* ((default-directory trakt-sync-script-dir)
         (cmd (string-join
               (append (list trakt-sync-python "sync_emacs.py" command) args)
               " "))
         (output (shell-command-to-string cmd)))
    (condition-case err
        (json-parse-string output :object-type 'alist :array-type 'list)
      (error
       (message "trakt-sync: JSON parse error: %s\nOutput: %s" err output)
       nil))))

(defun trakt-sync--save-mapping (org-title candidate)
  "Save mapping from ORG-TITLE to CANDIDATE."
  (let ((cmd (if (eq trakt-sync--mode 'watchlist) "watchlist-save" "save-mapping")))
    (trakt-sync--run-python cmd
                            (shell-quote-argument org-title)
                            (shell-quote-argument (json-encode candidate)))))

(defun trakt-sync-open-trakt ()
  "Open Trakt.tv in the browser."
  (interactive)
  (browse-url "https://trakt.tv"))

(defun trakt-sync-commit ()
  "Commit all mapped entries to Trakt."
  (interactive)
  (let* ((watchlist-p (eq trakt-sync--mode 'watchlist))
         (prompt (if watchlist-p
                     "Add all mapped movies to Trakt watchlist? "
                   "Sync all mapped movies to Trakt history? "))
         (cmd (if watchlist-p "watchlist-commit" "commit"))
         (org-file (if watchlist-p trakt-sync-watchlist-org-file trakt-sync-org-file)))
    (when (y-or-n-p prompt)
      (message "Syncing to Trakt...")
      (let ((result (trakt-sync--run-python cmd (shell-quote-argument org-file))))
        (if result
            (message "trakt-sync: %s" (or (alist-get 'message result) "Done!"))
          (message "trakt-sync: commit failed — check *Messages*"))))))

;;; --- Mock / Test ---

(defun trakt-sync-test-ui ()
  "Preview the picker UI with mock data."
  (interactive)
  (setq trakt-sync--resolved 0
        trakt-sync--skipped 0
        trakt-sync--selected 0)
  (let ((mock-entry
         '((org_title . "Sinners")
           (watched_date . "2025-09-11")
           (status . "unmatched")
           (candidates .
            (((title . "Sinner: The Secret Diary of a Nymphomaniac")
              (year . 1973)
              (overview . "Linda comes to the big city in search of fun and excitement. What she finds is exploitation and abuse at the hands of a succession of sleazy guys.")
              (poster . "https://media.trakt.tv/images/movies/000/126/694/posters/medium/e5bc58972a.jpg.webp")
              (slug . "sinner-the-secret-diary-of-a-nymphomaniac-1973")
              (ids . ((trakt . 126694))))
             ((title . "Saint Sinner")
              (year . 2002)
              (overview . "In 1815 a monk unwittingly unleashes two female succubi upon an unsuspecting 21st century. He is chosen by God to travel through the centuries and stop the demons' rampage.")
              (poster . "https://media.trakt.tv/images/movies/000/016/430/posters/medium/a6524addde.jpg.webp")
              (slug . "saint-sinner-2002")
              (ids . ((trakt . 16430))))
             ((title . "Half a Sinner")
              (year . 1940)
              (overview . "A bored young woman decides to be bad for a day. She steals a car, only to find a dead body in the back seat.")
              (poster . "https://media.trakt.tv/images/movies/000/133/757/posters/medium/1776f61b7f.jpg.webp")
              (slug . "half-a-sinner-1940")
              (ids . ((trakt . 133757)))))))))
    (setq trakt-sync--current mock-entry)
    (setq trakt-sync--unmatched (list mock-entry))
    (trakt-sync--render mock-entry
                        (alist-get 'candidates mock-entry)
                        12 5)))

;;; --- Log watched ---

(defun trakt-sync--append-to-file (filepath line)
  "Append LINE as a new line at the end of FILEPATH."
  (let* ((existing-buf (find-buffer-visiting filepath))
         (buf (or existing-buf (find-file-noselect filepath))))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert line "\n"))
      (save-buffer))
    (unless existing-buf
      (kill-buffer buf))))

(defun trakt-sync--remove-from-watchlist-org (movie-title)
  "Remove MOVIE-TITLE from movies-to-watch.org if present.
Returns t if a line was removed."
  (let* ((filepath trakt-sync-watchlist-org-file)
         (existing-buf (find-buffer-visiting filepath))
         (buf (or existing-buf (find-file-noselect filepath)))
         (title-down (downcase movie-title))
         (removed nil))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^\\* \\(.+\\)$" nil t)
          (let* ((raw (string-trim (match-string 1)))
                 (clean (string-trim
                         (replace-regexp-in-string "\\s-*(\\([0-9]\\{4\\}\\))\\s-*$" "" raw))))
            (when (string= (downcase clean) title-down)
              (delete-region (line-beginning-position)
                             (min (1+ (line-end-position)) (point-max)))
              (setq removed t)))))
      (when removed (save-buffer)))
    (unless existing-buf
      (kill-buffer buf))
    removed))

(defun trakt-sync--log-watched-finish (movie)
  "Complete the log-watched flow: prompt for date, update org files, sync Trakt."
  (let* ((title (alist-get 'title movie))
         (year (alist-get 'year movie))
         (today (format-time-string "%m/%d/%y"))
         (date (read-string (format "Date watched (default %s): " today) nil nil today))
         (org-line (format "* %s - %s" title date)))
    ;; Append to movies-watched.org
    (trakt-sync--append-to-file trakt-sync-org-file org-line)
    ;; Remove from movies-to-watch.org if present
    (let ((removed (trakt-sync--remove-from-watchlist-org title)))
      ;; Sync to Trakt
      (message "Syncing to Trakt...")
      (let ((result (trakt-sync--run-python
                     "log-watched"
                     (shell-quote-argument (json-encode movie))
                     (shell-quote-argument date))))
        ;; Close picker and restore windows
        (kill-buffer "*trakt-sync*")
        (when trakt-sync--window-config
          (set-window-configuration trakt-sync--window-config)
          (setq trakt-sync--window-config nil))
        ;; Report
        (if (null result)
            (message "WARNING: Logged to org but Trakt sync FAILED for %s — check *Messages*" title)
          (message "Logged: %s%s — %s%s%s"
                   title
                   (if year (format " (%s)" year) "")
                   date
                   (if removed " (removed from watchlist)" "")
                   (if (trakt-sync--run-after-log) ", Letterboxd queued" "")))))))

(defun trakt-sync--run-after-log ()
  "Start `trakt-sync-after-log-command' in the background.
Return non-nil when it was started.  A failure is reported in the echo area
when the process exits; output stays in the \" *trakt-sync-after-log*\" buffer."
  (let ((cmd trakt-sync-after-log-command))
    (when (and cmd (file-executable-p cmd))
      (let ((buf (get-buffer-create " *trakt-sync-after-log*")))
        (with-current-buffer buf (erase-buffer))
        (make-process
         :name "trakt-sync-after-log"
         :buffer buf
         :command (list cmd)
         :noquery t
         :sentinel (lambda (proc _event)
                     (when (and (memq (process-status proc) '(exit signal))
                                (/= (process-exit-status proc) 0))
                       (message "Letterboxd push failed (exit %d): see buffer %s"
                                (process-exit-status proc)
                                (buffer-name (process-buffer proc))))))
        t))))

;;;###autoload
(defun trakt-sync--watchlist-titles ()
  "Return list of titles from movies-to-watch.org."
  (let ((filepath trakt-sync-watchlist-org-file)
        titles)
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      (while (re-search-forward "^\\* \\(.+\\)$" nil t)
        (push (string-trim (match-string 1)) titles)))
    (nreverse titles)))

;;;###autoload
(defun log-watched ()
  "Log a movie as watched.
Searches Trakt, shows the picker, prompts for date, then:
- Appends to movies-watched.org
- Removes from movies-to-watch.org (if present)
- Syncs to Trakt history
- Removes from Trakt watchlist (if present)"
  (interactive)
  (let ((query (mr-x/popup-prompt "What did you watch?"
                                  "Pick from your watchlist or type a title"
                                  (trakt-sync--watchlist-titles)
                                  :header "LOG WATCHED")))
    (unless query (user-error "Cancelled"))
    (message "Searching Trakt...")
    (let ((results (trakt-sync--run-python "search" (shell-quote-argument query))))
      (unless results
        (user-error "No results found for \"%s\"" query))
      (setq trakt-sync--mode 'log-watched
            trakt-sync--resolved 0
            trakt-sync--skipped 0
            trakt-sync--selected 0)
      (let ((entry `((org_title . ,query)
                     (watched_date . nil)
                     (candidates . ,results))))
        (setq trakt-sync--current entry
              trakt-sync--unmatched (list entry))
        (trakt-sync--render entry results 1 1)))))

;;; --- Entry point ---

;;;###autoload
(defun trakt-sync ()
  "Sync movies-watched.org to Trakt interactively."
  (interactive)
  (setq trakt-sync--mode 'history)
  (message "Fetching candidates from Trakt...")
  (let ((data (trakt-sync--run-python
               "candidates"
               (shell-quote-argument trakt-sync-org-file))))
    (unless data
      (user-error "Failed to get candidates — check *Messages*"))
    (setq trakt-sync--entries data
          trakt-sync--resolved 0
          trakt-sync--skipped 0
          trakt-sync--selected 0)

    (let ((auto (seq-filter (lambda (e) (equal (alist-get 'status e) "auto")) data))
          (synced (seq-filter (lambda (e) (equal (alist-get 'status e) "synced")) data))
          (mapped (seq-filter (lambda (e) (equal (alist-get 'status e) "mapped")) data))
          (unmatched (seq-filter (lambda (e) (equal (alist-get 'status e) "unmatched")) data)))

      (message "%d auto-matched, %d mapped, %d synced, %d need review"
               (length auto) (length mapped) (length synced) (length unmatched))

      (setq trakt-sync--unmatched unmatched)
      (if unmatched
          (let ((entry (car unmatched)))
            (setq trakt-sync--current entry)
            (trakt-sync--render entry (alist-get 'candidates entry)
                                (length unmatched) 1))
        (trakt-sync--show-done)))))

;;;###autoload
(defun trakt-sync-watchlist ()
  "Sync movies-to-watch.org to Trakt watchlist interactively."
  (interactive)
  (setq trakt-sync--mode 'watchlist)
  (message "Fetching watchlist candidates from Trakt...")
  (let ((data (trakt-sync--run-python
               "watchlist-candidates"
               (shell-quote-argument trakt-sync-watchlist-org-file))))
    (unless data
      (setq trakt-sync--mode 'history)
      (user-error "Failed to get candidates — check *Messages*"))
    (setq trakt-sync--entries data
          trakt-sync--resolved 0
          trakt-sync--skipped 0
          trakt-sync--selected 0)

    (let ((auto (seq-filter (lambda (e) (equal (alist-get 'status e) "auto")) data))
          (synced (seq-filter (lambda (e) (equal (alist-get 'status e) "synced")) data))
          (mapped (seq-filter (lambda (e) (equal (alist-get 'status e) "mapped")) data))
          (unmatched (seq-filter (lambda (e) (equal (alist-get 'status e) "unmatched")) data)))

      (message "%d auto-matched, %d mapped, %d synced, %d need review"
               (length auto) (length mapped) (length synced) (length unmatched))

      (setq trakt-sync--unmatched unmatched)
      (if unmatched
          (let ((entry (car unmatched)))
            (setq trakt-sync--current entry)
            (trakt-sync--render entry (alist-get 'candidates entry)
                                (length unmatched) 1))
        (trakt-sync--show-done)))))

;;; --- View commands ---

(defun trakt-sync-view-watchlist ()
  "Open movies-to-watch.org."
  (interactive)
  (find-file trakt-sync-watchlist-org-file))

(defun trakt-sync-view-history ()
  "Open movies-watched.org."
  (interactive)
  (find-file trakt-sync-org-file))

;;; --- Unmapped commands ---

(defun trakt-sync-show-unmapped (type)
  "Show unmapped titles for TYPE (`watchlist' or `history')."
  (let* ((cmd (if (eq type 'watchlist) "watchlist-unmapped" "history-unmapped"))
         (label (if (eq type 'watchlist) "Watchlist" "History"))
         (titles (trakt-sync--run-python cmd)))
    (if (or (null titles) (= (length titles) 0))
        (message "%s: all titles are mapped!" label)
      (with-current-buffer (get-buffer-create "*trakt-unmapped*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (format " %s — Unmapped Titles (%d)\n" label (length titles))
                              'face 'trakt-sync-header))
          (insert " " (propertize (make-string 50 ?─) 'face 'trakt-sync-separator) "\n\n")
          (dolist (title titles)
            (insert "  • " (if (stringp title) title "?") "\n"))
          (insert "\n")
          (special-mode)
          (goto-char (point-min)))
        (pop-to-buffer "*trakt-unmapped*")))))

(defun trakt-sync-unmapped-watchlist ()
  "Show watchlist titles with no mapping."
  (interactive)
  (trakt-sync-show-unmapped 'watchlist))

(defun trakt-sync-unmapped-history ()
  "Show history titles with no mapping."
  (interactive)
  (trakt-sync-show-unmapped 'history))

;;; --- Transient menu ---

;;;###autoload
(transient-define-prefix movies ()
  "Movies — Trakt sync menu."
  ["Log"
   ("l"   "Log watched"     log-watched)]
  ["Sync"
   ("sw"  "Sync watchlist"  trakt-sync-watchlist)
   ("sh"  "Sync history"    trakt-sync)]
  ["View"
   ("vw"  "View watchlist"  trakt-sync-view-watchlist)
   ("vh"  "View history"    trakt-sync-view-history)]
  ["Unmapped"
   ("uw"  "Unmapped watchlist" trakt-sync-unmapped-watchlist)
   ("uh"  "Unmapped history"   trakt-sync-unmapped-history)]
  ["Other"
   ("C"   "Commit mapped"   trakt-sync-commit)
   ("t"   "Test UI"         trakt-sync-test-ui)
   ("o"   "Open Trakt.tv"   trakt-sync-open-trakt)])

(provide 'trakt-sync)
;;; trakt-sync.el ends here
