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
(require 'url)
(require 'url-http)
(require 'url-util)

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

(defvar music-assistant--schedule-function
  #'music-assistant-client--default-schedule
  "Function used to schedule dashboard work on the Emacs event loop.")

(defvar music-assistant--cancel-function #'cancel-timer
  "Function used to cancel dashboard timers.")

(defvar music-assistant--url-retrieve-function #'url-retrieve
  "Function used to retrieve artwork asynchronously.")

(defvar music-assistant--create-image-function #'create-image
  "Function used to create an Emacs image from downloaded data.")

(defvar music-assistant--artwork-cache
  (make-hash-table :test #'equal)
  "Artwork cache keyed by requested and final URL.")

(defvar-local music-assistant--client nil
  "Protocol client owned by the current dashboard buffer.")

(defvar-local music-assistant--selected-queue-item-id nil
  "Stable queue item ID selected in the current dashboard.")

(defvar-local music-assistant--searching-p nil
  "Non-nil while the current dashboard has a search in flight.")

(defvar-local music-assistant--notice nil
  "Transient user-facing notice for the current dashboard.")

(defvar-local music-assistant--progress-start nil
  "Marker at the beginning of the in-place progress region.")

(defvar-local music-assistant--progress-end nil
  "Marker at the end of the in-place progress region.")

(defvar-local music-assistant--progress-timer nil
  "One-shot timer responsible for the next progress update.")

(defvar-local music-assistant--artwork-image nil
  "Image object for the current queue item, when available.")

(defvar-local music-assistant--artwork-item-id nil
  "Queue item ID associated with `music-assistant--artwork-image'.")

(defvar-local music-assistant--artwork-url nil
  "Artwork URL associated with the current queue item.")

(defvar-local music-assistant--artwork-requests nil
  "Hash table of in-flight artwork requests in this dashboard.")

(defvar-local music-assistant--artwork-response-buffers nil
  "Live URL response buffers owned by this dashboard.")

(defvar-local music-assistant--cleaned-p nil
  "Non-nil after the current dashboard session has been torn down.")

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
              truncate-lines t
              music-assistant--cleaned-p nil
              music-assistant--progress-timer nil
              music-assistant--progress-start nil
              music-assistant--progress-end nil
              music-assistant--artwork-image nil
              music-assistant--artwork-item-id nil
              music-assistant--artwork-url nil
              music-assistant--artwork-requests
              (make-hash-table :test #'equal)
              music-assistant--artwork-response-buffers nil)
  (add-hook 'kill-buffer-hook #'music-assistant--cleanup nil t))

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

(defun music-assistant--progress-text (client)
  "Return the replaceable progress text for CLIENT."
  (let* ((queue (music-assistant-client-selected-queue client))
         (current (music-assistant-client-current-item client))
         (player (music-assistant-client-selected-player client))
         (duration
          (or (alist-get 'duration current)
              (alist-get 'duration
                         (music-assistant--item-media current))
              0))
         (elapsed (music-assistant-client-current-elapsed client))
         (state (or (alist-get 'state queue) "idle"))
         (volume (or (alist-get 'volume_level player) 0)))
    (format "\n%s / %s  %s  %s  Volume %d%%\n"
            (music-assistant--format-time elapsed)
            (music-assistant--format-time duration)
            (music-assistant--progress-bar elapsed duration)
            state volume)))

(defun music-assistant--proxy-id-from-image (image)
  "Return a non-empty proxy ID from IMAGE, if it has one."
  (when (listp image)
    (let ((proxy-id (alist-get 'proxy_id image)))
      (and (stringp proxy-id)
           (not (string-empty-p proxy-id))
           proxy-id))))

(defun music-assistant--artwork-proxy-id (item)
  "Return the preferred artwork proxy ID for queue ITEM."
  (or
   (music-assistant--proxy-id-from-image
    (alist-get 'image item))
   (let* ((media (music-assistant--item-media item))
          (metadata (alist-get 'metadata media))
          (images (alist-get 'images metadata)))
     (seq-some
      #'music-assistant--proxy-id-from-image
      (if (vectorp images) (append images nil) images)))))

(defun music-assistant--artwork-url (client item)
  "Return CLIENT's schema-31 artwork proxy URL for ITEM."
  (when-let ((proxy-id
              (music-assistant--artwork-proxy-id item)))
    (format "%s/imageproxy/%s?size=%d"
            (replace-regexp-in-string
             "/+\\'" ""
             (music-assistant-client-server-url client))
            (url-hexify-string proxy-id)
            music-assistant-artwork-size)))

(defun music-assistant--artwork-cache-entry (url)
  "Return a live cache entry for URL, expiring old failures."
  (let ((entry (and url
                    (gethash url music-assistant--artwork-cache))))
    (if (and entry
             (plist-member entry :failed-at)
             (>= (- (float-time) (plist-get entry :failed-at)) 30))
        (progn
          (remhash url music-assistant--artwork-cache)
          nil)
      entry)))

(defun music-assistant--response-final-url (fallback)
  "Return the current URL response's final URL or FALLBACK."
  (or (and (boundp 'url-current-object)
           url-current-object
           (ignore-errors (url-recreate-url url-current-object)))
      fallback))

(defun music-assistant--cache-artwork-failure (url)
  "Store a short-lived failure marker for URL."
  (puthash url (list :failed-at (float-time))
           music-assistant--artwork-cache))

(defun music-assistant--forget-artwork-response
    (dashboard requested-url response)
  "Forget RESPONSE for REQUESTED-URL in DASHBOARD."
  (when (buffer-live-p dashboard)
    (with-current-buffer dashboard
      (setq music-assistant--artwork-response-buffers
            (delq response
                  music-assistant--artwork-response-buffers))
      (when (hash-table-p music-assistant--artwork-requests)
        (remhash requested-url music-assistant--artwork-requests)))))

(defun music-assistant--artwork-response
    (status dashboard client item-id requested-url)
  "Handle an artwork response STATUS for DASHBOARD and CLIENT."
  (let ((response (current-buffer))
        image)
    (music-assistant--forget-artwork-response
     dashboard requested-url response)
    (unwind-protect
        (condition-case _failure
            (if (plist-get status :error)
                (music-assistant--cache-artwork-failure requested-url)
              (let* ((header-end
                      (and (boundp 'url-http-end-of-headers)
                           url-http-end-of-headers))
                     (data-start
                      (cond
                       ((markerp header-end)
                        (1+ (marker-position header-end)))
                       ((integerp header-end) (1+ header-end))))
                     (final-url
                      (music-assistant--response-final-url
                       requested-url)))
                (unless (and data-start
                             (<= data-start (point-max)))
                  (error "Artwork response has no body"))
                (let* ((data
                        (buffer-substring-no-properties
                         data-start (point-max)))
                       (created
                        (funcall music-assistant--create-image-function
                                 data nil t
                                 :max-width music-assistant-artwork-size
                                 :max-height
                                 music-assistant-artwork-size))
                       (entry (list :image created)))
                  (unless created
                    (error "Artwork decoder returned no image"))
                  (setq image created)
                  (puthash final-url entry
                           music-assistant--artwork-cache)
                  (puthash requested-url entry
                           music-assistant--artwork-cache))))
          (error
           (music-assistant--cache-artwork-failure requested-url)))
      (when (buffer-live-p response)
        (kill-buffer response)))
    (when (and image
               (music-assistant--owns-client-p dashboard client))
      (with-current-buffer dashboard
        (when (equal
               item-id
               (music-assistant--item-id
                (music-assistant-client-current-item client)))
          (setq music-assistant--artwork-image image
                music-assistant--artwork-item-id item-id)
          (apply music-assistant--schedule-function
                 0 #'music-assistant--render-if-current
                 (list dashboard client)))))))

(defun music-assistant--request-artwork
    (client item-id url)
  "Start an asynchronous artwork request for CLIENT ITEM-ID at URL."
  (unless (gethash url music-assistant--artwork-requests)
    (puthash url 'starting music-assistant--artwork-requests)
    (condition-case _failure
        (let ((response
               (funcall
                music-assistant--url-retrieve-function
                url #'music-assistant--artwork-response
                (list (current-buffer) client item-id url)
                t t)))
          (if (buffer-live-p response)
              (progn
                (puthash url response
                         music-assistant--artwork-requests)
                (push response
                      music-assistant--artwork-response-buffers))
            (when (gethash url music-assistant--artwork-requests)
              (remhash url music-assistant--artwork-requests)
              (music-assistant--cache-artwork-failure url))))
      (error
       (remhash url music-assistant--artwork-requests)
       (music-assistant--cache-artwork-failure url)))))

(defun music-assistant--insert-artwork (client item)
  "Insert cached artwork or a safe placeholder for CLIENT ITEM."
  (let* ((item-id (music-assistant--item-id item))
         (url (music-assistant--artwork-url client item))
         (entry (music-assistant--artwork-cache-entry url))
         (image (plist-get entry :image))
         (failed (plist-member entry :failed-at)))
    (setq music-assistant--artwork-item-id item-id
          music-assistant--artwork-url url
          music-assistant--artwork-image image)
    (if image
        (insert (propertize " " 'display image) "\n")
      (insert "[no artwork]\n")
      (when (and url (not failed))
        (music-assistant--request-artwork client item-id url)))))

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
         music-assistant-keychain-service))
       (when details
         (insert (format "%s\n" details))))
      ('reconnecting
       (insert
        (propertize "Reconnecting to Music Assistant…\n"
                    'face 'music-assistant-stale-face))
       (when details
         (insert (format "%s\n" details))))
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
                 (current-id (music-assistant--item-id current)))
            (insert "\n")
            (music-assistant--insert-artwork client current)
            (insert "\n")
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
            (setq music-assistant--progress-start
                  (copy-marker (point)))
            (insert (music-assistant--progress-text client))
            (setq music-assistant--progress-end
                  (copy-marker (point)))
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

(defun music-assistant--playing-p (client)
  "Return non-nil when CLIENT has a ready, playing queue."
  (and (eq (music-assistant-client-state client) 'ready)
       (equal
        (alist-get 'state
                   (music-assistant-client-selected-queue client))
        "playing")))

(defun music-assistant--cancel-progress-timer ()
  "Cancel the current dashboard's pending progress timer."
  (when music-assistant--progress-timer
    (let ((timer music-assistant--progress-timer))
      (setq music-assistant--progress-timer nil)
      (condition-case nil
          (funcall music-assistant--cancel-function timer)
        (error nil)))))

(defun music-assistant--sync-progress-timer (client)
  "Start or stop the current buffer's progress timer for CLIENT."
  (if (and (not music-assistant--cleaned-p)
           (music-assistant--playing-p client))
      (unless music-assistant--progress-timer
        (setq music-assistant--progress-timer
              (apply music-assistant--schedule-function
                     1 #'music-assistant--progress-tick
                     (list (current-buffer) client))))
    (music-assistant--cancel-progress-timer)))

(defun music-assistant--progress-tick (buffer client)
  "Update BUFFER's progress for CLIENT and schedule the next tick."
  (when (music-assistant--owns-client-p buffer client)
    (with-current-buffer buffer
      (setq music-assistant--progress-timer nil)
      (music-assistant--update-progress buffer client)
      (music-assistant--sync-progress-timer client))))

(defun music-assistant--update-progress (buffer client)
  "Replace only BUFFER's elapsed/progress region for CLIENT."
  (when (music-assistant--owns-client-p buffer client)
    (with-current-buffer buffer
      (when (and (markerp music-assistant--progress-start)
                 (markerp music-assistant--progress-end)
                 (eq (marker-buffer music-assistant--progress-start)
                     buffer)
                 (eq (marker-buffer music-assistant--progress-end)
                     buffer))
        (let ((inhibit-read-only t)
              (start (marker-position
                      music-assistant--progress-start))
              (end (marker-position
                    music-assistant--progress-end)))
          (save-excursion
            (delete-region start end)
            (goto-char start)
            (insert (music-assistant--progress-text client))
            (set-marker music-assistant--progress-end
                        (point))))))))

(defun music-assistant--render ()
  "Render the current dashboard without disturbing other windows."
  (when music-assistant--client
    (let ((inhibit-read-only t)
          (old-point (point)))
      (save-window-excursion
        (when (markerp music-assistant--progress-start)
          (set-marker music-assistant--progress-start nil))
        (when (markerp music-assistant--progress-end)
          (set-marker music-assistant--progress-end nil))
        (setq music-assistant--progress-start nil
              music-assistant--progress-end nil)
        (erase-buffer)
        (music-assistant--set-header music-assistant--client)
        (insert (propertize "Music Assistant\n\n"
                            'face 'music-assistant-title-face))
        (if (eq (music-assistant-client-state music-assistant--client)
                'ready)
            (music-assistant--insert-ready music-assistant--client)
          (music-assistant--insert-state music-assistant--client))
        (goto-char (min old-point (point-max))))
      (music-assistant--sync-progress-timer
       music-assistant--client))))

(defun music-assistant--owns-client-p (buffer client)
  "Return non-nil when live BUFFER still owns CLIENT."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (not music-assistant--cleaned-p)
              (eq music-assistant--client client)))))

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

(defun music-assistant--reset-session-state ()
  "Reset buffer-local resources before creating a fresh client."
  (setq music-assistant--cleaned-p nil
        music-assistant--progress-timer nil
        music-assistant--progress-start nil
        music-assistant--progress-end nil
        music-assistant--artwork-image nil
        music-assistant--artwork-item-id nil
        music-assistant--artwork-url nil
        music-assistant--artwork-requests
        (make-hash-table :test #'equal)
        music-assistant--artwork-response-buffers nil
        music-assistant--selected-queue-item-id nil
        music-assistant--searching-p nil
        music-assistant--notice nil))

(defun music-assistant--cleanup ()
  "Idempotently release resources owned by the current dashboard."
  (unless music-assistant--cleaned-p
    (setq music-assistant--cleaned-p t)
    (music-assistant--cancel-progress-timer)
    (when (markerp music-assistant--progress-start)
      (set-marker music-assistant--progress-start nil))
    (when (markerp music-assistant--progress-end)
      (set-marker music-assistant--progress-end nil))
    (setq music-assistant--progress-start nil
          music-assistant--progress-end nil)
    (dolist (response music-assistant--artwork-response-buffers)
      (when (buffer-live-p response)
        (kill-buffer response)))
    (setq music-assistant--artwork-response-buffers nil)
    (when (hash-table-p music-assistant--artwork-requests)
      (maphash
       (lambda (_url response)
         (when (buffer-live-p response)
           (kill-buffer response)))
       music-assistant--artwork-requests)
      (clrhash music-assistant--artwork-requests))
    (when music-assistant--client
      (setf (music-assistant-client-on-state-change
             music-assistant--client)
            #'ignore)
      (music-assistant-client-close music-assistant--client))))

(defun music-assistant-show-log ()
  "Display sanitized log entries for the current dashboard client."
  (interactive)
  (let* ((client (music-assistant--require-client))
         (entries
          (reverse
           (copy-sequence
            (music-assistant-client-log-entries client))))
         (buffer (get-buffer-create "*Music Assistant Log*")))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Music Assistant Log\n\n")
        (dolist (entry entries)
          (insert entry "\n"))))
    (display-buffer buffer)
    buffer))

(defun music-assistant-quit ()
  "Close dashboard resources and bury its window."
  (interactive)
  (music-assistant--cleanup)
  (quit-window))

;;;###autoload
(defun music-assistant ()
  "Open the native Music Assistant dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*Music Assistant*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'music-assistant-mode)
        (music-assistant-mode))
      (if (and music-assistant--client
               (not music-assistant--cleaned-p))
          (when (memq (music-assistant-client-state
                       music-assistant--client)
                      '(disconnected error))
            (music-assistant-client-retry music-assistant--client))
        (music-assistant--reset-session-state)
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
