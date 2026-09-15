;;; mr-x-crash-capture.el --- Coherent session capture store -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit, local storage for one daemon run.  Loading this library installs
;; no hooks or timers and reads/writes no runtime state.  The caller supplies
;; the run directory, run identity, and capture providers.
;;
;; Each capture commits its session, optional placement, and manifest together.
;; Only an atomic capture-current.el replacement publishes a generation.  The
;; current and previous generations survive; incomplete captures never become
;; recovery evidence.  Same-process reentrant saves skip instead of overlapping.
;; A run directory belongs to one immutable daemon identity.  A restarted
;; daemon must receive a new directory.  Invalid existing evidence fails closed
;; rather than being silently replaced.  This is not an inter-process lock or
;; a frame/restore implementation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(define-error 'mr-x/crash-capture-invalid "Invalid crash capture")

(defvar mr-x/crash-capture--busy (make-hash-table :test #'equal)
  "Canonical run directories with an active save in this process.")

(defun mr-x/crash-capture--invalid (format-string &rest args)
  "Signal a capture validation error using FORMAT-STRING and ARGS."
  (signal 'mr-x/crash-capture-invalid
          (list (apply #'format format-string args))))

(defun mr-x/crash-capture--id-p (value)
  "Whether VALUE is a generated capture basename, with no path components."
  (and (stringp value)
       (string-match-p "\\`capture-[[:alnum:]]+\\'" value)))

(defun mr-x/crash-capture--root (directory)
  "Return canonical local DIRECTORY; never create it implicitly."
  (unless (and (stringp directory) (not (file-remote-p directory))
               (file-directory-p directory))
    (mr-x/crash-capture--invalid "Run directory must exist locally"))
  (file-name-as-directory (file-truename directory)))

(defun mr-x/crash-capture--directory (path)
  "Verify PATH is an ordinary directory, not a symlink."
  (unless (and (not (file-symlink-p path)) (file-directory-p path))
    (mr-x/crash-capture--invalid "Not an ordinary directory: %s" path))
  path)

(defun mr-x/crash-capture--text (path)
  "Read UTF-8 text from ordinary file PATH without evaluating it."
  (unless (and (not (file-symlink-p path)) (file-regular-p path))
    (mr-x/crash-capture--invalid "Not an ordinary file: %s" path))
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents path))
    (buffer-string)))

(defun mr-x/crash-capture--read (path)
  "Read exactly one Lisp data form from PATH; reject trailing forms."
  (condition-case err
      (with-temp-buffer
        (insert (mr-x/crash-capture--text path))
        (goto-char (point-min))
        (let ((value (read (current-buffer))))
          (skip-chars-forward " \t\r\n")
          (unless (eobp)
            (mr-x/crash-capture--invalid "Trailing data in %s" path))
          value))
    (error (mr-x/crash-capture--invalid "Cannot read %s: %s"
                                        path (error-message-string err)))))

(defun mr-x/crash-capture--digest (path)
  "SHA-256 of the exact bytes in ordinary file PATH."
  (unless (and (not (file-symlink-p path)) (file-regular-p path))
    (mr-x/crash-capture--invalid "Not an ordinary file: %s" path))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun mr-x/crash-capture--write (path value &optional textp)
  "Atomically write VALUE at PATH, as UTF-8 text when TEXTP is non-nil.
Temporary files are beside PATH and are private before contents are written."
  (let ((temporary (make-temp-file
                    (expand-file-name ".write-" (file-name-directory path)))))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix)
              (print-length nil) (print-level nil) (print-circle t)
              (write-region-annotate-functions nil)
              (write-region-post-annotation-function nil))
          (set-file-modes temporary #o600)
          (write-region (if textp value (concat (prin1-to-string value) "\n"))
                        nil temporary nil 'silent)
          (rename-file temporary path t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun mr-x/crash-capture--identity (identity)
  "Validate and normalize daemon IDENTITY into stable comparison order."
  (unless (and (proper-list-p identity)
               (stringp (plist-get identity :run-id))
               (not (string-empty-p (plist-get identity :run-id)))
               (integerp (plist-get identity :pid))
               (> (plist-get identity :pid) 0)
               (stringp (plist-get identity :server))
               (not (string-empty-p (plist-get identity :server)))
               (stringp (plist-get identity :init-directory))
               (file-name-absolute-p (plist-get identity :init-directory))
               (not (file-remote-p (plist-get identity :init-directory))))
    (mr-x/crash-capture--invalid "Malformed run identity"))
  (list :run-id (plist-get identity :run-id) :pid (plist-get identity :pid)
        :server (plist-get identity :server)
        :init-directory (file-name-as-directory
                         (expand-file-name (plist-get identity :init-directory)))))

(defun mr-x/crash-capture--keys (keys)
  "Validate KEYS as a list of unique, nonempty frame-key strings."
  (unless (and (proper-list-p keys)
               (cl-every (lambda (key) (and (stringp key) (not (string-empty-p key))))
                         keys)
               (= (length keys) (length (delete-dups (copy-sequence keys)))))
    (mr-x/crash-capture--invalid "Frame keys must be unique nonempty strings"))
  keys)

(defun mr-x/crash-capture--session-keys (session)
  "Validate SESSION's frame records and return their restore keys."
  (unless (and (proper-list-p session)
               (cl-every (lambda (frame)
                           (and (proper-list-p frame)
                                (plist-member frame :window-tree)))
                         session))
    (mr-x/crash-capture--invalid "Malformed serialized frame list"))
  (mr-x/crash-capture--keys
   (mapcar (lambda (frame) (plist-get frame :restore-key)) session)))

(defun mr-x/crash-capture--same-keys-p (first second)
  "Compare validated key lists FIRST and SECOND without changing their order."
  (equal (sort (copy-sequence (mr-x/crash-capture--keys first)) #'string<)
         (sort (copy-sequence (mr-x/crash-capture--keys second)) #'string<)))

(defun mr-x/crash-capture--placement (text identity keys)
  "Validate placement JSON TEXT against IDENTITY and eligible frame KEYS."
  (condition-case err
      (let* ((data (json-parse-string text :object-type 'alist :array-type 'list
                                      :null-object nil :false-object :false))
             (frames (alist-get 'frames data))
             (ids (mapcar (lambda (frame) (alist-get 'old_window_id frame)) frames)))
        (unless (and (equal (alist-get 'schema_version data) 1)
                     (equal (alist-get 'source_pid data) (plist-get identity :pid))
                     (equal (alist-get 'source_run data) (plist-get identity :run-id))
                     (proper-list-p frames)
                     (mr-x/crash-capture--same-keys-p
                      keys (mapcar (lambda (frame) (alist-get 'restore_key frame)) frames))
                     (cl-every (lambda (id) (and (integerp id) (> id 0))) ids)
                     (= (length ids) (length (delete-dups (copy-sequence ids)))))
          (mr-x/crash-capture--invalid "Placement identity, keys, or IDs mismatch"))
        (dolist (frame frames)
          (dolist (field '(space display))
            (let ((value (alist-get field frame)))
              (unless (and (integerp value) (> value 0))
                (mr-x/crash-capture--invalid "Invalid placement %s" field)))))
        text)
    (error (mr-x/crash-capture--invalid "Invalid placement: %s"
                                        (error-message-string err)))))

(defun mr-x/crash-capture--generation (root id &optional identity)
  "Read and validate generation ID below ROOT, optionally matching IDENTITY."
  (unless (mr-x/crash-capture--id-p id)
    (mr-x/crash-capture--invalid "Invalid capture ID"))
  (let* ((captures (mr-x/crash-capture--directory (expand-file-name "captures" root)))
         (directory (mr-x/crash-capture--directory (expand-file-name id captures)))
         (manifest (mr-x/crash-capture--read (expand-file-name "manifest.el" directory)))
         (session (expand-file-name "session-state.el" directory))
         (placement (expand-file-name "yabai-state.json" directory))
         (source (mr-x/crash-capture--identity (plist-get manifest :source-run)))
         (keys (mr-x/crash-capture--keys (plist-get manifest :frame-keys))))
    (unless (and (equal (plist-get manifest :schema-version) 1)
                 (equal (plist-get manifest :capture-id) id)
                 keys
                 (or (null identity)
                     (equal source (mr-x/crash-capture--identity identity)))
                 (equal (plist-get manifest :session-sha256)
                        (mr-x/crash-capture--digest session))
                 (equal keys (mr-x/crash-capture--session-keys
                              (mr-x/crash-capture--read session))))
      (mr-x/crash-capture--invalid "Capture manifest/session mismatch"))
    (pcase (plist-get manifest :placement-mode)
      ('required
       (unless (equal (plist-get manifest :placement-sha256)
                      (mr-x/crash-capture--digest placement))
         (mr-x/crash-capture--invalid "Placement digest mismatch"))
       (mr-x/crash-capture--placement (mr-x/crash-capture--text placement) source keys))
      ('not-requested
       (when (or (file-exists-p placement) (file-symlink-p placement)
                 (plist-get manifest :placement-sha256))
         (mr-x/crash-capture--invalid "Unexpected placement in frame-only capture")))
      (_ (mr-x/crash-capture--invalid "Missing explicit placement mode")))
    (list :capture-id id :directory directory :manifest manifest)))

(defun mr-x/crash-capture-current (run-directory &optional identity)
  "Return the published capture in RUN-DIRECTORY, or nil before first commit.
Validate hashes, structure, ownership, and optional expected IDENTITY.  Never
infer a current capture from timestamps or unreferenced generation directories."
  (let* ((root (mr-x/crash-capture--root run-directory))
         (pointer (expand-file-name "capture-current.el" root)))
    (when (or (file-exists-p pointer) (file-symlink-p pointer))
      (let ((data (mr-x/crash-capture--read pointer)))
        (unless (and (equal (plist-get data :schema-version) 1)
                     (or (null (plist-get data :previous-id))
                         (mr-x/crash-capture--id-p (plist-get data :previous-id))))
          (mr-x/crash-capture--invalid "Malformed capture pointer"))
        (mr-x/crash-capture--generation root (plist-get data :capture-id) identity)))))

(defun mr-x/crash-capture--prune (root current previous identity)
  "Prune older valid generations in ROOT, retaining CURRENT and PREVIOUS.
Only remove ordinary generations with validated matching IDENTITY.  Return
warnings rather than disguising a successful pointer commit as a failed save."
  (let ((captures (expand-file-name "captures" root)) warnings)
    (condition-case err
        (dolist (name (directory-files captures nil "\\`capture-"))
          (unless (member name (list current previous))
            (condition-case err
                (let ((generation (mr-x/crash-capture--generation root name identity)))
                  (delete-directory (plist-get generation :directory) t))
              (error (push (error-message-string err) warnings)))))
      (error (push (error-message-string err) warnings)))
    (nreverse warnings)))

(defun mr-x/crash-capture-save (run-directory identity session-function
                                              placement-function &optional keys-function)
  "Commit one coherent capture in existing local RUN-DIRECTORY for IDENTITY.
IDENTITY must remain unchanged for the lifetime of RUN-DIRECTORY.  Allocate a
new run directory after a daemon restart; never reuse one with a different PID.
SESSION-FUNCTION returns serialized frames with unique :restore-key fields.
PLACEMENT-FUNCTION receives a copy of the frames and returns versioned JSON;
nil explicitly requests frame-only capture.  Optional KEYS-FUNCTION returns
the current eligible frame keys after capture, to detect eligibility changes.

Return a plist with :status `committed', :capture-id, and :directory.  An empty
session or overlapping invocation returns :status `skipped' and :reason.  All
pre-commit failures signal and leave the previous published pair intact.
Post-commit pruning failures appear in :warnings; they do not undo a commit."
  (let* ((root (mr-x/crash-capture--root run-directory))
         (source (mr-x/crash-capture--identity identity)))
    (if (gethash root mr-x/crash-capture--busy)
        '(:status skipped :reason busy)
      (puthash root t mr-x/crash-capture--busy)
      (unwind-protect
          (let* ((old (mr-x/crash-capture-current root source))
                 (session (funcall session-function))
                 (keys (mr-x/crash-capture--session-keys session)))
            (if (null keys)
                '(:status skipped :reason empty)
              (setq session (copy-tree session))
              (set-file-modes root #o700)
              (let ((captures (expand-file-name "captures" root)))
                (unless (file-exists-p captures) (make-directory captures))
                (mr-x/crash-capture--directory captures)
                (set-file-modes captures #o700)
                (let* ((temporary (make-temp-file (expand-file-name ".capture-" captures) t))
                       (id (substring (file-name-nondirectory temporary) 1))
                       (directory (expand-file-name id captures))
                       (previous (plist-get old :capture-id)))
                  (unwind-protect
                      (progn
                        (set-file-modes temporary #o700)
                        (mr-x/crash-capture--write
                         (expand-file-name "session-state.el" temporary) session)
                        (when placement-function
                          (mr-x/crash-capture--write
                           (expand-file-name "yabai-state.json" temporary)
                           (mr-x/crash-capture--placement
                            (funcall placement-function (copy-tree session)) source keys) t))
                        (when (and keys-function
                                   (not (mr-x/crash-capture--same-keys-p
                                         keys (funcall keys-function))))
                          (mr-x/crash-capture--invalid "Eligible frame set changed"))
                        (mr-x/crash-capture--write
                         (expand-file-name "manifest.el" temporary)
                         (list :schema-version 1 :capture-id id :source-run source
                               :captured-at (float-time) :frame-keys keys
                               :placement-mode (if placement-function 'required 'not-requested)
                               :session-sha256 (mr-x/crash-capture--digest
                                                (expand-file-name "session-state.el" temporary))
                               :placement-sha256 (when placement-function
                                                   (mr-x/crash-capture--digest
                                                    (expand-file-name "yabai-state.json" temporary)))))
                        (rename-file temporary directory)
                        (mr-x/crash-capture--write
                         (expand-file-name "capture-current.el" root)
                         (list :schema-version 1 :capture-id id :previous-id previous))
                        (let ((result (list :status 'committed :capture-id id :directory directory))
                              (warnings (mr-x/crash-capture--prune root id previous source)))
                          (if warnings (append result (list :warnings warnings)) result)))
                    ;; Once renamed, a generation may already be published even
                    ;; if a quit/error interrupted the pointer writer's return.
                    ;; Never delete it here.  A later successful save can prune
                    ;; validated orphans; readers only follow the pointer.
                    (when (file-directory-p temporary)
                      (delete-directory temporary t)))))))
        (remhash root mr-x/crash-capture--busy)))))

(provide 'mr-x-crash-capture)
;;; mr-x-crash-capture.el ends here
