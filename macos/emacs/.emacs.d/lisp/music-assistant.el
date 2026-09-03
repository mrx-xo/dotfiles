;;; music-assistant.el --- Native Music Assistant dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A native Emacs control surface for Music Assistant.

;;; Code:

(require 'cl-lib)
(require 'music-assistant-client)
(require 'savehist)
(require 'seq)
(require 'subr-x)

(defgroup music-assistant nil
  "Control Music Assistant from Emacs."
  :group 'multimedia)

(defcustom music-assistant-server-url "http://192.168.1.143:8095"
  "Base URL of the Music Assistant server."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-default-player-name "MrX.local"
  "Player selected when no remembered player is available."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-keychain-service "music-assistant-token"
  "macOS Keychain service containing the API token."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-request-timeout 10
  "Seconds before a Music Assistant request fails."
  :type 'number
  :group 'music-assistant)

(defcustom music-assistant-artwork-size 256
  "Square Music Assistant artwork size in pixels."
  :type 'integer
  :group 'music-assistant)

(defvar music-assistant-last-player-id nil
  "Last player explicitly selected in the dashboard.")

(defface music-assistant-title-face
  '((t :inherit variable-pitch :height 1.4 :weight bold))
  "Face for the dashboard title and current track."
  :group 'music-assistant)

(defface music-assistant-metadata-face
  '((t :inherit font-lock-doc-face))
  "Face for track, album, player, and time metadata."
  :group 'music-assistant)

(defface music-assistant-progress-fill-face
  '((t :inherit success :weight bold))
  "Face for the completed part of the progress bar."
  :group 'music-assistant)

(defface music-assistant-progress-empty-face
  '((t :inherit shadow))
  "Face for the remaining part of the progress bar."
  :group 'music-assistant)

(defface music-assistant-current-item-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the queue item Music Assistant is currently playing."
  :group 'music-assistant)

(defface music-assistant-selection-face
  '((t :inherit highlight :extend t))
  "Face for the queue item selected with the keyboard."
  :group 'music-assistant)

(defface music-assistant-stale-face
  '((t :inherit shadow))
  "Face for stale state retained while disconnected."
  :group 'music-assistant)

(defface music-assistant-error-face
  '((t :inherit error :weight bold))
  "Face for user-facing Music Assistant errors."
  :group 'music-assistant)

(defface music-assistant-key-hint-face
  '((t :inherit help-key-binding))
  "Face for compact dashboard key hints."
  :group 'music-assistant)

(defvar music-assistant--schedule-function #'run-at-time
  "Function used to schedule dashboard work on the Emacs event loop.")

(defvar-local music-assistant--client nil
  "Protocol client owned by the current dashboard buffer.")

(defvar-local music-assistant--selected-queue-item-id nil
  "Stable queue item ID selected in the current dashboard.")

(defvar-local music-assistant--searching-p nil
  "Non-nil while the current dashboard has a search in flight.")

(defvar-local music-assistant--notice nil
  "Transient user-facing notice for the current dashboard.")

(defvar music-assistant-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'music-assistant-play-pause)
    (define-key map (kbd "p") #'music-assistant-previous)
    (define-key map (kbd "n") #'music-assistant-next)
    (define-key map (kbd "h") #'music-assistant-seek-backward)
    (define-key map (kbd "l") #'music-assistant-seek-forward)
    (define-key map (kbd "-") #'music-assistant-volume-down)
    (define-key map (kbd "+") #'music-assistant-volume-up)
    (define-key map (kbd "=") #'music-assistant-volume-up)
    (define-key map (kbd "j") #'music-assistant-queue-next)
    (define-key map (kbd "k") #'music-assistant-queue-previous)
    (define-key map (kbd "RET") #'music-assistant-play-selected)
    (define-key map (kbd "s") #'music-assistant-search)
    (define-key map (kbd "P") #'music-assistant-choose-player)
    (define-key map (kbd "g") #'music-assistant-refresh)
    (define-key map (kbd "?") #'describe-mode)
    (define-key map (kbd "q") #'music-assistant-quit)
    map)
  "Keymap for `music-assistant-mode'.")

(define-derived-mode music-assistant-mode special-mode "Music Assistant"
  "Major mode for the Music Assistant dashboard.

\{music-assistant-mode-map}"
  (setq-local mode-line-format nil
              truncate-lines t))

(defun music-assistant--require-client ()
  "Return the current dashboard client or signal a user error."
  (or music-assistant--client
      (user-error "This buffer has no Music Assistant client")))

(defun music-assistant--item-id (item)
  "Return stable queue item ID from ITEM."
  (alist-get 'queue_item_id item))

(defun music-assistant--item-media (item)
  "Return ITEM's media object, falling back to ITEM itself."
  (let ((media (alist-get 'media_item item)))
    (if (listp media) media item)))

(defun music-assistant--item-title (item)
  "Return a display title for queue ITEM."
  (let ((media (music-assistant--item-media item)))
    (or (alist-get 'name media)
        (alist-get 'name item)
        "Unknown track")))

(defun music-assistant--artist-names (media)
  "Return joined artist names from MEDIA."
  (let ((artists (alist-get 'artists media)))
    (string-join
     (delq nil
           (mapcar
            (lambda (artist)
              (cond
               ((stringp artist) artist)
               ((listp artist) (alist-get 'name artist))))
            (if (vectorp artists)
                (append artists nil)
              artists)))
     ", ")))

(defun music-assistant--album-name (media)
  "Return MEDIA's album name, or an empty string."
  (let ((album (alist-get 'album media)))
    (cond
     ((stringp album) album)
     ((listp album) (or (alist-get 'name album) ""))
     (t ""))))

(defun music-assistant--album-year (media)
  "Return MEDIA's album or release year, if present."
  (let ((album (alist-get 'album media)))
    (or (and (listp album) (alist-get 'year album))
        (alist-get 'year media))))

(defun music-assistant--provider-name (media)
  "Return a concise provider name for MEDIA."
  (or (alist-get 'provider media)
      (when-let* ((mappings (alist-get 'provider_mappings media))
                  (first (if (vectorp mappings)
                             (aref mappings 0)
                           (car mappings))))
        (or (alist-get 'provider_instance first)
            (alist-get 'provider_domain first)))
      ""))

(defun music-assistant--format-time (seconds)
  "Format SECONDS as MM:SS, or H:MM:SS for long media."
  (let* ((total (truncate (max 0 (or seconds 0))))
         (hours (/ total 3600))
         (minutes (/ (% total 3600) 60))
         (remaining (% total 60)))
    (if (> hours 0)
        (format "%d:%02d:%02d" hours minutes remaining)
      (format "%02d:%02d" minutes remaining))))

(defun music-assistant--progress-bar (elapsed duration)
  "Return a fixed-width progress bar for ELAPSED and DURATION."
  (let* ((width 28)
         (ratio (if (and (numberp duration) (> duration 0))
                    (min 1.0 (max 0.0 (/ (float elapsed) duration)))
                  0.0))
         (filled (round (* width ratio))))
    (concat
     (propertize (make-string filled ?━)
                 'face 'music-assistant-progress-fill-face)
     (propertize (make-string (- width filled) ?─)
                 'face 'music-assistant-progress-empty-face))))

(defun music-assistant--queue-item-by-id (client item-id)
  "Return ITEM-ID from CLIENT's loaded queue items."
  (seq-find
   (lambda (item)
     (equal (music-assistant--item-id item) item-id))
   (music-assistant-client-queue-items client)))

(defun music-assistant--normalize-selection (client)
  "Preserve or repair the queue selection for CLIENT."
  (let* ((items (music-assistant-client-queue-items client))
         (current-id
          (music-assistant--item-id
           (music-assistant-client-current-item client)))
         (selected
          (music-assistant--queue-item-by-id
           client music-assistant--selected-queue-item-id)))
    (setq music-assistant--selected-queue-item-id
          (cond
           (selected music-assistant--selected-queue-item-id)
           ((music-assistant--queue-item-by-id client current-id)
            current-id)
           (items (music-assistant--item-id (car items)))
           (t nil)))))

(defun music-assistant--state-label (client)
  "Return the concise header state for CLIENT."
  (if music-assistant--searching-p
      "searching..."
    (symbol-name (music-assistant-client-state client))))

(defun music-assistant--set-header (client)
  "Set the current buffer's header from CLIENT."
  (let ((player (music-assistant-client-selected-player client)))
    (setq header-line-format
          (propertize
           (concat
            " Music Assistant · "
            (music-assistant--state-label client)
            (when player
              (format " · %s" (alist-get 'name player))))
           'face 'music-assistant-metadata-face))))

(defun music-assistant--insert-state (client)
  "Insert a user-facing non-ready state for CLIENT."
  (let ((details (music-assistant-client-last-error client)))
    (pcase (music-assistant-client-state client)
      ('connecting
       (insert "Connecting to Music Assistant…\n"))
      ('authenticating
       (insert "Authenticating with Music Assistant…\n"))
      ('auth-required
       (insert
        (propertize "Authentication required\n"
                    'face 'music-assistant-error-face)
        (format
         "Add a token to macOS Keychain service `%s`, then press g.\n"
         music-assistant-keychain-service)
        (when details (format "%s\n" details))))
      ('reconnecting
       (insert
        (propertize "Reconnecting to Music Assistant…\n"
                    'face 'music-assistant-stale-face)
        (when details (format "%s\n" details))))
      ('error
       (insert
        (propertize (format "%s\n" (or details "Music Assistant error"))
                    'face 'music-assistant-error-face)
        "Press g to retry.\n"))
      ('disconnected
       (insert "Disconnected. Press g to connect.\n"))
      (_
       (insert (format "Music Assistant state: %s\n"
                       (music-assistant-client-state client)))))))

(defun music-assistant--queue-row (item current-id selected-id)
  "Return a propertized row for ITEM and selection IDs."
  (let* ((item-id (music-assistant--item-id item))
         (media (music-assistant--item-media item))
         (artists (music-assistant--artist-names media))
         (duration (alist-get 'duration item))
         (faces
          (delq nil
                (list
                 (and (equal item-id current-id)
                      'music-assistant-current-item-face)
                 (and (equal item-id selected-id)
                      'music-assistant-selection-face))))
         (row
          (format " %s %-36s %-24s %7s\n"
                  (if (equal item-id selected-id) "›" " ")
                  (music-assistant--item-title item)
                  artists
                  (music-assistant--format-time duration))))
    (propertize row
                'music-assistant-queue-item-id item-id
                'face faces
                'mouse-face 'highlight)))

(defun music-assistant--insert-ready (client)
  "Insert CLIENT's ready dashboard state."
  (let ((player (music-assistant-client-selected-player client)))
    (if (not player)
        (insert
         (propertize "No available player\n"
                     'face 'music-assistant-error-face)
         "Press P after a player becomes available.\n")
      (insert
       (propertize (format "%s\n" (alist-get 'name player))
                   'face 'music-assistant-metadata-face))
      (let ((queue (music-assistant-client-selected-queue client)))
        (if (not queue)
            (insert
             (propertize "No active queue\n"
                         'face 'music-assistant-error-face)
             "Start playback on this player or press g to refresh.\n")
          (music-assistant--normalize-selection client)
          (let* ((current
                  (music-assistant-client-current-item client))
                 (media (music-assistant--item-media current))
                 (title (music-assistant--item-title current))
                 (artists (music-assistant--artist-names media))
                 (album (music-assistant--album-name media))
                 (year (music-assistant--album-year media))
                 (duration
                  (or (alist-get 'duration current)
                      (alist-get 'duration media)
                      0))
                 (elapsed
                  (music-assistant-client-current-elapsed client))
                 (state (or (alist-get 'state queue) "idle"))
                 (volume (or (alist-get 'volume_level player) 0))
                 (current-id (music-assistant--item-id current)))
            (insert "\n[no artwork]\n\n")
            (insert (propertize (concat title "\n")
                                'face 'music-assistant-title-face))
            (unless (string-empty-p artists)
              (insert
               (propertize (concat artists "\n")
                           'face 'music-assistant-metadata-face)))
            (unless (string-empty-p album)
              (insert
               (propertize
                (format "%s%s\n" album
                        (if year (format " · %s" year) ""))
                'face 'music-assistant-metadata-face)))
            (insert
             (format "\n%s / %s  %s  %s  Volume %d%%\n"
                     (music-assistant--format-time elapsed)
                     (music-assistant--format-time duration)
                     (music-assistant--progress-bar elapsed duration)
                     state volume))
            (insert
             (propertize
              "p previous  SPC play/pause  n next  h/l seek  -/+ volume\n"
              'face 'music-assistant-key-hint-face))
            (insert "\n"
                    (propertize "Queue\n"
                                'face 'music-assistant-title-face))
            (if-let ((items
                      (music-assistant-client-queue-items client)))
                (dolist (item items)
                  (insert
                   (music-assistant--queue-row
                    item current-id
                    music-assistant--selected-queue-item-id)))
              (insert
               (propertize " Queue is empty\n"
                           'face 'music-assistant-stale-face))))))))
  (when music-assistant--notice
    (insert "\n"
            (propertize music-assistant--notice
                        'face 'music-assistant-metadata-face)
            "\n"))
  (insert
   "\n"
   (propertize
    "j/k queue  RET play  s search  P player  g refresh  ? help  q quit\n"
    'face 'music-assistant-key-hint-face)))

(defun music-assistant--render ()
  "Render the current dashboard without disturbing other windows."
  (when music-assistant--client
    (let ((inhibit-read-only t)
          (old-point (point)))
      (save-window-excursion
        (erase-buffer)
        (music-assistant--set-header music-assistant--client)
        (insert (propertize "Music Assistant\n\n"
                            'face 'music-assistant-title-face))
        (if (eq (music-assistant-client-state music-assistant--client)
                'ready)
            (music-assistant--insert-ready music-assistant--client)
          (music-assistant--insert-state music-assistant--client))
        (goto-char (min old-point (point-max)))))))

(defun music-assistant--owns-client-p (buffer client)
  "Return non-nil when live BUFFER still owns CLIENT."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (eq music-assistant--client client))))

(defun music-assistant--render-if-current (buffer client)
  "Render BUFFER if it still owns CLIENT."
  (when (music-assistant--owns-client-p buffer client)
    (with-current-buffer buffer
      (music-assistant--render))))

(defun music-assistant--client-changed (buffer client)
  "Schedule a render of BUFFER after CLIENT changes."
  (apply music-assistant--schedule-function
         0 #'music-assistant--render-if-current
         (list buffer client)))

(defun music-assistant--make-client (buffer)
  "Create the protocol client owned by BUFFER."
  (let ((service music-assistant-keychain-service))
    (music-assistant-client-create
     :server-url music-assistant-server-url
     :token-provider
     (lambda (success error-callback)
       (music-assistant-client--read-keychain-token
        service success error-callback))
     :on-state-change
     (apply-partially #'music-assistant--client-changed buffer)
     :request-timeout music-assistant-request-timeout
     :default-player-name music-assistant-default-player-name)))

(defun music-assistant--queue-ids (client)
  "Return stable queue item IDs loaded by CLIENT."
  (delq nil
        (mapcar #'music-assistant--item-id
                (music-assistant-client-queue-items client))))

(defun music-assistant--move-queue-selection (delta)
  "Move the queue selection by DELTA rows without wrapping."
  (let* ((client (music-assistant--require-client))
         (_normalized (music-assistant--normalize-selection client))
         (ids (music-assistant--queue-ids client)))
    (unless ids
      (user-error "The Music Assistant queue is empty"))
    (let* ((index
            (or (seq-position
                 ids music-assistant--selected-queue-item-id
                 #'equal)
                0))
           (target (max 0 (min (1- (length ids)) (+ index delta)))))
      (setq music-assistant--selected-queue-item-id (nth target ids))
      (music-assistant--render))))

(defun music-assistant-queue-next ()
  "Select the next queue item without wrapping."
  (interactive)
  (music-assistant--move-queue-selection 1))

(defun music-assistant-queue-previous ()
  "Select the previous queue item without wrapping."
  (interactive)
  (music-assistant--move-queue-selection -1))

(defun music-assistant-play-selected ()
  "Play the queue item selected in the dashboard."
  (interactive)
  (let ((client (music-assistant--require-client)))
    (music-assistant--normalize-selection client)
    (unless music-assistant--selected-queue-item-id
      (user-error "The Music Assistant queue is empty"))
    (music-assistant-client-play-index
     client music-assistant--selected-queue-item-id)))

(defun music-assistant--search-label (track)
  "Return a completion label for TRACK."
  (let* ((title (or (alist-get 'name track) "Unknown track"))
         (artists (music-assistant--artist-names track))
         (album (music-assistant--album-name track))
         (provider (music-assistant--provider-name track)))
    (format "%s — %s — %s%s"
            title
            (if (string-empty-p artists) "Unknown artist" artists)
            (if (string-empty-p album) "Unknown album" album)
            (if (string-empty-p provider)
                ""
              (format " [%s]" provider)))))

(defun music-assistant--present-search-results
    (buffer client tracks)
  "Present TRACKS if BUFFER still owns CLIENT."
  (when (music-assistant--owns-client-p buffer client)
    (with-current-buffer buffer
      (setq music-assistant--searching-p nil)
      (music-assistant--render)
      (if (null tracks)
          (message "No tracks found")
        (let* ((candidates
                (mapcar
                 (lambda (track)
                   (cons (music-assistant--search-label track) track))
                 tracks))
               (choice
                (completing-read "Play track: " candidates nil t))
               (track (cdr (assoc choice candidates)))
               (uri (alist-get 'uri track)))
          (when (and uri
                     (music-assistant--owns-client-p buffer client))
            (music-assistant-client-play-media client uri)))))))

(defun music-assistant--search-succeeded (buffer client tracks)
  "Schedule presentation of TRACKS for BUFFER and CLIENT."
  (apply music-assistant--schedule-function
         0 #'music-assistant--present-search-results
         (list buffer client tracks)))

(defun music-assistant--present-search-error
    (buffer client error)
  "Render SEARCH ERROR if BUFFER still owns CLIENT."
  (when (music-assistant--owns-client-p buffer client)
    (with-current-buffer buffer
      (setq music-assistant--searching-p nil
            music-assistant--notice
            (or (plist-get error :details) "Search failed"))
      (music-assistant--render)
      (message "%s" music-assistant--notice))))

(defun music-assistant--search-failed (buffer client error)
  "Schedule SEARCH ERROR display for BUFFER and CLIENT."
  (apply music-assistant--schedule-function
         0 #'music-assistant--present-search-error
         (list buffer client error)))

(defun music-assistant-search ()
  "Search Music Assistant for a track and play the chosen result."
  (interactive)
  (let* ((client (music-assistant--require-client))
         (query (string-trim (read-string "Search tracks: ")))
         (buffer (current-buffer)))
    (when (string-empty-p query)
      (user-error "Music Assistant search cannot be empty"))
    (setq music-assistant--searching-p t
          music-assistant--notice nil)
    (music-assistant--render)
    (condition-case failure
        (music-assistant-client-search-tracks
         client query
         (apply-partially
          #'music-assistant--search-succeeded buffer client)
         (apply-partially
          #'music-assistant--search-failed buffer client))
      (error
       (setq music-assistant--searching-p nil)
       (music-assistant--render)
       (signal (car failure) (cdr failure))))))

(defun music-assistant--player-label (player)
  "Return a completion label for PLAYER."
  (let ((provider (alist-get 'provider player)))
    (format "%s%s"
            (or (alist-get 'name player) "Unnamed player")
            (if provider (format " [%s]" provider) ""))))

(defun music-assistant-choose-player ()
  "Choose an available Music Assistant player and remember it."
  (interactive)
  (let* ((client (music-assistant--require-client))
         (players
          (seq-filter
           #'music-assistant-client--available-player-p
           (music-assistant-client-players client)))
         (candidates
          (mapcar
           (lambda (player)
             (cons (music-assistant--player-label player) player))
           players)))
    (unless candidates
      (user-error "No Music Assistant players are available"))
    (let* ((choice
            (completing-read "Player: " candidates nil t))
           (player (cdr (assoc choice candidates)))
           (player-id (alist-get 'player_id player)))
      (music-assistant-client-select-player client player-id)
      (setq music-assistant-last-player-id player-id)
      (savehist-save))))

(defun music-assistant-play-pause ()
  "Toggle playback for the selected queue."
  (interactive)
  (music-assistant-client-play-pause
   (music-assistant--require-client)))

(defun music-assistant-previous ()
  "Play the previous item in the selected queue."
  (interactive)
  (music-assistant-client-previous
   (music-assistant--require-client)))

(defun music-assistant-next ()
  "Play the next item in the selected queue."
  (interactive)
  (music-assistant-client-next
   (music-assistant--require-client)))

(defun music-assistant-seek-backward ()
  "Seek backward ten seconds."
  (interactive)
  (music-assistant-client-seek-relative
   (music-assistant--require-client) -10))

(defun music-assistant-seek-forward ()
  "Seek forward ten seconds."
  (interactive)
  (music-assistant-client-seek-relative
   (music-assistant--require-client) 10))

(defun music-assistant--change-volume (delta)
  "Change the selected player volume by DELTA."
  (let* ((client (music-assistant--require-client))
         (player (music-assistant-client-selected-player client))
         (level (alist-get 'volume_level player)))
    (unless (numberp level)
      (user-error "The selected player has no volume control"))
    (music-assistant-client-set-volume client (+ level delta))))

(defun music-assistant-volume-down ()
  "Lower the selected player volume by five points."
  (interactive)
  (music-assistant--change-volume -5))

(defun music-assistant-volume-up ()
  "Raise the selected player volume by five points."
  (interactive)
  (music-assistant--change-volume 5))

(defun music-assistant-refresh ()
  "Refresh authoritative state or reconnect immediately."
  (interactive)
  (music-assistant-client-refresh
   (music-assistant--require-client)))

(defun music-assistant-quit ()
  "Bury the Music Assistant dashboard window."
  (interactive)
  (quit-window))

;;;###autoload
(defun music-assistant ()
  "Open the native Music Assistant dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*Music Assistant*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'music-assistant-mode)
        (music-assistant-mode))
      (if music-assistant--client
          (when (memq (music-assistant-client-state
                       music-assistant--client)
                      '(disconnected error))
            (music-assistant-client-retry music-assistant--client))
        (setq music-assistant--client
              (music-assistant--make-client buffer))
        (setf
         (music-assistant-client-selected-player-id
          music-assistant--client)
         music-assistant-last-player-id)
        (music-assistant--render)
        (music-assistant-client-connect music-assistant--client)))
    (pop-to-buffer buffer)
    buffer))

(provide 'music-assistant)

;;; music-assistant.el ends here
