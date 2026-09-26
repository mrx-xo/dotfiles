;;; review-store.el --- Pause, resume and remember review sessions -*- lexical-binding: t; -*-
;;; Commentary:
;; A paused review is a record: the source's recipe, every loaded file's
;; text, viewed marks by path, and where you were.  Records live in memory
;; and on disk, one per PR or range, so a review survives a restart and
;; resumes on exactly the snapshot you left.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'review-session)
(require 'review-panel)

(defcustom review-store-directory (locate-user-emacs-file "var/review-sessions/")
  "Where paused reviews are saved, one file per review."
  :type 'directory :group 'review)

(defcustom review-store-autosave-interval 60
  "Seconds between saves of the live review, so a crash loses little."
  :type 'natnum :group 'review)

(defcustom review-session-keep-on-quit nil
  "Keep a review's saved record when it quits, not only when it pauses."
  :type 'boolean :group 'review)

(defvar review-store--memory (make-hash-table :test #'equal) "Records by review key.")
(defvar review-store--timer nil)
(defvar review-store-restored-functions nil
  "Called with SESSION and RECORD after a review is restored.")

(defconst review-store--file-keys
  '(:path :old-path :kind :binary :unchanged :mode :blobs :index-blob :old-text :new-text)
  "File plist keys a record keeps.  Rows, renders and caches are rebuilt.")

(defun review-store--file (file)
  (let (out)
    (dolist (k review-store--file-keys)
      (when-let ((v (plist-get file k)))
        (setq out (plist-put out k (if (stringp v) (substring-no-properties v) v)))))
    out))

(defun review-store--bare (file)
  "FILE without its saved texts: what the session's file list holds."
  (cl-loop for (k v) on file by #'cddr
           unless (memq k '(:old-text :new-text)) append (list k v)))

(defun review-store--panel (session)
  (let ((b (review-session-panel session)))
    (when (buffer-live-p b)
      (list :toggled (buffer-local-value 'review-panel--toggled b)
            :collapsed (buffer-local-value 'review-panel--collapsed b)))))

(defun review-store-record (session)
  "SESSION as a record that `review-store-restore' can bring back."
  (let* ((source (review-session-source session))
         (recipe (or (review-source-recipe source)
                     (user-error "This review cannot be saved: its source has no recipe")))
         (files (review-session-files session)))
    (list :version 1
          :key (review-source-key recipe)
          :recipe recipe
          :title (review-source-title source)
          :subtitle (review-source-subtitle source)
          :range-label (review-source-range-label source)
          :old-label (review-source-old-label source)
          :new-label (review-source-new-label source)
          :paused-at (float-time)
          :files (mapcar #'review-store--file files)
          :viewed (mapcar (lambda (i) (plist-get (aref files i) :path)) (review-session-viewed session))
          :current-path (plist-get (aref files (review-session-current session)) :path)
          :hunk (review-session-hunk session)
          :panes (review-session-pane-state session)
          :panel (review-store--panel session)
          ;; A request still waiting on its reply is kept too: its reply
          ;; finds the resumed review by the :request token.
          :walkthrough (let ((w (review-session-walkthrough session)))
                         (and (or (plist-get w :steps) (plist-get w :request)) w)))))

(defun review-store--path (key)
  (expand-file-name (concat (md5 key) ".eld") review-store-directory))

(defun review-store--write (record)
  "Write RECORD to disk.  A pending walkthrough request stays in memory only:
nothing waits on its reply after a restart."
  (make-directory review-store-directory t)
  (unless (plist-get (plist-get record :walkthrough) :steps)
    (setq record (plist-put (copy-sequence record) :walkthrough nil)))
  (let ((print-length nil) (print-level nil) (print-circle nil))
    (with-temp-file (review-store--path (plist-get record :key))
      (setq buffer-file-coding-system 'utf-8-unix)
      (insert ";; -*- coding: utf-8-unix -*-\n")
      (prin1 record (current-buffer))
      (insert "\n"))))

(defun review-store--read (file)
  "The record in FILE, or nil with a message when it cannot be read."
  (condition-case err
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
        (let ((record (read (current-buffer))))
          (unless (and (listp record) (eql (plist-get record :version) 1)
                       (stringp (plist-get record :key)))
            (error "Not a saved review"))
          record))
    (error (message "Review: skipping unreadable saved review %s (%s)"
                    (abbreviate-file-name file) (error-message-string err))
           nil)))

(defun review-store-save (session)
  "Save SESSION to memory and disk; return the record."
  (let ((record (review-store-record session)))
    (puthash (plist-get record :key) record review-store--memory)
    (review-store--write record)
    record))

(defun review-store-load (key)
  "The record for KEY: memory first, then disk."
  (or (gethash key review-store--memory)
      (let ((file (review-store--path key)))
        (and (file-readable-p file) (review-store--read file)))))

(defun review-store-list ()
  "Every saved record, newest first.  Memory wins over disk for a key."
  (let ((seen (make-hash-table :test #'equal)) out)
    (maphash (lambda (key record) (puthash key t seen) (push record out)) review-store--memory)
    (when (file-directory-p review-store-directory)
      (dolist (file (directory-files review-store-directory t "\\.eld\\'"))
        (when-let ((record (review-store--read file)))
          (unless (gethash (plist-get record :key) seen)
            (puthash (plist-get record :key) t seen)
            (push record out)))))
    (sort out (lambda (a b) (> (plist-get a :paused-at) (plist-get b :paused-at))))))

(defun review-store-drop (key)
  "Forget the saved record for KEY."
  (remhash key review-store--memory)
  (let ((file (review-store--path key)))
    (when (file-exists-p file) (delete-file file))))

;;;; Rebuilding

(defun review-store--live-source (recipe files)
  "A live source for RECIPE, pinned to its saved revisions where it can be, or nil."
  (ignore-errors
    (pcase (plist-get recipe :kind)
      ('git-range
       (let ((revs (plist-get recipe :revs)))
         (review-source-git-range (plist-get recipe :directory)
                                  (if (and (stringp (car revs)) (stringp (cdr revs)))
                                      (format "%s..%s" (car revs) (cdr revs))
                                    (plist-get recipe :range)))))
      ('forgejo (review-source-forgejo-pr (plist-get recipe :host) (plist-get recipe :owner)
                                          (plist-get recipe :repo) (plist-get recipe :number)
                                          files (plist-get recipe :title)))
      ('github (review-source-github-pr (plist-get recipe :directory) (plist-get recipe :owner)
                                        (plist-get recipe :name) (plist-get recipe :number)
                                        :title (plist-get recipe :title)
                                        :base-ref (plist-get recipe :base-ref)
                                        :head-ref (plist-get recipe :head-ref)
                                        :base-rev (plist-get recipe :base-rev)
                                        :head-rev (plist-get recipe :head-rev))))))

(defun review-store-source (record)
  "A source that serves RECORD's saved texts, and the live source for the rest."
  (let* ((recipe (plist-get record :recipe))
         (files (plist-get record :files))
         (bare (mapcar #'review-store--bare files))
         (live nil))
    (cl-flet ((live () (or live (setq live (or (review-store--live-source recipe bare) :none)))))
      (make-review-source
       :name (if (eq (plist-get recipe :kind) 'git-range) "git" (format "%s" (plist-get recipe :kind)))
       :title (plist-get record :title) :subtitle (plist-get record :subtitle)
       :range-label (plist-get record :range-label)
       :old-label (plist-get record :old-label) :new-label (plist-get record :new-label)
       :number (plist-get recipe :number)
       :directory (or (plist-get recipe :directory) default-directory)
       :recipe recipe
       :files (lambda () (copy-tree bare))
       :text (lambda (file side callback)
               (let* ((saved (seq-find (lambda (f) (equal (plist-get f :path) (plist-get file :path))) files))
                      (text (plist-get saved (if (eq side 'old) :old-text :new-text))))
                 (cond (text (funcall callback text))
                       ((eq (live) :none)
                        (funcall callback nil (format "%s was not loaded before the pause, and its source is gone"
                                                      (plist-get file :path))))
                       (t (funcall (review-source-text (live)) file side callback)))))
       :origin (lambda (file start end)
                 (if (eq (live) :none)
                     (list :label (format "%s:%d" (plist-get file :path) start) :link nil :url nil)
                   (funcall (review-source-origin (live)) file start end)))))))

(defun review-store--index (session path)
  (cl-position path (review-session-files session) :key (lambda (f) (plist-get f :path)) :test #'equal))

(defun review-store-restore (record)
  "Start a review on RECORD's snapshot, where it was left.  Return the session."
  (let* ((session (review-session-start (review-store-source record))))
    (setf (review-session-viewed session)
          (delq nil (mapcar (lambda (p) (review-store--index session p)) (plist-get record :viewed)))
          (review-session-walkthrough session) (plist-get record :walkthrough))
    (review-panel-open session)
    (when-let ((panel (plist-get record :panel))
               (buffer (review-session-panel session)))
      (with-current-buffer buffer
        (setq review-panel--toggled (plist-get panel :toggled)
              review-panel--collapsed (plist-get panel :collapsed))))
    (review-session-show (or (review-store--index session (plist-get record :current-path)) 0)
                         (plist-get record :hunk))
    (review-session-restore-pane-state session (plist-get record :panes))
    (run-hook-with-args 'review-store-restored-functions session record)
    (review-store--check-moved session record)
    session))

;;;; Moved on since the pause

(defun review-store--worktree-changed-p (record)
  "Non-nil when a saved working-tree text differs from the file on disk."
  (let ((dir (plist-get (plist-get record :recipe) :directory)))
    (seq-some (lambda (file)
                (let ((text (plist-get file :new-text))
                      (name (expand-file-name (concat "./" (plist-get file :path)) dir)))
                  (and text
                       (not (equal text (if (file-regular-p name)
                                            (with-temp-buffer
                                              (let ((coding-system-for-read 'utf-8-unix))
                                                (insert-file-contents name))
                                              (buffer-string))
                                          ""))))))
              (plist-get record :files))))

(defun review-store-moved-p (record callback)
  "Call CALLBACK with a notice when RECORD's live source has moved on, else nil."
  (let ((recipe (plist-get record :recipe)))
    (pcase (plist-get recipe :kind)
      ('git-range
       (funcall callback
                (condition-case err
                    (let* ((saved (plist-get recipe :revs))
                           (now (review-source--git-revs (plist-get recipe :directory)
                                                         (plist-get recipe :range))))
                      (cond ((and saved (not (equal now saved)))
                             (format "%s moved since the pause" (or (plist-get recipe :range) "HEAD")))
                            ((and saved (null (cdr saved)) (review-store--worktree-changed-p record))
                             "working tree changed since the pause")))
                  (error (format "source unavailable (%s); showing the saved snapshot"
                                 (error-message-string err))))))
      ('forgejo
       (require 'forgejo-api)
       (let ((saved (cadr (plist-get recipe :revs))))
         (if (not saved) (funcall callback nil)
           (forgejo-api-get
            (plist-get recipe :host)
            (format "repos/%s/%s/pulls/%d" (plist-get recipe :owner) (plist-get recipe :repo)
                    (plist-get recipe :number))
            nil
            (lambda (data _headers)
              (let ((head (alist-get 'sha (alist-get 'head data))))
                (funcall callback (and head (not (equal head saved))
                                       (format "PR #%d has new commits since the pause"
                                               (plist-get recipe :number))))))
            :error-callback (lambda (_error) (funcall callback nil))))))
      (_ (funcall callback nil)))))

(defun review-store--check-moved (session record)
  (review-store-moved-p
   record
   (lambda (notice)
     (when (and notice (eq session review-session--current))
       (setf (review-session-notice session) notice)
       (review-session--notify session)))))

;;;; Refresh

(defvar review-store-refresh-functions nil
  "Alist of (KIND . FUNCTION) that open a fresh review for a recipe.
FUNCTION is called with RECIPE and the old RECORD.")

(defun review-store--refresh-git (recipe record)
  (let ((session (review-session-start (review-source-git-range (plist-get recipe :directory)
                                                                (plist-get recipe :range)))))
    (setf (review-session-viewed session)
          (delq nil (mapcar (lambda (p) (review-store--index session p)) (plist-get record :viewed))))
    (review-panel-open session)
    (review-session-show (or (review-store--index session (plist-get record :current-path)) 0)
                         (plist-get record :hunk))
    session))

(add-to-list 'review-store-refresh-functions (cons 'git-range #'review-store--refresh-git))

(defun review-session-refresh ()
  "Reload this review from its live source, keeping viewed marks and place by path."
  (interactive)
  (let* ((s (review-session--require))
         (recipe (review-source-recipe (review-session-source s)))
         (refresh (alist-get (plist-get recipe :kind) review-store-refresh-functions)))
    (unless refresh (user-error "This review cannot be refreshed"))
    (let ((record (review-store-record s)))
      (review-session-quit)
      (funcall refresh recipe record))))

;;;; Commands

(defun review-session-pause ()
  "Save this review and close it.  \\[review-session-resume] brings it back."
  (interactive)
  (let* ((s (review-session--require))
         (record (review-store-save s)))
    (let ((review-session--pausing t)) (review-session-quit))
    (message "Review paused: %s" (plist-get record :range-label))))

(defun review-store--describe (record)
  (format "%s  %s  %s  hunk %d  %d/%d viewed  %s"
          (plist-get record :range-label) (or (plist-get record :title) "")
          (plist-get record :current-path) (1+ (or (plist-get record :hunk) 0))
          (length (plist-get record :viewed)) (length (plist-get record :files))
          (format-time-string "%b %d %H:%M" (plist-get record :paused-at))))

(defun review-session-resume (&optional pick)
  "Return to the live review, or resume the newest paused one.
With PICK (\\[universal-argument]), choose among every paused review."
  (interactive "P")
  (if (and review-session--current (not pick))
      (progn (review-session-return) review-session--current)
    (let* ((records (or (review-store-list) (user-error "No paused review")))
           (record (if pick
                       (let* ((cands (mapcar (lambda (r) (cons (review-store--describe r) r)) records))
                              (choice (completing-read "Resume review: " cands nil t)))
                         (cdr (assoc choice cands)))
                     (car records))))
      (when review-session--current (review-session-pause))
      (review-store-restore record))))

;;;; Quit and autosave

(defun review-store--on-quit (session)
  (unless (or review-session--pausing review-session-keep-on-quit)
    (when-let ((recipe (review-source-recipe (review-session-source session))))
      (review-store-drop (review-source-key recipe)))))

(defun review-store--autosave ()
  (when-let ((s review-session--current))
    (when (review-source-recipe (review-session-source s))
      (condition-case err (review-store-save s)
        (error (message "Review: autosave failed: %s" (error-message-string err)))))))

(defun review-store--on-update (session)
  (when (and session (not (timerp review-store--timer)) (> review-store-autosave-interval 0))
    (setq review-store--timer (run-with-timer review-store-autosave-interval
                                              review-store-autosave-interval
                                              #'review-store--autosave))))

(add-hook 'review-session-quit-functions #'review-store--on-quit)
(add-hook 'review-session-update-hook #'review-store--on-update)
(add-hook 'kill-emacs-hook #'review-store--autosave)

(provide 'review-store)
;;; review-store.el ends here
