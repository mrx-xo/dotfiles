;;; lights.el --- VENGEANCE lights dashboard, the Emacs skin -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Keywords: hardware, convenience

;;; Commentary:

;; The Emacs sibling of lights-tui.py: a thin skin over `lightsctl' that
;; polls engine state, lists effects/presets with a live ● marker, and
;; sends the same controls.  The animated color swatch is rendered
;; locally at framerate by a persistent swatch-stream.py subprocess
;; (Emacs can't run the Python effect functions itself).
;;
;; M-x lights  (or the leader binding)
;;
;;   j / k      move between effects/presets (headers are skipped)
;;   gg / G     top / bottom (evil motion)
;;   TAB        jump between the effects and presets sections
;;   l / RET    apply the highlighted effect or preset
;;   w           wake VENGEANCE (Wake-on-LAN, when it's off)
;;   r           randomize        o  rotation on       p  pin ⇄ unpin
;;   a           back on schedule x  󰃢 reset
;;   R           restart engine   [ / ]  brightness
;;   ?          keybinds            q  quit
;;
;; Detail (effect description / preset pool) follows point — no hover
;; concept needed.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'text-property-search)

(defgroup lights nil
  "Emacs skin for the VENGEANCE lights."
  :group 'external)

(defcustom lights-ctl
  (expand-file-name "~/.dotfiles/macos/scripts/lights/lightsctl")
  "Path to the lightsctl driver script."
  :type 'file)

(defcustom lights-swatch-stream
  (expand-file-name "~/.dotfiles/macos/scripts/lights/swatch-stream.py")
  "Path to the swatch frame streamer."
  :type 'file)

(defcustom lights-python "python3"
  "Python used for the swatch streamer (only needs the stdlib)."
  :type 'string)

(defcustom lights-poll-seconds 2.0
  "How often to ask the engine for state."
  :type 'number)

(defcustom lights-swatch-fps 10
  "Frames per second for the animated swatch."
  :type 'integer)

(defface lights-active
  '((t :foreground "#50fa7b" :weight bold))
  "Face for the effect/preset actually playing on the box.")

(defface lights-group
  '((t :inherit shadow :weight bold))
  "Face for the dim group headers in the effects list.")

(defface lights-status
  '((t :inherit highlight :extend t))
  "Face for the status panel.")

(defface lights-key
  '((t :foreground "#8be9fd" :weight bold))
  "Face for key names in the ? overlay.")

;; --- state ---------------------------------------------------------------

(defconst lights--buffer "*lights*")
(defvar lights--catalog nil)     ; hash: effects/groups/presets/descriptions
(defvar lights--status nil)      ; alist, the "lights" object from state
(defvar lights--reachable t)
(defvar lights--wedged nil)
(defvar lights--engine-age nil)
(defvar lights--waking nil)
(defvar lights--brightness 1.0)
(defvar lights--poll-timer nil)
(defvar lights--polling nil)
(defvar lights--swatch-proc nil)
(defvar lights--swatch-text nil)
(defvar lights--swatch-overlay nil)
(defvar lights--swatch-acc "")
(defvar lights--detail-id 'unset)
(defvar lights--detail-beg nil)  ; markers around the detail section
(defvar lights--detail-end nil)

(defun lights--st (key &optional default)
  (let ((cell (assq key lights--status)))
    (if cell (cdr cell) default)))

(defun lights--on-p ()
  (lights--st 'on t))

;; --- subprocess plumbing -------------------------------------------------

(defun lights--run (callback &rest args)
  "Run lightsctl ARGS asynchronously; CALLBACK gets the output string."
  (let ((buf (generate-new-buffer " *lightsctl*")))
    (make-process
     :name "lightsctl" :buffer buf :noquery t
     :command (cons lights-ctl args)
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((out (with-current-buffer buf (buffer-string))))
                     (kill-buffer buf)
                     (when callback (funcall callback out))))))))

(defun lights--poll ()
  "Ask the engine for state (skips if a poll is already in flight)."
  (unless (or lights--polling (not (get-buffer lights--buffer)))
    (setq lights--polling t)
    (lights--run
     (lambda (out)
       (setq lights--polling nil)
       (lights--apply-state
        (condition-case nil
            (json-parse-string out :object-type 'alist
                               :null-object nil :false-object nil)
          (error nil))))
     "state" "--json")))

(defun lights--send (&rest args)
  "Send a control, then refresh state."
  (apply #'lights--run (lambda (_) (lights--poll)) args))

(defun lights--apply-cmd (&rest cmd)
  "Change the look; if the lights are off now (night / forced-off),
turn them on first so the change is actually visible."
  (if (lights--on-p)
      (apply #'lights--send cmd)
    (lights--run (lambda (_) (apply #'lights--send cmd)) "on")))

;; --- state -> buffer -----------------------------------------------------

(defun lights--apply-state (data)
  (setq lights--reachable (and data (eq (alist-get 'reachable data) t))
        lights--wedged (and data (eq (alist-get 'wedged data) t))
        lights--engine-age (and data (alist-get 'engine_age data))
        lights--status (and data (alist-get 'lights data)))
  (when lights--reachable (setq lights--waking nil))
  (setq lights--brightness (lights--st 'brightness 1.0))
  (lights--render)
  (lights--swatch-control))

(defun lights--fmt-secs (s)
  (if s (format "%dm%02ds" (/ s 60) (% s 60)) "?"))

(defun lights--status-text ()
  "The two-line status panel, ported from the TUI's apply_state."
  (cond
   ((and lights--reachable (null lights--status))
    "connecting…")
   ((not lights--reachable)
    (if lights--waking
        " waking VENGEANCE…  (WoL sent, booting from S5)"
      " VENGEANCE offline  —  press w to wake"))
   (lights--wedged
    (format (concat "⚠ ENGINE WEDGED — status %s, controls are being"
                    " ignored\n   R: kill + relaunch it (takes a few seconds)")
            (if lights--engine-age
                (format "%ss stale" lights--engine-age) "missing")))
   ((not (lights--on-p))
    (if (equal (lights--st 'forced) "off")
        (format (concat " FORCED OFF until %s, then back on schedule\n"
                        "   a: back on schedule now")
                (lights--st 'forced_until))
      (concat " on schedule — night, LEDs black until 08:00\n"
              "   pick an effect to light up now")))
   (t
    (let* ((power (if (equal (lights--st 'forced) "on")
                      (format (concat " FORCED ON until %s, then back on"
                                      " schedule   ·   a: back to schedule now")
                              (lights--st 'forced_until))
                    " on schedule — lit 08:00–23:00, black overnight"))
           (eff (lights--st 'effect "?"))
           (look (cond
                  ((lights--st 'rotation)
                   (format "⟳ ROTATING '%s' — now: %s, next roll in %s"
                           (lights--st 'preset) eff
                           (lights--fmt-secs (lights--st 'seconds_left))))
                  ((equal (lights--st 'mode) "random")
                   " RANDOM look — holds until you change it   ·   o: rotate")
                  (t (format
                      " PINNED: %s — holds until you change it   ·   p: unpin"
                      eff))))
           (fans (lights--st 'fans)))
      (when fans
        (setq look (format "%s   ·    fan overrides: %s" look
                           (string-join (append fans nil) ", "))))
      (concat power "\n" look)))))

(defun lights--active-marks ()
  "(EFFECT . PRESET) actually playing on the box, or nils."
  (let ((live (and lights--reachable (lights--on-p))))
    (cons (and live (not (equal (lights--st 'mode) "random"))
               (lights--st 'effect))
          (and live (lights--st 'rotation) (lights--st 'preset)))))

(defun lights--insert-item (name id section active)
  (insert (propertize
           (concat (if active
                       (propertize (concat "  ● " name) 'face 'lights-active)
                     (concat "    " name))
                   "\n")
           'lights-id id 'lights-section section)))

(defun lights--detail-text (id)
  "Detail for the item ID at point: effect description or preset pool."
  (pcase (and id (substring id 0 2))
    ("e:"
     (let ((name (substring id 2)))
       (concat (propertize name 'face 'bold) "\n"
               (or (gethash name (gethash "descriptions" lights--catalog)) ""))))
    ("p:"
     (let* ((name (substring id 2))
            (live (and lights--reachable (lights--st 'rotation)
                       (equal (lights--st 'preset) name)
                       (lights--st 'effect))))
       (concat
        (propertize (format "⟳ %s rotates through:" name) 'face 'bold)
        (mapconcat
         (lambda (n)
           (if (equal n live)
               (propertize (format "\n  ● %s ← now" n) 'face 'lights-active)
             (format "\n  · %s" n)))
         (cadr (assoc name (gethash "presets" lights--catalog))) ""))))
    (_ "")))

(defun lights--render ()
  "Redraw the whole dashboard, preserving the item under point."
  (when-let ((buf (get-buffer lights--buffer)))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (id (get-text-property (point) 'lights-id))
             (line (line-number-at-pos))
             (marks (lights--active-marks))
             (swatch-pos nil))
        (erase-buffer)
        (insert (propertize (format " %d%%\n" (round (* 100 lights--brightness)))
                            'face 'shadow))
        (setq swatch-pos (point))
        (insert "\n\n")                 ; swatch line + blank
        (insert (propertize
                 (concat " " (string-replace "\n" "\n " (lights--status-text))
                         "\n")
                 'face 'lights-status)
                "\n")
        (insert (propertize "effects\n" 'face 'bold))
        (pcase-dolist (`(,group ,pool) (gethash "groups" lights--catalog))
          (insert (propertize (format "─ %s\n" group) 'face 'lights-group))
          (dolist (n pool)
            (lights--insert-item n (concat "e:" n) 'effects
                                 (equal n (car marks)))))
        (insert (propertize "\npresets\n" 'face 'bold))
        (pcase-dolist (`(,n ,_pool) (gethash "presets" lights--catalog))
          (lights--insert-item n (concat "p:" n) 'presets
                               (equal n (cdr marks))))
        (insert "\n")
        ;; detail markers land BEFORE the footer; end marker is
        ;; insertion-type t so detail text inserted at it stays inside
        (let ((dpos (point)))
          (insert (propertize "\n? keybinds" 'face 'shadow))
          (set-marker (or lights--detail-beg
                          (setq lights--detail-beg (make-marker)))
                      dpos)
          (set-marker (or lights--detail-end
                          (setq lights--detail-end (make-marker)))
                      dpos)
          (set-marker-insertion-type lights--detail-end t))
        ;; swatch overlay: survives re-render because we recreate it
        (when lights--swatch-overlay (delete-overlay lights--swatch-overlay))
        (setq lights--swatch-overlay (make-overlay swatch-pos (1+ swatch-pos)))
        (overlay-put lights--swatch-overlay 'display
                     (concat (or lights--swatch-text "") "\n"))
        ;; put point back on the item it was on
        (goto-char (point-min))
        (let ((m (and id (text-property-search-forward 'lights-id id t))))
          (if m
              (goto-char (prop-match-beginning m))
            (forward-line (1- line))))
        (unless (get-text-property (point) 'lights-id)
          (lights--goto-item 1 t))
        (setq lights--detail-id 'unset)
        (lights--update-detail)))))

(defun lights--update-detail ()
  "Keep the detail section in sync with the item under point."
  (let ((id (get-text-property (point) 'lights-id)))
    (unless (equal id lights--detail-id)
      (setq lights--detail-id id)
      (when (and lights--detail-beg (marker-position lights--detail-beg))
        (let ((inhibit-read-only t))
          (save-excursion
            (delete-region lights--detail-beg lights--detail-end)
            (goto-char lights--detail-beg)
            (insert (lights--detail-text id))))))))

;; --- swatch stream -------------------------------------------------------

(defun lights--swatch-width ()
  (let ((win (get-buffer-window lights--buffer t)))
    (max 8 (- (if win (window-width win) 60) 4))))

(defun lights--swatch-filter (_proc chunk)
  (setq lights--swatch-acc (concat lights--swatch-acc chunk))
  (let (line done)
    (while (setq line (and (string-match "\\(.*\\)\n" lights--swatch-acc)
                           (match-string 1 lights--swatch-acc)))
      (setq lights--swatch-acc (substring lights--swatch-acc (match-end 0)))
      (when (string-prefix-p "F " line) (setq done line)))
    (when done
      (setq lights--swatch-text
            (if (equal done "F off")
                (make-string (lights--swatch-width) ?\s)
              (mapconcat (lambda (hex)
                           (propertize " " 'face
                                       (list :background (concat "#" hex))))
                         (split-string (substring done 2)) "")))
      (when (and lights--swatch-overlay
                 (overlay-buffer lights--swatch-overlay))
        (overlay-put lights--swatch-overlay 'display
                     (concat lights--swatch-text "\n"))))))

(defun lights--swatch-start ()
  (unless (process-live-p lights--swatch-proc)
    (setq lights--swatch-acc "")
    (setq lights--swatch-proc
          (make-process :name "lights-swatch" :noquery t
                        :command (list lights-python lights-swatch-stream)
                        :connection-type 'pipe
                        :filter #'lights--swatch-filter
                        :stderr (get-buffer-create " *lights-swatch-err*")))))

(defun lights--swatch-control ()
  "Point the streamer at whatever is playing (mirrors the TUI's active_fn)."
  (when (process-live-p lights--swatch-proc)
    (let* ((live (and lights--reachable (lights--on-p)))
           (random-p (and live (equal (lights--st 'mode) "random")
                          (lights--st 'params)))
           (ctl `((effect . ,(and live (not random-p) (lights--st 'effect)))
                  (params . ,(and random-p (lights--st 'params)))
                  (width . ,(lights--swatch-width))
                  (brightness . ,lights--brightness)
                  (fps . ,lights-swatch-fps))))
      (process-send-string lights--swatch-proc
                           (concat (json-encode ctl) "\n")))))

;; --- navigation ----------------------------------------------------------

(defun lights--goto-item (dir &optional from-top)
  "Move point DIR lines at a time to the next line carrying an item."
  (when from-top (goto-char (point-min)))
  (let ((start (point)))
    (forward-line dir)
    (while (and (not (get-text-property (point) 'lights-id))
                (not (if (> dir 0) (eobp) (bobp))))
      (forward-line dir))
    (if (get-text-property (point) 'lights-id)
        (beginning-of-line)
      (goto-char start))))

(defun lights-next-item ()
  "Move to the next effect/preset (skipping group headers)."
  (interactive)
  (lights--goto-item 1))

(defun lights-prev-item ()
  "Move to the previous effect/preset (skipping group headers)."
  (interactive)
  (lights--goto-item -1))

(defun lights-other-section ()
  "Jump between the effects and presets sections."
  (interactive)
  (let ((here (get-text-property (point) 'lights-section))
        (found nil))
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (let ((sec (get-text-property (point) 'lights-section)))
          (when (and sec (not (eq sec (or here 'presets))))
            (setq found (point))))
        (forward-line 1)))
    (when found (goto-char found))))

;; --- controls ------------------------------------------------------------

(defun lights-apply ()
  "Apply the effect or preset under point."
  (interactive)
  (let ((id (get-text-property (point) 'lights-id)))
    (cond
     ((null id) nil)
     ((not lights--reachable)
      (message "VENGEANCE is offline — press w to wake"))
     ((string-prefix-p "e:" id)
      (lights--apply-cmd "set-effect" (substring id 2)))
     ((string-prefix-p "p:" id)
      (lights--apply-cmd "set-preset" (substring id 2))))))

(defun lights-wake ()
  "Wake VENGEANCE over Wake-on-LAN."
  (interactive)
  (if lights--reachable
      (message "VENGEANCE is already awake")
    (setq lights--waking t)
    (lights--render)
    (lights--run nil "wake")))

(defun lights-randomize ()
  "Roll a random parametric look."
  (interactive)
  (lights--apply-cmd "random"))

(defun lights-rotation-on ()
  "Turn preset rotation on."
  (interactive)
  (lights--send "rotation" "on"))

(defun lights-pin ()
  "Pin the current effect, or unpin back into rotation."
  (interactive)
  (if (equal (lights--st 'mode) "pinned")
      (lights--send "rotation" "on")
    (lights--send "rotation" "off")))

(defun lights-schedule ()
  "Back on the day/night schedule (drop a forced on/off)."
  (interactive)
  (lights--send "auto"))

(defun lights-reset ()
  "Clean slate: rotation, 100% brightness, no overrides."
  (interactive)
  (setq lights--brightness 1.0)
  (lights--send "reset"))

(defun lights-restart-engine ()
  "Kill + relaunch the engine on the box (for when it wedges)."
  (interactive)
  (message " restarting engine — kill + relaunch, ~5s…")
  (lights--send "restart-engine"))

(defun lights--set-brightness (delta)
  (setq lights--brightness
        (min 1.0 (max 0.05 (+ lights--brightness delta))))
  (lights--render)
  (lights--swatch-control)
  (lights--send "brightness" (format "%.2f" lights--brightness)))

(defun lights-brightness-up ()
  "Brightness up 15%."
  (interactive)
  (lights--set-brightness 0.15))

(defun lights-brightness-down ()
  "Brightness down 15%."
  (interactive)
  (lights--set-brightness -0.15))

;; --- keybinds page -------------------------------------------------------

(defconst lights--keybinds
  '(("navigate"
     ("j / k" "move down / up (headers are skipped)")
     ("gg / G" "jump to top / bottom")
     ("TAB" "switch between effects and presets")
     ("l / RET" "apply the highlighted effect or preset"))
    ("looks"
     ("r" " randomize")
     ("o" "⟳ rotation on")
     ("p" " pin ⇄ unpin")
     ("x" "󰃢 reset (clean slate: rotation, 100%, no overrides)")
     ("[ / ]" " brightness down / up"))
    ("power & box"
     ("w" " wake VENGEANCE (Wake-on-LAN, when it's off)")
     ("a" " back on schedule (drop a forced on/off)")
     ("R" " restart engine (when it wedges and ignores controls)"))
    ("app"
     ("?" "this keybinds page")
     ("q" "quit"))))

(defun lights-help ()
  "Show every keybind, mirroring the TUI's ? overlay."
  (interactive)
  (let ((width (apply #'max (mapcar (lambda (sec)
                                      (apply #'max (mapcar (lambda (k)
                                                             (length (car k)))
                                                           (cdr sec))))
                                    lights--keybinds))))
    (with-help-window "*lights keybinds*"
      (with-current-buffer standard-output
        (dolist (sec lights--keybinds)
          (insert (propertize (format "─ %s\n" (car sec)) 'face 'lights-group))
          (pcase-dolist (`(,key ,desc) (cdr sec))
            (insert (format "  %s  %s\n"
                            (propertize (string-pad key width) 'face 'lights-key)
                            desc)))
          (insert "\n"))))))

;; --- mode ----------------------------------------------------------------

(defun lights-quit ()
  "Close the dashboard and stop the poll timer + swatch streamer."
  (interactive)
  (when-let ((buf (get-buffer lights--buffer)))
    (kill-buffer buf)))

(defun lights--cleanup ()
  (when lights--poll-timer
    (cancel-timer lights--poll-timer)
    (setq lights--poll-timer nil))
  (when (process-live-p lights--swatch-proc)
    (delete-process lights--swatch-proc))
  (setq lights--swatch-proc nil
        lights--swatch-overlay nil
        lights--swatch-text nil
        lights--detail-beg nil
        lights--detail-end nil))

(defvar lights-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" #'lights-next-item)
    (define-key map "k" #'lights-prev-item)
    (define-key map "\t" #'lights-other-section)
    (define-key map "l" #'lights-apply)
    (define-key map (kbd "RET") #'lights-apply)
    (define-key map "w" #'lights-wake)
    (define-key map "r" #'lights-randomize)
    (define-key map "o" #'lights-rotation-on)
    (define-key map "p" #'lights-pin)
    (define-key map "a" #'lights-schedule)
    (define-key map "x" #'lights-reset)
    (define-key map "R" #'lights-restart-engine)
    (define-key map "]" #'lights-brightness-up)
    (define-key map "[" #'lights-brightness-down)
    (define-key map "?" #'lights-help)
    (define-key map "q" #'lights-quit)
    map)
  "Keymap for `lights-mode'.")

(define-derived-mode lights-mode special-mode "lights"
  "Dashboard for the VENGEANCE lights — a thin skin over lightsctl."
  (setq-local header-line-format "  VENGEANCE lights")
  (setq-local cursor-type 'bar)
  (setq-local truncate-lines t)
  (hl-line-mode 1)
  (add-hook 'post-command-hook #'lights--update-detail nil t)
  (add-hook 'kill-buffer-hook #'lights--cleanup nil t))

(with-eval-after-load 'evil
  (evil-set-initial-state 'lights-mode 'motion)
  (evil-make-overriding-map lights-mode-map))

(defun lights--load-catalog ()
  (with-temp-buffer
    (unless (zerop (call-process lights-python nil t nil
                                 lights-swatch-stream "--dump"))
      (user-error "lights: swatch-stream.py --dump failed (%s)"
                  (string-trim (buffer-string))))
    (json-parse-string (buffer-string) :array-type 'list)))

;;;###autoload
(defun lights ()
  "Open the VENGEANCE lights dashboard."
  (interactive)
  (unless (file-exists-p lights-ctl)
    (user-error "lights: %s not found" lights-ctl))
  (let ((existing (get-buffer lights--buffer)))
    (if existing
        (pop-to-buffer existing)
      (setq lights--catalog (lights--load-catalog)
            lights--status nil lights--reachable t lights--waking nil
            lights--wedged nil lights--brightness 1.0
            lights--detail-id 'unset lights--detail-beg nil
            lights--detail-end nil lights--swatch-text nil)
      (with-current-buffer (get-buffer-create lights--buffer)
        (lights-mode)
        (let ((inhibit-read-only t))
          (insert "connecting…")))
      (pop-to-buffer lights--buffer)
      (lights--swatch-start)
      (lights--render)
      (setq lights--poll-timer
            (run-at-time 0 lights-poll-seconds #'lights--poll)))))

(provide 'lights)
;;; lights.el ends here
