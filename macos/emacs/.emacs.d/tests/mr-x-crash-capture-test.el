;;; mr-x-crash-capture-test.el --- Coherent capture tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'mr-x-crash-capture)

(ert-deftest crash-capture-workspace-is-atomic-and-hashed ()
  (let ((run (make-temp-file "workspace-capture-" t))
        (entries '((:session-id "sid" :agent codex :cwd "/tmp/" :label "test" :anchored t))))
    (unwind-protect
        (let* ((saved (mr-x/crash-capture-save
                       run crash-capture-test--identity #'crash-capture-test--frames nil nil
                       (lambda () entries)))
               (file (expand-file-name "workspace.el" (plist-get saved :directory))))
          (should (equal entries (mr-x/crash-capture--read file)))
          (should (mr-x/crash-capture-current run))
          (let ((before (mr-x/crash-capture--read (expand-file-name "capture-current.el" run))))
            (should-error (mr-x/crash-capture-save
                           run crash-capture-test--identity #'crash-capture-test--frames nil nil
                           (lambda () (error "workspace unavailable"))))
            (should (equal before (mr-x/crash-capture--read (expand-file-name "capture-current.el" run)))))
          (mr-x/crash-capture--write file nil)
          (should-error (mr-x/crash-capture-current run)))
      (delete-directory run t))))

(ert-deftest crash-capture-workspace-only-and-empty-workspace-are-distinct ()
  (let ((run (make-temp-file "workspace-only-" t)))
    (unwind-protect
        (progn
          (should (eq 'committed
                      (plist-get (mr-x/crash-capture-save
                                  run crash-capture-test--identity (lambda () nil) nil nil
                                  (lambda () '((:session-id "sid" :agent codex :cwd "/tmp/")))) :status)))
          (should (mr-x/crash-capture-current run))
          (let ((saved (mr-x/crash-capture-save
                        run crash-capture-test--identity #'crash-capture-test--frames nil nil (lambda () nil))))
            (should (file-exists-p (expand-file-name "workspace.el" (plist-get saved :directory))))))
      (delete-directory run t))))

(defconst crash-capture-test--identity
  '(:run-id "test-run" :pid 123 :server "sandbox"
	    :init-directory "/tmp/capture-test-init/"))

(defun crash-capture-test--frames (&optional key)
  (list (list :restore-key (or key "frame-a")
              :window-tree '(:type leaf :buffer "fixture"))))

(defun crash-capture-test--placement (frames)
  (json-serialize
   (list :schema_version 1 :source_pid 123 :source_run "test-run"
         :frames (vconcat
                  (cl-loop for frame in frames for id from 100
                           collect (list :restore_key (plist-get frame :restore-key)
                                         :old_window_id id :space 1 :display 1))))))

(defmacro crash-capture-test--with-run (&rest body)
  (declare (indent 0) (debug t))
  `(let ((run (file-truename (make-temp-file "crash-capture-test-" t))))
     (unwind-protect (progn ,@body)
       (delete-directory run t))))

(defun crash-capture-test--save (run &optional key)
  (mr-x/crash-capture-save
   run crash-capture-test--identity
   (lambda () (crash-capture-test--frames key))
   #'crash-capture-test--placement))

(defun crash-capture-test--contents (file)
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest crash-capture-commits-one-matching-session-and-placement-pair ()
  (crash-capture-test--with-run
   (let* ((saved (crash-capture-test--save run))
          (current (mr-x/crash-capture-current run crash-capture-test--identity))
          (directory (plist-get current :directory))
          (manifest (plist-get current :manifest)))
     (should (eq (plist-get saved :status) 'committed))
     (should (equal (plist-get saved :capture-id)
                    (plist-get manifest :capture-id)))
     (should (equal (plist-get manifest :frame-keys) '("frame-a")))
     (should (eq (plist-get manifest :placement-mode) 'required))
     (should (equal (read (crash-capture-test--contents
                           (expand-file-name "session-state.el" directory)))
                    (crash-capture-test--frames)))
     (should (equal (crash-capture-test--contents
                     (expand-file-name "yabai-state.json" directory))
                    (crash-capture-test--placement (crash-capture-test--frames)))))))

(ert-deftest crash-capture-placement-failure-keeps-previous-pair ()
  (crash-capture-test--with-run
   (crash-capture-test--save run)
   (let ((before (crash-capture-test--contents
                  (expand-file-name "capture-current.el" run))))
     (should-error
      (mr-x/crash-capture-save
       run crash-capture-test--identity
       (lambda () (crash-capture-test--frames "frame-b"))
       (lambda (_) (error "injected placement failure"))))
     (should (equal before (crash-capture-test--contents
                            (expand-file-name "capture-current.el" run))))
     (should (equal '("frame-a")
                    (plist-get (plist-get (mr-x/crash-capture-current run)
                                          :manifest) :frame-keys))))))

(ert-deftest crash-capture-pointer-failure-keeps-previous-pair-and-unlocks ()
  (crash-capture-test--with-run
   (let* ((old (crash-capture-test--save run))
          (rename (symbol-function 'rename-file)))
     (cl-letf (((symbol-function 'rename-file)
                (lambda (from to &optional ok)
                  (if (equal to (expand-file-name "capture-current.el" run))
                      (error "injected pointer failure")
                    (funcall rename from to ok)))))
       (should-error (crash-capture-test--save run "frame-b")))
     (should (equal (plist-get old :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id)))
     (should (eq 'committed (plist-get (crash-capture-test--save run "frame-c")
                                       :status))))))

(ert-deftest crash-capture-reentrant-save-is-skipped-before-providers-run ()
  (crash-capture-test--with-run
   (let (nested)
     (should
      (eq 'committed
          (plist-get
           (mr-x/crash-capture-save
            run crash-capture-test--identity
            (lambda ()
              (setq nested
                    (mr-x/crash-capture-save
                     (concat run "/./") crash-capture-test--identity
                     (lambda () (ert-fail "nested provider ran")) nil))
              (crash-capture-test--frames))
            #'crash-capture-test--placement)
           :status)))
     (should (equal nested '(:status skipped :reason busy))))))

(ert-deftest crash-capture-frame-only-never-requires-placement ()
  (crash-capture-test--with-run
   (mr-x/crash-capture-save run crash-capture-test--identity
                            #'crash-capture-test--frames nil)
   (let ((current (mr-x/crash-capture-current run)))
     (should (eq 'not-requested
                 (plist-get (plist-get current :manifest) :placement-mode)))
     (should-not (file-exists-p
                  (expand-file-name "yabai-state.json"
                                    (plist-get current :directory)))))))

(ert-deftest crash-capture-empty-session-keeps-previous-capture ()
  (crash-capture-test--with-run
   (let ((old (crash-capture-test--save run)))
     (should (equal '(:status skipped :reason empty)
                    (mr-x/crash-capture-save
                     run crash-capture-test--identity (lambda () nil)
                     (lambda (_) (ert-fail "placement called for empty session")))))
     (should (equal (plist-get old :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id))))))

(ert-deftest crash-capture-eligibility-change-keeps-previous-capture ()
  (crash-capture-test--with-run
   (let ((old (crash-capture-test--save run)))
     (should-error
      (mr-x/crash-capture-save run crash-capture-test--identity
                               #'crash-capture-test--frames
                               #'crash-capture-test--placement
                               (lambda () '("frame-b"))))
     (should (equal (plist-get old :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id))))))

(ert-deftest crash-capture-invalid-placement-never-replaces-current ()
  (crash-capture-test--with-run
   (let ((old (crash-capture-test--save run)))
     (dolist (json '("not json" "null" "{}"
                     "{\"schema_version\":1,\"source_pid\":999,\"source_run\":\"test-run\",\"frames\":[]}"
                     "{\"schema_version\":1,\"source_pid\":123,\"source_run\":\"wrong-run\",\"frames\":[]}"
                     "{\"schema_version\":1,\"source_pid\":123,\"source_run\":\"test-run\",\"frames\":[]}"))
       (should-error
        (mr-x/crash-capture-save run crash-capture-test--identity
                                 #'crash-capture-test--frames (lambda (_) json))))
     (should (equal (plist-get old :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id))))))

(ert-deftest crash-capture-duplicate-keys-and-window-ids-are-rejected ()
  (crash-capture-test--with-run
   (should-error
    (mr-x/crash-capture-save
     run crash-capture-test--identity
     (lambda () (append (crash-capture-test--frames) (crash-capture-test--frames)))
     #'crash-capture-test--placement))
   (should-error
    (mr-x/crash-capture-save
     run crash-capture-test--identity
     (lambda () (append (crash-capture-test--frames "a")
                        (crash-capture-test--frames "b")))
     (lambda (_)
       "{\"schema_version\":1,\"source_pid\":123,\"source_run\":\"test-run\",\"frames\":[{\"restore_key\":\"a\",\"old_window_id\":1,\"space\":1,\"display\":1},{\"restore_key\":\"b\",\"old_window_id\":1,\"space\":1,\"display\":1}]}")))
   (should-not (mr-x/crash-capture-current run))))

(ert-deftest crash-capture-keeps-current-and-previous-complete-generations ()
  (crash-capture-test--with-run
   (let ((first (crash-capture-test--save run "a"))
         (second (crash-capture-test--save run "b"))
         (third (crash-capture-test--save run "c")))
     (should-not (file-exists-p (plist-get first :directory)))
     (should (file-directory-p (plist-get second :directory)))
     (should (file-directory-p (plist-get third :directory)))
     (should (equal (plist-get third :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id))))))

(ert-deftest crash-capture-artifacts-are-private-and-no-incomplete-files-remain ()
  (crash-capture-test--with-run
   (crash-capture-test--save run)
   (should (= #o700 (logand #o777 (file-modes run))))
   (dolist (path (directory-files-recursively run "." t))
     (should (= (if (file-directory-p path) #o700 #o600)
                (logand #o777 (file-modes path)))))
   (should-not (directory-files-recursively run "\\.capture-\\|\\.write-" t))))

(ert-deftest crash-capture-detects-corruption-and-wrong-run-identity ()
  (crash-capture-test--with-run
   (let* ((saved (crash-capture-test--save run))
          (session (expand-file-name "session-state.el"
                                     (plist-get saved :directory))))
     (should-error
      (mr-x/crash-capture-current
       run (plist-put (copy-sequence crash-capture-test--identity) :pid 999)))
     (with-temp-file session (insert "(:modified t)"))
      (should-error (mr-x/crash-capture-current run)))))

(ert-deftest crash-capture-cannot-reuse-a-run-directory-for-another-daemon ()
  (crash-capture-test--with-run
    (let* ((old (crash-capture-test--save run))
           (pointer (crash-capture-test--contents
                     (expand-file-name "capture-current.el" run))))
      (should-error
       (mr-x/crash-capture-save
        run (plist-put (copy-sequence crash-capture-test--identity) :pid 999)
        (lambda () (ert-fail "provider ran for wrong daemon")) nil)
       :type 'mr-x/crash-capture-invalid)
      (should (equal pointer (crash-capture-test--contents
                             (expand-file-name "capture-current.el" run))))
      (should (equal (plist-get old :capture-id)
                     (plist-get (mr-x/crash-capture-current run) :capture-id))))))

(ert-deftest crash-capture-read-rejects-malformed-metadata-with-domain-error ()
  (dolist (value '(5 "garbage" [1 2] (:source-run "garbage")
                    (:schema-version 1 :schema-version 2)))
    (dolist (filename '("manifest.el" "capture-current.el"))
      (crash-capture-test--with-run
        (let* ((saved (crash-capture-test--save run))
               (directory (if (equal filename "manifest.el")
                              (plist-get saved :directory) run)))
          (with-temp-file (expand-file-name filename directory)
            (prin1 value (current-buffer)))
          (should-error (mr-x/crash-capture-current run)
                        :type 'mr-x/crash-capture-invalid))))))

(ert-deftest crash-capture-pointer-cannot-escape-the-run-directory ()
  (crash-capture-test--with-run
   (with-temp-file (expand-file-name "capture-current.el" run)
     (prin1 '(:schema-version 1 :capture-id "../../elsewhere") (current-buffer)))
   (should-error (mr-x/crash-capture-current run)
                 :type 'mr-x/crash-capture-invalid)))

(ert-deftest crash-capture-quit-after-pointer-publish-cannot-delete-current ()
  (crash-capture-test--with-run
   (crash-capture-test--save run)
   (let ((rename (symbol-function 'rename-file)))
     (cl-letf (((symbol-function 'rename-file)
                (lambda (from to &optional overwrite)
                  (prog1 (funcall rename from to overwrite)
                    (when (equal to (expand-file-name "capture-current.el" run))
                      (signal 'quit nil))))))
       (condition-case nil
           (crash-capture-test--save run "new")
         (quit nil)))
     (should (equal '("new")
                    (plist-get (plist-get (mr-x/crash-capture-current run)
                                          :manifest) :frame-keys)))
     (should (eq 'committed (plist-get (crash-capture-test--save run "after")
                                       :status))))))

(ert-deftest crash-capture-pruning-failure-reports-warning-after-commit ()
  (crash-capture-test--with-run
   (let* ((first (crash-capture-test--save run "a"))
          (_second (crash-capture-test--save run "b"))
          (delete (symbol-function 'delete-directory)) result)
     (cl-letf (((symbol-function 'delete-directory)
                (lambda (directory &optional recursive trash)
                  (if (equal directory (plist-get first :directory))
                      (error "injected prune failure")
                    (funcall delete directory recursive trash)))))
       (setq result (crash-capture-test--save run "c")))
     (should (eq (plist-get result :status) 'committed))
     (should (plist-get result :warnings))
     (should (equal '("c")
                    (plist-get (plist-get (mr-x/crash-capture-current run)
                                          :manifest) :frame-keys))))))

(ert-deftest crash-capture-prune-listing-failure-does-not-report-save-failure ()
  (crash-capture-test--with-run
   (let ((listing (symbol-function 'directory-files)) result)
     (cl-letf (((symbol-function 'directory-files)
                (lambda (directory &rest args)
                  (if (equal directory (expand-file-name "captures" run))
                      (error "injected directory-listing failure")
                    (apply listing directory args)))))
       (setq result (crash-capture-test--save run)))
     (should (eq (plist-get result :status) 'committed))
     (should (plist-get result :warnings))
     (should (mr-x/crash-capture-current run)))))

(ert-deftest crash-capture-loading-does-not-install-hooks-timers-or-write-state ()
  (cl-letf (((symbol-function 'write-region)
             (lambda (&rest _) (ert-fail "library load wrote data")))
            ((symbol-function 'make-directory)
             (lambda (&rest _) (ert-fail "library load created directory"))))
    ;; Install stubs before the baseline: native trampoline creation itself
    ;; can start Emacs's unrelated undo boundary timer.
    (let ((timers (copy-sequence timer-list))
          (idle-timers (copy-sequence timer-idle-list))
          (exit-hook (copy-sequence kill-emacs-hook)))
      (load "mr-x-crash-capture" nil t)
      (should (equal timer-list timers))
      (should (equal timer-idle-list idle-timers))
      (should (equal kill-emacs-hook exit-hook)))))

(ert-deftest crash-capture-rejects-symlinked-artifacts-without-touching-target ()
  (crash-capture-test--with-run
   (let ((outside (make-temp-file "capture-outside-" t)))
     (unwind-protect
         (progn
           (make-symbolic-link outside (expand-file-name "captures" run))
           (should-error (crash-capture-test--save run)
                         :type 'mr-x/crash-capture-invalid)
           (should-not (directory-files outside nil "\\`[^.]")))
       (delete-file (expand-file-name "captures" run))
       (delete-directory outside t)))))

(ert-deftest crash-capture-utf8-content-round-trips-with-valid-digests ()
  (crash-capture-test--with-run
   (mr-x/crash-capture-save
    run crash-capture-test--identity
    (lambda () '((:restore-key "cadre-é" :window-tree (:type leaf :buffer "日本語"))))
    #'crash-capture-test--placement)
   (should (equal '("cadre-é")
                  (plist-get (plist-get (mr-x/crash-capture-current run)
                                        :manifest) :frame-keys)))))

(ert-deftest crash-capture-abrupt-exit-before-pointer-keeps-old-generation ()
  (crash-capture-test--with-run
   (let* ((old (crash-capture-test--save run))
          (library (locate-library "mr-x-crash-capture"))
          (form
           `(progn
              (load ,library nil t)
              (let ((original (symbol-function 'rename-file)))
                (fset 'rename-file
                      (lambda (from to &optional overwrite)
                        (when (equal to ,(expand-file-name "capture-current.el" run))
                          (kill-emacs 73))
                        (funcall original from to overwrite)))
                (mr-x/crash-capture-save
                 ,run ',crash-capture-test--identity
                 (lambda () ',(crash-capture-test--frames "new")) nil)))))
     ;; This is a disposable batch process, never a daemon/server request.
     (should (= 73 (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil nil nil "--batch" "-Q" "--eval"
                    (let ((print-length nil) (print-level nil))
                      (prin1-to-string `(eval ',form t))))))
     (should (equal (plist-get old :capture-id)
                    (plist-get (mr-x/crash-capture-current run) :capture-id)))
     (should (eq 'committed (plist-get (crash-capture-test--save run "after")
                                       :status))))))

;;; mr-x-crash-capture-test.el ends here

(ert-deftest crash-capture-deliberately-empty-workspace-replaces-owned-generation ()
  (crash-capture-test--with-run
    (let ((entries '((:session-id "sid" :agent codex :cwd "/tmp/"))))
      (mr-x/crash-capture-save run crash-capture-test--identity (lambda () nil) nil nil (lambda () entries))
      (setq entries nil)
      (should (eq 'committed (plist-get
                             (mr-x/crash-capture-save run crash-capture-test--identity (lambda () nil) nil nil (lambda () entries)) :status)))
      (let* ((saved (mr-x/crash-capture-current run))
             (directory (plist-get saved :directory)))
        (should-not (mr-x/crash-capture--read (expand-file-name "workspace.el" directory)))))))
