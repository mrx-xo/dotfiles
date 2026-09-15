;;; mr-x-crash-diagnostics.el --- Explicit run diagnostics -*- lexical-binding: t; -*-

;;; Commentary:
;; Inert storage primitives for startup and shutdown callers.  Loading this
;; library does not install hooks, change command-error-function, or do I/O.
;; The startup caller must allocate a new run before initializing its daemon;
;; it can do so in a separate batch process.  Initialization attaches the PID
;; once.  No source runs are pruned here.  Stderr transport, startup wiring,
;; bundle processing, and native-report correlation are separate integration.
;;
;; One process owns a run's metadata and each log.  Rotation is bounded but
;; not a transaction across two files: interruption can duplicate the last
;; current log in the previous slot, preserving evidence.  This is not a
;; multiprocess logging API.  Reuse the capture store's private atomic writer
;; and data reader so permissions and serialization have one implementation.

;;; Code:

(require 'mr-x-crash-capture)

(defvar mr-x/crash-diagnostics--log-limit (* 2 1024 1024)
  "Maximum bytes in each of the current and previous command logs.")
(defvar mr-x/crash-diagnostics--record-limit (* 64 1024)
  "Maximum bytes in one command error record.")
(defvar mr-x/crash-diagnostics--logging nil
  "Non-nil while a command error wrapper is gathering diagnostic evidence.")

(defun mr-x/crash-run--root (directory)
  "Validate existing ordinary local run DIRECTORY and return canonical path."
  (when (or (not (stringp directory)) (file-remote-p directory))
    (mr-x/crash-capture--invalid "Run directory must be local"))
  (mr-x/crash-capture--directory (directory-file-name directory))
  (mr-x/crash-capture--root directory))

(defun mr-x/crash-run-create (runs-directory server init-directory)
  "Allocate and return a private run below existing RUNS-DIRECTORY.
Record SERVER and absolute local INIT-DIRECTORY before daemon startup.
Never reuse a directory, even if startup fails before a PID is recorded."
  (let* ((parent (mr-x/crash-run--root runs-directory))
         (identity (mr-x/crash-capture--identity
                    (list :run-id "pending" :pid 1 :server server
                          :init-directory init-directory))))
    (set-file-modes parent #o700)
    (let* ((run (make-temp-file (expand-file-name "run-" parent) t))
           (id (file-name-nondirectory run)))
      (set-file-modes run #o700)
      (mr-x/crash-capture--write
       (expand-file-name "metadata.el" run)
       (list :schema-version 1 :run-id id :server server
             :init-directory (plist-get identity :init-directory)
             :started-at (float-time) :pid nil :initialized-at nil
             :logs '("recent-messages.log" "command-errors.log" "daemon-stderr.log")))
      run)))

(defun mr-x/crash-run-metadata (run-directory)
  "Read validated metadata for RUN-DIRECTORY without evaluating any data."
  (let* ((root (mr-x/crash-run--root run-directory))
         (data (mr-x/crash-capture--read (expand-file-name "metadata.el" root)))
         (pid (plist-get data :pid))
         (start (plist-get data :started-at))
         (initialized (plist-get data :initialized-at)))
    (mr-x/crash-capture--identity
     (list :run-id (plist-get data :run-id) :pid (or pid 1)
           :server (plist-get data :server)
           :init-directory (plist-get data :init-directory)))
    (unless (and (equal (plist-get data :schema-version) 1)
                 (equal (plist-get data :run-id)
                        (file-name-nondirectory (directory-file-name root)))
                 (numberp start) (> start 0)
                 (if pid (and (numberp initialized) (>= initialized start))
                   (null initialized)))
      (mr-x/crash-capture--invalid "Invalid run metadata"))
    data))

(defun mr-x/crash-run--identity (metadata)
  "Return capture identity from initialized METADATA."
  (mr-x/crash-capture--identity
   (list :run-id (plist-get metadata :run-id) :pid (plist-get metadata :pid)
         :server (plist-get metadata :server)
         :init-directory (plist-get metadata :init-directory))))

(defun mr-x/crash-run-initialized (run-directory pid)
  "Attach PID once to RUN-DIRECTORY and return its capture identity.
Repeating with the same PID is idempotent; changing it is an error."
  (let* ((data (mr-x/crash-run-metadata run-directory))
         (old (plist-get data :pid)))
    (when (and old (not (equal old pid)))
      (mr-x/crash-capture--invalid "Cannot replace a run's PID"))
    (setq data (plist-put data :pid pid))
    (let ((identity (mr-x/crash-run--identity data)))
      (unless old
        (setq data (plist-put data :initialized-at (max (float-time) (plist-get data :started-at))))
        (mr-x/crash-capture--write (expand-file-name "metadata.el" run-directory) data))
      identity)))

(defun mr-x/crash-run-mark-clean (run-directory identity)
  "Write clean-exit evidence only for RUN-DIRECTORY's exact IDENTITY."
  (let ((data (mr-x/crash-run-metadata run-directory)))
    (unless (equal (mr-x/crash-run--identity data)
                   (mr-x/crash-capture--identity identity))
      (mr-x/crash-capture--invalid "Clean exit identity mismatch"))
    (mr-x/crash-capture--write
     (expand-file-name "clean-exit.el" run-directory)
     (list :schema-version 1 :run-id (plist-get data :run-id)
           :pid (plist-get data :pid)
           :exited-at (max (float-time) (plist-get data :initialized-at))))))

(defun mr-x/crash-run-clean-p (run-directory)
  "Whether RUN-DIRECTORY has clean-exit evidence matching its PID and run ID.
Malformed or missing markers never classify a run as clean.  Invalid run
metadata itself remains an error, so callers can report corrupt evidence."
  (let ((data (mr-x/crash-run-metadata run-directory)))
    (and (plist-get data :pid)
         (condition-case nil
             (let* ((marker (mr-x/crash-capture--read
                             (expand-file-name "clean-exit.el" run-directory)))
                    (time (plist-get marker :exited-at)))
               (and (equal (plist-get marker :schema-version) 1)
                    (equal (plist-get marker :run-id) (plist-get data :run-id))
                    (equal (plist-get marker :pid) (plist-get data :pid))
                    (numberp time) (>= time (plist-get data :initialized-at))))
           (error nil)))))

(defun mr-x/crash-diagnostics--bytes (text)
  "Return UTF-8 encoded byte length of TEXT."
  (string-bytes (encode-coding-string text 'utf-8-unix)))

(defun mr-x/crash-diagnostics--bounded (text limit &optional tail)
  "Bound TEXT to LIMIT UTF-8 bytes, retaining head or, with TAIL, tail.
Include a truncation marker within LIMIT and preserve character boundaries."
  (let* ((marker "\n[truncated]\n")
         (budget (- limit (mr-x/crash-diagnostics--bytes marker))))
    (unless (>= budget 0) (error "Diagnostic limit is too small"))
    (if (<= (mr-x/crash-diagnostics--bytes text) limit) text
      (let ((low 0) (high (length text)))
        (while (< low high)
          (let* ((mid (/ (+ low high 1) 2))
                 (part (if tail (substring text (- (length text) mid))
                         (substring text 0 mid))))
            (if (<= (mr-x/crash-diagnostics--bytes part) budget)
                (setq low mid)
              (setq high (1- mid)))))
        (if tail (concat marker (substring text (- (length text) low)))
          (concat (substring text 0 low) marker))))))

(defun mr-x/crash-diagnostics--file (root name)
  "Return safe log path NAME below ROOT, rejecting existing special files."
  (let ((file (expand-file-name name root)))
    (when (or (file-symlink-p file)
              (and (file-exists-p file) (not (file-regular-p file))))
      (mr-x/crash-capture--invalid "Not an ordinary log file"))
    file))

(defun mr-x/crash-diagnostics-messages (run-directory messages)
  "Persist timestamped MESSAGES tail in RUN-DIRECTORY, at most 256 KiB."
  (let* ((root (mr-x/crash-run--root run-directory))
         (file (mr-x/crash-diagnostics--file root "recent-messages.log"))
         (stamp (format-time-string "%FT%T%z\n")))
    (mr-x/crash-capture--write
     file (concat stamp (mr-x/crash-diagnostics--bounded
                         messages (- (* 256 1024) (length stamp)) t)) t)))

(defun mr-x/crash-diagnostics--append (run-directory record)
  "Append bounded RECORD, rotating one previous log in RUN-DIRECTORY."
  (let* ((root (mr-x/crash-run--root run-directory))
         (file (mr-x/crash-diagnostics--file root "command-errors.log"))
         (previous (mr-x/crash-diagnostics--file root "command-errors.log.1"))
         (text (mr-x/crash-diagnostics--bounded
                record (min mr-x/crash-diagnostics--record-limit
                            mr-x/crash-diagnostics--log-limit)))
         (old (if (file-exists-p file) (mr-x/crash-capture--text file) "")))
    (if (> (+ (mr-x/crash-diagnostics--bytes old)
              (mr-x/crash-diagnostics--bytes text)) mr-x/crash-diagnostics--log-limit)
        (progn
          (mr-x/crash-capture--write previous
                                    (mr-x/crash-diagnostics--bounded
                                     old mr-x/crash-diagnostics--log-limit t) t)
          (mr-x/crash-capture--write file text t))
      (mr-x/crash-capture--write file (concat old text) t))))

(defun mr-x/crash-diagnostics-wrapper (run-directory previous)
  "Return an error handler recording in RUN-DIRECTORY then calling PREVIOUS.
The caller explicitly installs the returned function as command-error-function.
PREVIOUS receives the original three arguments exactly once.  Its return value
and signals propagate unchanged; only evidence-gathering failures are ignored."
  (unless (functionp previous) (error "Previous error handler must be callable"))
  (let ((root (mr-x/crash-run--root run-directory)))
    (lambda (data context function)
      (unless mr-x/crash-diagnostics--logging
        (let ((mr-x/crash-diagnostics--logging t))
          (condition-case nil
              (let* ((print-circle t) (print-length 40) (print-level 8)
                     (messages (get-buffer "*Messages*"))
                     (tail (if messages
                               (with-current-buffer messages
                                 (buffer-substring-no-properties
                                  (max (point-min) (- (point-max) 8192)) (point-max)))
                             "")))
                ;; Bound fields separately: a huge error string must not
                ;; crowd the command context and message tail out of a record.
                (mr-x/crash-diagnostics--append
                 root (concat
                       (format-time-string "%FT%T%z\n")
                       ":data " (mr-x/crash-diagnostics--bounded
                                  (prin1-to-string data) (* 32 1024)) "\n"
                       (mapconcat
                        (lambda (field)
                          (concat (symbol-name (car field)) " "
                                  (mr-x/crash-diagnostics--bounded
                                   (prin1-to-string (cdr field)) 4096)))
                        (list (cons :context context) (cons :function function)
                              (cons :this-command this-command)
                              (cons :frame (frame-parameter nil 'name))
                              (cons :buffer (buffer-name))) "\n")
                       "\nRecent messages:\n"
                       (mr-x/crash-diagnostics--bounded tail 8192 t) "\n")))
            ((error quit) nil))))
      (funcall previous data context function))))

(provide 'mr-x-crash-diagnostics)
;;; mr-x-crash-diagnostics.el ends here
