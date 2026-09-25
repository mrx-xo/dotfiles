;;; mr-x-boot-status.el --- Report daemon startup to sketchybar -*- lexical-binding: t; -*-

;; Almost all of daemon startup is Elpaca working through its queue after
;; init.el returns (49s until 2026-09-25, ~7s after loading evil before
;; general; see the Evil section of emacs.org).  This pushes what it is doing
;; to the `emacs_status' sketchybar item (the cacodemon) once a second:
;; loading init, then the package Elpaca is on with a done/total count,
;; then any workspace restore, then "ready in Ns".
;;
;; Loaded as the very first thing in init.el, before Elpaca, so it must
;; depend on nothing but Emacs itself.  Only the main daemon (socket
;; "server") reports; batch runs and the sandbox never touch the bar.
;;
;; The bar side lives in macos/sketchybar/plugins/emacs-status*.sh.

(require 'cl-lib)
(require 'seq)

(defvar mr-x/boot-status-voice t
  "Non-nil to phrase the label in the cacodemon's voice.
The package, count and time stay real; only the verb changes.")

(defvar mr-x/boot-status-verbs
  '("devouring" "chewing on" "gnawing at" "glaring at" "haunting"
    "summoning" "floating past" "running an errand for"
    "getting groceries for" "sniffing" "biting" "consulting the void about"
    "hexing" "negotiating with" "sizing up")
  "Verbs the cacodemon picks from, one per subject.")

(defvar mr-x/boot-status-enabled (member (daemonp) '(t "server"))
  "Non-nil when this Emacs reports to sketchybar.
True for the main daemon: --fg-daemon=server from launchd, or a plain
`emacs --daemon' (default socket name).  The sandbox socket is named sandbox.")

(defvar mr-x/boot-status-sketchybar
  (or (executable-find "sketchybar") "/opt/homebrew/bin/sketchybar")
  "Path to the sketchybar binary.")

(defvar mr-x/boot-status--summary-file
  (expand-file-name "var/boot-status.last" user-emacs-directory)
  "Shell-sourceable summary of the last boot, read by the click popup.")

(defvar mr-x/boot-status--start before-init-time
  "When the current run (boot or restore) started.")
(defvar mr-x/boot-status--booting t
  "Non-nil until the first ready; later runs are restores.")
(defvar mr-x/boot-status--timer nil)
(defvar mr-x/boot-status--last-push 0.0)
(defvar mr-x/boot-status--verb nil)
(defvar mr-x/boot-status--verb-subject nil)
(defvar mr-x/boot-status--config nil
  "Plist (:package :done :total) for the queued config body now running.")
(defvar mr-x/boot-status--config-started nil)
(defvar mr-x/boot-status--durations nil
  "Alist of package id to seconds its queued config body took.")

(defvar elpaca--queues)
(defvar elpaca-after-init-time)
(defvar mr-x/crash-workspace-current)

;;;; State

(defun mr-x/boot-status--elapsed ()
  "Whole seconds since the current run started."
  (round (float-time (time-subtract nil mr-x/boot-status--start))))

(defun mr-x/boot-status--elpaca-progress ()
  "Plist (:done :total :package :step) for Elpaca's queues, or nil."
  (when (and (boundp 'elpaca--queues) (fboundp 'elpaca--status))
    (let ((done 0) (total 0) current)
      (dolist (q elpaca--queues)
        (dolist (cell (elpaca-q<-elpacas q))
          (let ((status (elpaca--status (cdr cell))))
            (cl-incf total)
            (if (memq status '(finished failed))
                (cl-incf done)
              (when (or (null current)
                        (and (memq (cdr current) '(queued blocked))
                             (not (memq status '(queued blocked)))))
                (setq current (cons (car cell) status)))))))
      (list :done done :total total
            :package (car current) :step (cdr current)))))

(defun mr-x/boot-status--config-step (id index total)
  "Note that the config body for ID (INDEX of TOTAL) is starting."
  (ignore-errors
    (let ((now (float-time)))
      (when mr-x/boot-status--config-started
        (push (cons (plist-get mr-x/boot-status--config :package)
                    (- now mr-x/boot-status--config-started))
              mr-x/boot-status--durations))
      (setq mr-x/boot-status--config (list :package id :done index :total total)
            mr-x/boot-status--config-started now)
      ;; The config loop is synchronous, so this is the only chance to push.
      (when (> (- now mr-x/boot-status--last-push) 0.1)
        (mr-x/boot-status--tick)))))

(defun mr-x/boot-status--instrument-forms (forms)
  "Prefix each (ID . BODY) in FORMS with a progress call; return FORMS.
FORMS is an Elpaca queue's form list: newest first, run after `nreverse'."
  (let ((total (length forms)) (index 0))
    (dolist (cell (reverse forms))
      (setcdr cell (cons `(mr-x/boot-status--config-step
                           ',(car cell) ,(cl-incf index) ,total)
                         (cdr cell)))))
  forms)

(defun mr-x/boot-status--before-queue-finalize (q)
  "Instrument Q's queued config bodies while a boot is being reported.
Elpaca evals every package's config in one synchronous loop, so without
this the label freezes for all of it.  The per-package times it records
are what found the 42s evil stall."
  (when mr-x/boot-status--timer
    (ignore-errors (mr-x/boot-status--instrument-forms (elpaca-q<-forms q)))))

(defun mr-x/boot-status--after-queue-finalize (&rest _)
  "Close out the last config body's timing."
  (when mr-x/boot-status--config-started
    (mr-x/boot-status--config-step nil 0 0)
    (setq mr-x/boot-status--config nil
          mr-x/boot-status--config-started nil)))

(defun mr-x/boot-status--slowest (n)
  "The N slowest config bodies, as \"pkg 20s, pkg 6s\"."
  (mapconcat (lambda (cell) (format "%s %ds" (car cell) (round (cdr cell))))
             (seq-take (sort (seq-filter #'car (copy-sequence mr-x/boot-status--durations))
                             (lambda (a b) (> (cdr a) (cdr b))))
                       n)
             ", "))

(defun mr-x/boot-status--restore-progress ()
  "Plist (:done :total) for a running workspace restore, or nil."
  (when (and (boundp 'mr-x/crash-workspace-current) mr-x/crash-workspace-current
             (fboundp 'mr-x/crash-workspace-attempt-entries))
    (let ((total (length (mr-x/crash-workspace-attempt-entries
                          mr-x/crash-workspace-current)))
          (left (length (mr-x/crash-workspace-attempt-queue
                         mr-x/crash-workspace-current))))
      (list :done (- total left) :total total))))

(defun mr-x/boot-status--phase ()
  "What Emacs is doing now as a plist with :phase, or nil when idle."
  (let ((restore (mr-x/boot-status--restore-progress)))
    (cond
     (restore (cons :phase (cons 'restore restore)))
     ((not after-init-time) '(:phase init))
     ((not (and (boundp 'elpaca-after-init-time) elpaca-after-init-time))
      (if mr-x/boot-status--config
          (append '(:phase packages :step configuring) mr-x/boot-status--config)
        (cons :phase (cons 'packages (mr-x/boot-status--elpaca-progress)))))
     (t nil))))

;;;; Label

(defun mr-x/boot-status--verb-for (subject)
  "The cacodemon's verb for SUBJECT, redrawn only when SUBJECT changes."
  (unless (and mr-x/boot-status--verb (equal subject mr-x/boot-status--verb-subject))
    (setq mr-x/boot-status--verb-subject subject
          mr-x/boot-status--verb (nth (random (length mr-x/boot-status-verbs))
                                      mr-x/boot-status-verbs)))
  mr-x/boot-status--verb)

(defun mr-x/boot-status--label (phase elapsed)
  "The bar label for PHASE (see `mr-x/boot-status--phase') after ELAPSED seconds."
  (let* ((kind (plist-get phase :phase))
         (subject (pcase kind
                    ('init "init")
                    ('packages (format "%s" (or (plist-get phase :package) "packages")))
                    ('restore "chats")))
         (verb (if mr-x/boot-status-voice
                   (mr-x/boot-status--verb-for subject)
                 (pcase kind
                   ('init "loading")
                   ('packages (format "%s" (or (plist-get phase :step) "waiting on")))
                   ('restore "restoring"))))
         (count (when (plist-get phase :total)
                  (format " · %d/%d" (plist-get phase :done) (plist-get phase :total)))))
    (format "%s %s%s · %ds" verb subject (or count "") elapsed)))

;;;; Bar

(defun mr-x/boot-status--push (state label)
  "Send STATE and LABEL to the sketchybar `emacs_status' item, without waiting."
  (when (and mr-x/boot-status-enabled (file-executable-p mr-x/boot-status-sketchybar))
    (let ((process-connection-type nil))
      (ignore-errors
        (set-process-query-on-exit-flag
         (start-process "boot-status" nil mr-x/boot-status-sketchybar
                        "--trigger" "emacs_status_update"
                        (concat "EMACS_STATUS_STATE=" state)
                        (concat "EMACS_STATUS_LABEL=" label))
         nil)))))

(defun mr-x/boot-status--seconds-between (from to)
  "Whole seconds from FROM to TO, or \"\" when either is missing."
  (if (and from to) (number-to-string (round (float-time (time-subtract to from)))) ""))

(defun mr-x/boot-status--write-summary (total)
  "Record the finished boot (TOTAL seconds) for the bar's click popup."
  (ignore-errors
    (make-directory (file-name-directory mr-x/boot-status--summary-file) t)
    (with-temp-file mr-x/boot-status--summary-file
      (insert (format "EMACS_BOOT_TOTAL=%d\n" total)
              (format "EMACS_BOOT_INIT=%s\n"
                      (mr-x/boot-status--seconds-between before-init-time after-init-time))
              (format "EMACS_BOOT_PACKAGES=%s\n"
                      (mr-x/boot-status--seconds-between
                       after-init-time (and (boundp 'elpaca-after-init-time)
                                            elpaca-after-init-time)))
              (format "EMACS_BOOT_SLOWEST='%s'\n" (mr-x/boot-status--slowest 3))
              (format "EMACS_BOOT_AT='%s'\n" (format-time-string "%a %H:%M"))
              (format "EMACS_BOOT_PID=%d\n" (emacs-pid))))))

(defun mr-x/boot-status--tick ()
  "Push the current phase, or push ready and stop once idle."
  (setq mr-x/boot-status--last-push (float-time))
  (let ((phase (mr-x/boot-status--phase))
        (elapsed (mr-x/boot-status--elapsed)))
    (if phase
        (mr-x/boot-status--push "booting" (mr-x/boot-status--label phase elapsed))
      (when (timerp mr-x/boot-status--timer) (cancel-timer mr-x/boot-status--timer))
      (setq mr-x/boot-status--timer nil)
      (if mr-x/boot-status--booting
          (progn (mr-x/boot-status--write-summary elapsed)
                 (mr-x/boot-status--push "ready" (format "ready in %ds" elapsed)))
        (mr-x/boot-status--push "ready" (format "restored in %ds" elapsed)))
      (setq mr-x/boot-status--booting nil))))

(defun mr-x/boot-status--maybe-tick (&rest _)
  "Tick at most once a second; hooked to Elpaca status changes.
Elpaca can activate packages in long synchronous runs where timers never
fire, so status changes drive the label too."
  (when (and mr-x/boot-status--timer
             (> (- (float-time) mr-x/boot-status--last-push) 1.0))
    (mr-x/boot-status--tick)))

(defun mr-x/boot-status-start ()
  "Start reporting.  Called at the top of init.el and when a restore starts."
  (when mr-x/boot-status-enabled
    (unless mr-x/boot-status--booting
      (setq mr-x/boot-status--start (current-time)))
    (unless (timerp mr-x/boot-status--timer)
      (setq mr-x/boot-status--timer (run-at-time 1 1 #'mr-x/boot-status--tick)))
    (mr-x/boot-status--tick)))

(with-eval-after-load 'elpaca
  (advice-add 'elpaca--set-status :after #'mr-x/boot-status--maybe-tick)
  (advice-add 'elpaca--finalize-queue :before #'mr-x/boot-status--before-queue-finalize)
  (advice-add 'elpaca--finalize-queue :after #'mr-x/boot-status--after-queue-finalize))
(with-eval-after-load 'mr-x-crash-workspace
  (advice-add 'mr-x/crash-workspace-start :after
              (lambda (&rest _) (mr-x/boot-status-start))
              '((name . mr-x/boot-status))))

(provide 'mr-x-boot-status)
;;; mr-x-boot-status.el ends here
