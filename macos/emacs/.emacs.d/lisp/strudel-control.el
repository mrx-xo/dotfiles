;;; strudel-control.el --- Native editing with Strudex audio -*- lexical-binding: t; -*-

;; Install the runtime with npm install -g strudex@0.1.0 (Node and Bun required).
;; Edit ordinary JavaScript buffers; play/update sends unsaved buffer contents.
;; WebKit is only the audio engine.  No save hooks or keybindings are installed.

(require 'cl-lib)
(require 'url)
(require 'json)
(require 'subr-x)
(require 'xwidget nil t)

(defgroup mr-x/strudel nil "Strudel music from native buffers." :group 'multimedia)
(defcustom mr-x/strudel-port 4323
  "Port for the Emacs-owned Strudex bridge." :type 'integer)
(defvar mr-x/strudel--process nil)
(defvar mr-x/strudel--widget nil)
(defvar mr-x/strudel--patch nil)
(defvar mr-x/strudel--timer nil)
(defvar mr-x/strudel--pending nil)
(defvar mr-x/strudel--ready nil)
(defvar mr-x/strudel--deadline nil)
(defvar mr-x/strudel--generation 0)
(defvar mr-x/strudel--unlock-window nil)

(defun mr-x/strudel--url ()
  (format "http://localhost:%d" mr-x/strudel-port))

(defun mr-x/strudel--code ()
  "Read the entire current buffer, including unsaved and narrowed text."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun mr-x/strudel--post (path body)
  "Send BODY to bridge PATH, failing visibly on a transport error."
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "text/plain; charset=utf-8")))
         (url-request-data (encode-coding-string body 'utf-8))
         (url-proxy-services nil)
         (response (url-retrieve-synchronously
                    (concat (mr-x/strudel--url) path) t t 2)))
    (unless response (user-error "Strudel bridge did not respond"))
    (unwind-protect
        (with-current-buffer response
          (unless (eq url-http-response-status 200)
            (user-error "Strudel bridge returned HTTP %s" url-http-response-status)))
      (kill-buffer response))))

(defun mr-x/strudel--widget-live-p ()
  (and mr-x/strudel--widget
       (buffer-live-p (xwidget-buffer mr-x/strudel--widget))))

(defun mr-x/strudel--bridge-up-p ()
  "Return non-nil once the bridge responds to HTTP."
  (let ((url-proxy-services nil))
    (condition-case nil
        (when-let* ((response (url-retrieve-synchronously
                              (concat (mr-x/strudel--url) "/patch") t t 0.2)))
          (unwind-protect
              (with-current-buffer response (memq url-http-response-status '(200 204)))
            (kill-buffer response)))
      (error nil))))

(defun mr-x/strudel--cancel-start ()
  (cl-incf mr-x/strudel--generation)
  (when (timerp mr-x/strudel--timer) (cancel-timer mr-x/strudel--timer))
  (setq mr-x/strudel--timer nil mr-x/strudel--pending nil))

(defun mr-x/strudel--poll (generation)
  "Wait for the bridge and audio engine without blocking Emacs."
  (when (= generation mr-x/strudel--generation)
    (cond
     ((not (process-live-p mr-x/strudel--process))
      (mr-x/strudel--cancel-start)
      (message "Strudel bridge failed; see *Strudel bridge*"))
     ((time-less-p mr-x/strudel--deadline (current-time))
      (mr-x/strudel--cancel-start)
      (message "Strudel audio startup timed out; run mr-x/strudel-show-audio to inspect"))
     ((not (mr-x/strudel--bridge-up-p))
      (setq mr-x/strudel--timer
            (run-at-time 0.5 nil #'mr-x/strudel--poll generation)))
     (t
      (unless (mr-x/strudel--widget-live-p)
        (save-window-excursion
          (save-current-buffer
            (xwidget-webkit-browse-url (mr-x/strudel--url) t)
            (setq mr-x/strudel--widget (xwidget-webkit-current-session)))))
      (xwidget-webkit-execute-script
       mr-x/strudel--widget
       "(() => { const r = document.getElementById('repl'); if (!r?.editor || typeof getAudioContext !== 'function') return 'loading'; document.dispatchEvent(new Event('click')); return getAudioContext().state === 'running' ? 'ready' : 'unlock'; })()"
       (lambda (ready)
         (when (= generation mr-x/strudel--generation)
           (if (equal ready "ready")
               (progn
                 (setq mr-x/strudel--ready t)
                 (when (and (window-live-p mr-x/strudel--unlock-window)
                            (eq (window-buffer mr-x/strudel--unlock-window)
                                (xwidget-buffer mr-x/strudel--widget)))
                   (quit-window nil mr-x/strudel--unlock-window))
                 (setq mr-x/strudel--unlock-window nil)
                 (when mr-x/strudel--pending
                   (mr-x/strudel--post "/eval" mr-x/strudel--pending)
                   (setq mr-x/strudel--pending nil)
                   (message "Strudel: playing; edit and run mr-x/strudel-update")))
             (when (and (equal ready "unlock")
                        (not (window-live-p mr-x/strudel--unlock-window)))
               (setq mr-x/strudel--unlock-window
                     (display-buffer (xwidget-buffer mr-x/strudel--widget)))
               ;; Give the user time to make the one-time audio gesture.
               (setq mr-x/strudel--deadline (time-add (current-time) 300))
               (message "Strudel: click 'click to enable audio' once; this pane will then hide"))
             (setq mr-x/strudel--timer
                   (run-at-time 0.5 nil #'mr-x/strudel--poll generation))))))))))

;;;###autoload
(defun mr-x/strudel-play ()
  "Start audio and play the current native buffer, without saving it.
WebKit may show a one-time audio-unlock prompt, then stays hidden.
First startup needs the
network for Strudex's Strudel JavaScript bundle and default samples."
  (interactive)
  (unless (and (featurep 'xwidget-internal) (display-graphic-p))
    (user-error "Strudel audio needs a graphical Emacs with WebKit"))
  (let ((code (mr-x/strudel--code)))
    (when (string-empty-p (string-trim code)) (user-error "This buffer is empty"))
    (if (and mr-x/strudel--ready (process-live-p mr-x/strudel--process)
             (mr-x/strudel--widget-live-p))
        (mr-x/strudel--post "/eval" code)
      (mr-x/strudel--cancel-start)
      (setq mr-x/strudel--ready nil)
      ;; A previous failed navigation must not poison the next startup.
      (when (mr-x/strudel--widget-live-p)
        (kill-buffer (xwidget-buffer mr-x/strudel--widget)))
      (setq mr-x/strudel--widget nil)
      (unless (process-live-p mr-x/strudel--process)
        (unless (and (executable-find "strudex") (executable-find "bun"))
          (user-error "Install Strudex and Bun first"))
        (when (and mr-x/strudel--patch (file-exists-p mr-x/strudel--patch))
          (delete-file mr-x/strudel--patch))
        (setq mr-x/strudel--patch (make-temp-file "emacs-strudel-" nil ".js"))
        ;; Run Bun directly so the Emacs process object owns the audio server,
        ;; not a Node wrapper that can outlive or orphan its child.
        (let ((bridge (expand-file-name
                       "../src/bridge.mjs"
                       (file-name-directory
                        (file-truename (executable-find "strudex"))))))
          (unless (file-exists-p bridge)
            (user-error "Strudex bridge missing; reinstall strudex@0.1.0"))
          (setq mr-x/strudel--process
              (make-process :name "strudel-audio" :buffer "*Strudel bridge*"
                            :command (list (executable-find "bun") bridge
                                           mr-x/strudel--patch "--no-watch"
                                           "--port" (number-to-string mr-x/strudel-port))
                            :noquery t))))
      (setq mr-x/strudel--pending code
            mr-x/strudel--deadline (time-add (current-time) 60)
            mr-x/strudel--timer
            (run-at-time 1 nil #'mr-x/strudel--poll mr-x/strudel--generation))
      (message "Strudel: starting audio in the background"))))

;;;###autoload
(defun mr-x/strudel-update ()
  "Evaluate the entire current buffer, including unsaved changes."
  (interactive)
  (unless mr-x/strudel--ready (user-error "Run mr-x/strudel-play first"))
  (mr-x/strudel--post "/eval" (mr-x/strudel--code))
  (message "Strudel: update sent"))

;;;###autoload
(defun mr-x/strudel-stop ()
  "Stop music, keeping the engine available for the next play command."
  (interactive)
  (mr-x/strudel--cancel-start)
  (when mr-x/strudel--ready (mr-x/strudel--post "/stop" ""))
  (message "Strudel: stopped"))

;;;###autoload
(defun mr-x/strudel-show-audio ()
  "Show the audio page for visualizations, loading errors, or audio unlock."
  (interactive)
  (unless (mr-x/strudel--widget-live-p) (user-error "Run mr-x/strudel-play first"))
  (pop-to-buffer (xwidget-buffer mr-x/strudel--widget)))

;;;###autoload
(defun mr-x/strudel-shutdown ()
  "Release only this integration's audio engine and bridge."
  (interactive)
  (mr-x/strudel--cancel-start)
  (setq mr-x/strudel--ready nil)
  (when (mr-x/strudel--widget-live-p)
    (kill-buffer (xwidget-buffer mr-x/strudel--widget)))
  (when (process-live-p mr-x/strudel--process)
    (delete-process mr-x/strudel--process))
  (when (and mr-x/strudel--patch (file-exists-p mr-x/strudel--patch))
    (delete-file mr-x/strudel--patch))
  (setq mr-x/strudel--widget nil mr-x/strudel--patch nil
        mr-x/strudel--unlock-window nil)
  (message "Strudel: audio session closed"))

(provide 'strudel-control)
;;; strudel-control.el ends here
