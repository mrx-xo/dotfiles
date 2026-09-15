;;; mr-x-crash-bundle.el --- Immutable crash bundles and recovery state -*- lexical-binding: t; -*-

;;; Commentary:
;; The bundle store below `crash-state/' holds one immutable directory per
;; unclean daemon run plus an atomic `active.el' pointer to the newest pending
;; bundle.  Loading is inert.  The startup caller scans prior runs of its own
;; server and init directory: clean runs are marked processed, unclean runs are
;; bundled exactly once, and the source run keeps a `processed.el' marker so an
;; interrupted bundling attempt is finished idempotently rather than repeated.
;;
;; Evidence inside a committed bundle is never modified.  Only
;; `restore-status.el' changes, through explicit legal transitions.  Terminal
;; bundles are removed pointer-first, so a failed deletion leaves a bundle that
;; the next startup finishes cleaning.  A flat legacy `crash-state/' snapshot
;; is reported but never rewritten, migrated, or deleted here.
;;
;; Frame reconstruction, yabai placement, native-report correlation, and the
;; review UI are separate; this library owns storage and phase bookkeeping.

;;; Code:

(require 'cl-lib)
(require 'mr-x-crash-diagnostics)

(defconst mr-x/crash-bundle--transitions
  '((pending-frames restoring-frames discarded)
    (restoring-frames pending-yabai cleanup-pending pending-frames)
    (cleanup-pending pending-frames discarded)
    (pending-yabai placing-yabai complete discarded)
    (placing-yabai complete pending-yabai discarded)
    (review-only discarded)
    (complete)
    (discarded))
  "Legal recovery phases and the phases each may move to.")

(defconst mr-x/crash-bundle--cancel-only
  '((cleanup-pending . discarded) (placing-yabai . discarded))
  "Transitions allowed only after :cancel-requested was recorded.")

(defconst mr-x/crash-bundle--terminal '(complete discarded))
(defconst mr-x/crash-bundle--idle '(review-only pending-frames pending-yabai)
  "Phases in which no worker owns the bundle, so a user may discard it.")
(defconst mr-x/crash-bundle--fields
  '(:owner :attempt :restored-frames :residual-resources :cancel-requested :last-error)
  "Status fields a transition may update.")
(defconst mr-x/crash-bundle--evidence
  '("recent-messages.log" "command-errors.log" "command-errors.log.1"
    "daemon-stderr.log" "daemon-stderr.log.1" "stderr-status.json")
  "Run diagnostics copied byte for byte into a bundle when present.")

(defun mr-x/crash-bundle--id-p (value)
  "Whether VALUE is a bundle basename with no path components."
  (and (stringp value) (string-match-p "\\`bundle-[[:alnum:]-]+\\'" value)))

(defun mr-x/crash-bundle-store (init-directory)
  "Return the private bundle store below INIT-DIRECTORY, creating it."
  (let* ((store (expand-file-name "crash-state/" (file-name-as-directory init-directory)))
         (bundles (expand-file-name "bundles/" store)))
    (dolist (directory (list store bundles))
      (unless (file-exists-p directory) (make-directory directory))
      (mr-x/crash-capture--directory (directory-file-name directory))
      (set-file-modes directory #o700))
    store))

(defun mr-x/crash-bundle-directory (store id)
  "Return the path of bundle ID below STORE without requiring it to exist."
  (unless (mr-x/crash-bundle--id-p id)
    (mr-x/crash-capture--invalid "Invalid bundle ID"))
  (expand-file-name id (expand-file-name "bundles" store)))

(defun mr-x/crash-bundle-legacy-p (store)
  "Whether STORE still holds the flat legacy snapshot.  It is left untouched."
  (file-exists-p (expand-file-name "session-state.el" store)))

;;; Status

(defun mr-x/crash-bundle--status-file (bundle)
  (expand-file-name "restore-status.el" bundle))

(defun mr-x/crash-bundle-status (bundle)
  "Read and validate BUNDLE's restore status without evaluating data."
  (let ((data (mr-x/crash-capture--read (mr-x/crash-bundle--status-file bundle))))
    (unless (and (equal (plist-get data :schema-version) 1)
                 (mr-x/crash-bundle--id-p (plist-get data :bundle-id))
                 (assq (plist-get data :phase) mr-x/crash-bundle--transitions)
                 (natnump (plist-get data :attempt))
                 (numberp (plist-get data :updated-at)))
      (mr-x/crash-capture--invalid "Invalid restore status"))
    data))

(defun mr-x/crash-bundle--write-status (bundle status)
  (mr-x/crash-capture--write (mr-x/crash-bundle--status-file bundle)
                             (plist-put (copy-sequence status) :updated-at (float-time))))

(defun mr-x/crash-bundle-transition (bundle from to &rest updates)
  "Atomically move BUNDLE's status from phase FROM to TO, applying UPDATES.
FROM must be the current phase.  TO equal to FROM updates fields in place in a
nonterminal phase.  Discarding from `cleanup-pending' or `placing-yabai'
requires a previously recorded :cancel-requested.  Illegal moves signal and
leave the file unchanged.  Return the new status."
  (let* ((status (copy-sequence (mr-x/crash-bundle-status bundle)))
         (phase (plist-get status :phase)))
    (unless (and (eq phase from)
                 (or (and (eq to from) (not (memq from mr-x/crash-bundle--terminal)))
                     (memq to (cdr (assq from mr-x/crash-bundle--transitions))))
                 (or (not (member (cons from to) mr-x/crash-bundle--cancel-only))
                     (plist-get status :cancel-requested)))
      (mr-x/crash-capture--invalid "Illegal recovery transition %s -> %s in phase %s"
                                   from to phase))
    (while updates
      (let ((key (pop updates)) (value (pop updates)))
        (unless (memq key mr-x/crash-bundle--fields)
          (mr-x/crash-capture--invalid "Unknown status field %s" key))
        (setq status (plist-put status key value))))
    (setq status (plist-put status :phase to))
    (mr-x/crash-bundle--write-status bundle status)
    status))

;;; Store queries

(defun mr-x/crash-bundle--entries (store)
  "Return (ID . STATUS) for every valid bundle, newest source run first."
  (let ((bundles (expand-file-name "bundles" store)) entries)
    (dolist (name (directory-files bundles nil "\\`bundle-"))
      (condition-case nil
          (let ((status (mr-x/crash-bundle-status (expand-file-name name bundles))))
            (when (equal name (plist-get status :bundle-id))
              (push (cons name status) entries)))
        (error nil)))
    (sort entries (lambda (a b)
                    (> (or (plist-get (plist-get (cdr a) :source-run) :started-at) 0)
                       (or (plist-get (plist-get (cdr b) :source-run) :started-at) 0))))))

(defun mr-x/crash-bundle-pending (store)
  "Return (ID . STATUS) for nonterminal bundles in STORE, newest first."
  (cl-remove-if (lambda (entry)
                  (memq (plist-get (cdr entry) :phase) mr-x/crash-bundle--terminal))
                (mr-x/crash-bundle--entries store)))

(defun mr-x/crash-bundle--pointer (store)
  (expand-file-name "active.el" store))

(defun mr-x/crash-bundle--write-pointer (store id)
  (mr-x/crash-capture--write (mr-x/crash-bundle--pointer store)
                             (list :schema-version 1 :bundle-id id)))

(defun mr-x/crash-bundle--clear-pointer (store)
  (let ((pointer (mr-x/crash-bundle--pointer store)))
    (when (or (file-exists-p pointer) (file-symlink-p pointer))
      (delete-file pointer))))

(defun mr-x/crash-bundle-active (store)
  "Return the active pending bundle ID, repairing a stale or missing pointer."
  (let* ((pending (mr-x/crash-bundle-pending store))
         (recorded (condition-case nil
                       (let ((data (mr-x/crash-capture--read (mr-x/crash-bundle--pointer store))))
                         (and (equal (plist-get data :schema-version) 1)
                              (plist-get data :bundle-id)))
                     (error nil)))
         (newest (caar pending)))
    (cond ((and recorded (assoc recorded pending)) recorded)
          (newest (mr-x/crash-bundle--write-pointer store newest) newest)
          (t (mr-x/crash-bundle--clear-pointer store) nil))))

(defun mr-x/crash-bundle--advance (store id)
  "Point past ID at the newest other pending bundle, or clear the pointer."
  (let ((next (caar (cl-remove-if (lambda (entry) (equal (car entry) id))
                                  (mr-x/crash-bundle-pending store)))))
    (if next (mr-x/crash-bundle--write-pointer store next)
      (mr-x/crash-bundle--clear-pointer store))
    next))

(defun mr-x/crash-bundle--remove (store id)
  "Advance the pointer past ID, then delete its directory, in that order."
  (mr-x/crash-bundle--advance store id)
  (delete-directory (mr-x/crash-bundle-directory store id) t))

(defun mr-x/crash-bundle-discard (store id)
  "Discard idle bundle ID: terminal status, then pointer, then files."
  (let* ((bundle (mr-x/crash-bundle-directory store id))
         (phase (plist-get (mr-x/crash-bundle-status bundle) :phase)))
    (unless (memq phase mr-x/crash-bundle--idle)
      (mr-x/crash-capture--invalid "Cannot discard a bundle in phase %s" phase))
    (mr-x/crash-bundle-transition bundle phase 'discarded)
    (mr-x/crash-bundle--remove store id)))

(defun mr-x/crash-bundle-consume (store id)
  "Remove bundle ID after recovery committed `complete'."
  (let ((bundle (mr-x/crash-bundle-directory store id)))
    (unless (eq 'complete (plist-get (mr-x/crash-bundle-status bundle) :phase))
      (mr-x/crash-capture--invalid "Only a complete bundle can be consumed"))
    (mr-x/crash-bundle--remove store id)))

;;; Creation

(defun mr-x/crash-bundle--tail (path limit)
  "Bounded tail of ordinary file PATH, or a note when it was not recorded."
  (if (file-exists-p path)
      (mr-x/crash-diagnostics--bounded (mr-x/crash-capture--text path) limit t)
    "(no evidence recorded)\n"))

(defun mr-x/crash-bundle--report (id run data capture note)
  "Return the combined report text for bundle ID from RUN metadata DATA."
  (let ((stamp (lambda (time)
                 (if (numberp time) (format-time-string "%FT%T%z" time) "none")))
        (pid (plist-get data :pid)))
    (concat
     (format ";; crash bundle %s\n;; source run %s, server %s, init %s\n"
             id (plist-get data :run-id) (plist-get data :server)
             (plist-get data :init-directory))
     (format ";; started %s, initialized %s\n"
             (funcall stamp (plist-get data :started-at))
             (funcall stamp (plist-get data :initialized-at)))
     (if pid (format ";; emacs pid %d\n" pid)
       ";; emacs pid unknown: the run ended before recording it (process correlation incomplete)\n")
     (format ";; session capture: %s\n"
             (cond (capture (plist-get capture :capture-id))
                   (note (format "unusable (%s); diagnostics only, not restorable" note))
                   (t "none; diagnostics only, not restorable")))
     ";; each source below is labeled separately; no causal link between them is asserted\n\n"
     "== macOS crash report ==\nnot correlated: native report correlation is not implemented yet\n\n"
     "== latest command errors (tail) ==\n"
     (mr-x/crash-bundle--tail (expand-file-name "command-errors.log" run) (* 64 1024))
     "\n\n== recent messages (tail) ==\n"
     (mr-x/crash-bundle--tail (expand-file-name "recent-messages.log" run) (* 64 1024))
     "\n\n== daemon stderr (tail) ==\n"
     (mr-x/crash-bundle--tail (expand-file-name "daemon-stderr.log" run) (* 256 1024))
     "\n")))

(defun mr-x/crash-bundle--copy (source destination)
  "Copy ordinary SOURCE to DESTINATION privately; return (NAME . SHA256) or nil."
  (when (and (file-regular-p source) (not (file-symlink-p source)))
    (copy-file source destination)
    (set-file-modes destination #o600)
    (cons (file-name-nondirectory destination) (mr-x/crash-capture--digest source))))

(defun mr-x/crash-bundle-create (store run-directory)
  "Create an immutable bundle from unclean RUN-DIRECTORY and return its ID.
An existing bundle for the same source run is returned unchanged.  Evidence
is written to a sibling temporary directory and renamed into place once."
  (let* ((run (mr-x/crash-run--root run-directory))
         (data (mr-x/crash-run-metadata run))
         (id (concat "bundle-" (plist-get data :run-id)))
         (bundle (mr-x/crash-bundle-directory store id))
         (bundles (file-name-directory (directory-file-name bundle))))
    (if (or (file-exists-p bundle) (file-symlink-p bundle))
        id
      (let* ((note nil)
             (capture (when (plist-get data :pid)
                        (condition-case err (mr-x/crash-capture-current run)
                          (error (setq note (error-message-string err)) nil))))
             (temporary (make-temp-file (expand-file-name ".bundle-" bundles) t))
             (files nil))
        (unwind-protect
            (progn
              (set-file-modes temporary #o700)
              (dolist (name mr-x/crash-bundle--evidence)
                (let ((entry (mr-x/crash-bundle--copy (expand-file-name name run)
                                                      (expand-file-name name temporary))))
                  (when entry (push entry files))))
              (when capture
                (dolist (name '("session-state.el" "yabai-state.json"))
                  (let ((entry (mr-x/crash-bundle--copy
                                (expand-file-name name (plist-get capture :directory))
                                (expand-file-name name temporary))))
                    (when entry (push entry files)))))
              (mr-x/crash-capture--write (expand-file-name "report.log" temporary)
                                         (mr-x/crash-bundle--report id run data capture note) t)
              (mr-x/crash-capture--write
               (expand-file-name "manifest.el" temporary)
               (list :schema-version 1 :bundle-id id :source-run data
                     :capture-id (plist-get capture :capture-id)
                     :created-at (float-time) :files (nreverse files)))
              (mr-x/crash-capture--write
               (expand-file-name "restore-status.el" temporary)
               (list :schema-version 1 :bundle-id id
                     :source-run (list :id (plist-get data :run-id) :pid (plist-get data :pid)
                                       :server (plist-get data :server)
                                       :user-emacs-directory (plist-get data :init-directory)
                                       :started-at (plist-get data :started-at)
                                       :initialized-at (plist-get data :initialized-at))
                     :phase (if capture 'pending-frames 'review-only)
                     :attempt 0 :owner nil
                     :requested-frame-count
                     (length (plist-get (plist-get capture :manifest) :frame-keys))
                     :restored-frames nil :residual-resources nil :cancel-requested nil
                     :yabai-required (and capture
                                          (eq 'required (plist-get (plist-get capture :manifest)
                                                                   :placement-mode))
                                          t)
                     :last-error nil :updated-at (float-time)))
              (rename-file temporary bundle))
          (when (file-directory-p temporary) (delete-directory temporary t)))
        id))))

;;; Startup processing

(defun mr-x/crash-bundle--cleanup (store)
  "Remove abandoned temporary bundles and unreferenced terminal bundles."
  (let ((bundles (expand-file-name "bundles" store)))
    (dolist (name (directory-files bundles nil "\\`\\.bundle-"))
      (delete-directory (expand-file-name name bundles) t))
    (dolist (entry (mr-x/crash-bundle--entries store))
      (when (memq (plist-get (cdr entry) :phase) mr-x/crash-bundle--terminal)
        (mr-x/crash-bundle--remove store (car entry))))))

(defun mr-x/crash-bundle-process (init-directory server &optional current-run-id)
  "Bundle unclean unprocessed runs of SERVER under INIT-DIRECTORY.
CURRENT-RUN-ID, the live run, is never processed.  Clean runs receive a
processed marker without a bundle.  Return a plist with :bundled (new IDs),
:processed (count), :active, and :warnings; failures never stop the scan."
  (let* ((init (file-name-as-directory (file-truename (expand-file-name init-directory))))
         (store (mr-x/crash-bundle-store init))
         (runs (expand-file-name "var/crash-recovery/runs/" init))
         (bundled nil) (processed 0) (warnings nil))
    (when (file-directory-p runs)
      (dolist (name (directory-files runs nil "\\`run-"))
        (let ((run (expand-file-name name runs)))
          (unless (or (equal name current-run-id)
                      (file-exists-p (expand-file-name "processed.el" run)))
            (condition-case err
                (let ((data (mr-x/crash-run-metadata run)))
                  (when (and (equal (plist-get data :server) server)
                             (equal (file-truename (plist-get data :init-directory)) init))
                    (let ((id nil))
                      (unless (mr-x/crash-run-clean-p run)
                        (let ((existing (file-exists-p
                                         (mr-x/crash-bundle-directory store (concat "bundle-" name)))))
                          (setq id (mr-x/crash-bundle-create store run))
                          (unless existing (push id bundled))))
                      (mr-x/crash-capture--write
                       (expand-file-name "processed.el" run)
                       (list :schema-version 1 :run-id name :bundle-id id
                             :processed-at (float-time)))
                      (cl-incf processed))))
              (error (push (format "%s: %s" name (error-message-string err)) warnings)))))))
    (condition-case err (mr-x/crash-bundle--cleanup store)
      (error (push (error-message-string err) warnings)))
    (when bundled (mr-x/crash-bundle--clear-pointer store))
    (list :bundled (nreverse bundled) :processed processed
          :active (mr-x/crash-bundle-active store) :warnings (nreverse warnings))))

(provide 'mr-x-crash-bundle)
;;; mr-x-crash-bundle.el ends here
