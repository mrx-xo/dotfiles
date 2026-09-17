;;; crash-workspace-test.el --- Workspace transaction tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'mr-x-crash-workspace nil t)

(ert-deftest crash-workspace-waits-before-frame-replay ()
  (let ((buf (generate-new-buffer " *recovery-agent*")) callback replayed completed)
    (unwind-protect
        (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
                   (lambda (_entry done)
                     (setq callback done)
                     `((status . "pending") (bufferName . ,(buffer-name buf))
                       (existing . :false) (operation . "op"))))
                  ((symbol-function 'mr-x/crash-restore-frames)
                   (lambda (_session _replay)
                     (setq replayed (mr-x/crash-workspace-buffer 'codex "sid"))
                     '(:status restored :frames nil))))
          (mr-x/crash-workspace-start
           "attempt" '((:agent codex :session-id "sid" :cwd "/tmp/"))
           '((:restore-key "f" :window-tree (:type leaf :restore-spec (agent-shell :agent codex :session-id "sid" :dir "/tmp/"))))
           #'ignore (lambda (r) (setq completed r)))
          (should-not replayed)
          (should-not completed)
          (funcall callback `((ok . t) (status . "ready") (bufferName . ,(buffer-name buf)) (existing . :false)))
          (should (eq replayed buf))
          (should (eq (plist-get completed :status) 'restored)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest crash-workspace-frame-failure-cleans-owned-agent ()
  (let ((buf (generate-new-buffer " *recovery-owned*")) completed)
    (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
               (lambda (_entry done)
                 (funcall done `((ok . t) (status . "ready") (bufferName . ,(buffer-name buf)) (existing . :false)))))
              ((symbol-function 'mr-x/crash-restore-frames)
               (lambda (&rest _) '(:status failed :errors ("missing file") :leaked nil))))
      (unwind-protect
          (progn
            (mr-x/crash-workspace-start
             "attempt" '((:agent codex :session-id "sid" :cwd "/tmp/"))
             '((:restore-key "f" :window-tree (:type leaf :buffer "missing")))
             #'ignore (lambda (r) (setq completed r)))
            (should (eq (plist-get completed :status) 'failed))
            (should-not (buffer-live-p buf)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest crash-workspace-one-failed-conversation-does-not-cost-the-rest ()
  ;; Entry "bad" refuses to resume; "good" comes back.  Frames are still
  ;; rebuilt, "bad"'s window gets a placeholder, and the result names it.
  (let ((buf (generate-new-buffer " *recovery-good*")) placeholder completed)
    (unwind-protect
        (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
                   (lambda (entry done)
                     (if (equal (plist-get entry :session-id) "bad")
                         (funcall done '((ok . :false) (status . "failed") (error . "agent went silent")))
                       (funcall done `((ok . t) (status . "ready") (bufferName . ,(buffer-name buf))
                                       (existing . :false))))))
                  ((symbol-function 'mr-x/crash-restore-frames)
                   (lambda (_session _replay)
                     (should (eq (mr-x/crash-workspace-buffer 'codex "good") buf))
                     (setq placeholder (mr-x/crash-workspace-buffer 'codex "bad"))
                     '(:status restored :frames nil))))
          (mr-x/crash-workspace-start
           "attempt"
           '((:agent codex :session-id "bad" :cwd "/tmp/" :label "BAD" :transcript "/tmp/bad.md")
             (:agent codex :session-id "good" :cwd "/tmp/"))
           '((:restore-key "f" :window-tree (:type leaf :restore-spec (agent-shell :agent codex :session-id "bad" :dir "/tmp/"))))
           #'ignore (lambda (r) (setq completed r)))
          (should (eq (plist-get completed :status) 'restored))
          (let ((failed (plist-get completed :failed)))
            (should (= 1 (length failed)))
            (should (equal (plist-get (car failed) :session-id) "bad"))
            (should (equal (plist-get (car failed) :error) "agent went silent")))
          (should (buffer-live-p buf))
          (should (buffer-live-p placeholder))
          (with-current-buffer placeholder
            (should (derived-mode-p 'special-mode))
            (should-not mr-x/crash-workspace-owner)
            (should (string-match-p "BAD" (buffer-string)))
            (should (string-match-p "/tmp/bad.md" (buffer-string)))
            (should (string-match-p "agent went silent" (buffer-string)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p placeholder) (kill-buffer placeholder)))))

(ert-deftest crash-workspace-failed-pending-conversation-leaves-no-buffer ()
  ;; A resume handed over as pending and then refused must not leave its
  ;; half-started buffer behind, while the rest of the workspace continues.
  (let ((pending-buf (generate-new-buffer " *recovery-pending*"))
        (good-buf (generate-new-buffer " *recovery-good2*"))
        callback completed)
    (unwind-protect
        (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
                   (lambda (entry done)
                     (if (equal (plist-get entry :session-id) "slow")
                         (progn (setq callback done)
                                `((status . "pending") (operation . "op")
                                  (bufferName . ,(buffer-name pending-buf)) (existing . :false)))
                       (funcall done `((ok . t) (status . "ready") (bufferName . ,(buffer-name good-buf))
                                       (existing . :false))))))
                  ((symbol-function 'mr-x/crash-restore-frames)
                   (lambda (&rest _) '(:status restored :frames nil))))
          (mr-x/crash-workspace-start
           "attempt"
           '((:agent codex :session-id "slow" :cwd "/tmp/") (:agent codex :session-id "good" :cwd "/tmp/"))
           nil #'ignore (lambda (r) (setq completed r)))
          (should-not completed)
          (should (buffer-live-p pending-buf))
          (funcall callback '((ok . :false) (status . "failed") (error . "The agent went silent for 45s")))
          (should (eq (plist-get completed :status) 'restored))
          (should (equal (mapcar (lambda (f) (plist-get f :session-id)) (plist-get completed :failed)) '("slow")))
          (should-not (buffer-live-p pending-buf))
          (should (buffer-live-p good-buf)))
      (dolist (b (list pending-buf good-buf)) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest crash-workspace-synchronous-resume-error-is-a-failure-not-an-abort ()
  (let ((buf (generate-new-buffer " *recovery-sync*")) completed)
    (unwind-protect
        (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
                   (lambda (entry done)
                     (if (equal (plist-get entry :session-id) "gone")
                         (error "Saved conversation has no valid provider, session or local directory")
                       (funcall done `((ok . t) (status . "ready") (bufferName . ,(buffer-name buf))
                                       (existing . :false))))))
                  ((symbol-function 'mr-x/crash-restore-frames)
                   (lambda (&rest _) '(:status restored :frames nil))))
          (mr-x/crash-workspace-start
           "attempt"
           '((:agent codex :session-id "gone" :cwd "/nowhere/") (:agent codex :session-id "ok" :cwd "/tmp/"))
           nil #'ignore (lambda (r) (setq completed r)))
          (should (eq (plist-get completed :status) 'restored))
          (should (equal (mapcar (lambda (f) (plist-get f :session-id)) (plist-get completed :failed)) '("gone")))
          (should (string-match-p "no valid provider" (plist-get (car (plist-get completed :failed)) :error)))
          (should (buffer-live-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest crash-workspace-unknown-session-still-aborts-replay ()
  ;; Only recorded failures get placeholders; an unverified session that
  ;; never failed is a bug and must roll the transaction back.
  (let (completed)
    (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
              ((symbol-function 'mr-x/crash-restore-frames)
               (lambda (_session _replay)
                 (mr-x/crash-workspace-buffer 'codex "never-queued"))))
      (mr-x/crash-workspace-start "attempt" nil
                                 '((:restore-key "f" :window-tree (:type leaf :buffer "fixture")))
                                 #'ignore (lambda (r) (setq completed r)))
      (should (eq (plist-get completed :status) 'failed))
      (should (string-match-p "never-queued" (car (plist-get completed :errors)))))))

(ert-deftest crash-workspace-rejects-legacy-agent-before-start ()
  (let (started)
    (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                  ((symbol-function 'syzygy-recall-resume-entry)
               (lambda (&rest _) (setq started t))))
      (should-error
       (mr-x/crash-workspace-start
        "attempt" nil
        '((:restore-key "f" :window-tree (:type leaf :restore-spec (agent-shell :session-id "sid" :dir "/tmp/"))))
        #'ignore #'ignore))
      (should-not started))))

(ert-deftest crash-workspace-presentation-failure-rolls-back-created-frames ()
  (let (deleted completed)
    (cl-letf (((symbol-function 'mr-x/crash-restore-frames)
               (lambda (&rest _) '(:status restored :frames ((:restore-key "f" :frame fake-frame)))))
              ((symbol-function 'mr-x/crash-workspace--presentation)
               (lambda (_) (error "presentation failed")))
              ((symbol-function 'delete-frame) (lambda (frame &rest _) (push frame deleted))))
      (mr-x/crash-workspace-start "failed-presentation" nil
                                 '((:restore-key "f" :window-tree (:type leaf :buffer "fixture")))
                                 #'ignore (lambda (r) (setq completed r)))
      (should (eq (plist-get completed :status) 'failed))
      (should (equal deleted '(fake-frame))))))
