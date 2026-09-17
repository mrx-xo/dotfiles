;;; session-restore-test.el --- Restore failures retain evidence -*- lexical-binding: t; -*-

;;; Commentary:
;; Load after init.el.  These tests exercise the real leaf replay and bundle
;; driver, replacing only GUI frame creation and agent process startup.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mr-x-crash-restore)
(require 'mr-x-crash-bundle)

(ert-deftest session-restore-test-missing-file-does-not-use-namesake ()
  (let ((buffer (generate-new-buffer " *restore-namesake*"))
        (directory (make-temp-file "restore-missing-" t)))
    (unwind-protect
        (save-window-excursion
          (let ((err (should-error
                      (mr-x/--restore-window-tree
                       (selected-window)
                       (list :type 'leaf :buffer (buffer-name buffer)
                             :file (expand-file-name "missing.txt" directory))))))
            (should (string-match-p "missing.txt" (error-message-string err)))))
      (kill-buffer buffer)
      (delete-directory directory t))))

(ert-deftest session-restore-test-handler-error-reaches-caller ()
  (let ((buffer (generate-new-buffer " *restore-agent*")))
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'mr-x/crash-workspace-buffer)
                     (lambda (&rest _) (error "fixture resume refused"))))
            (let ((err (should-error
                        (mr-x/--restore-window-tree
                         (selected-window)
                         (list :type 'leaf :buffer (buffer-name buffer)
                               :restore-spec '(agent-shell :session-id "fixture"))))))
              (should (string-match-p "fixture resume refused"
                                      (error-message-string err))))))
      (kill-buffer buffer))))

(ert-deftest session-restore-test-unavailable-handler-does-not-use-namesake ()
  (with-temp-buffer
    (save-window-excursion
      (cl-letf (((symbol-function 'agent-shell--resolve-preferred-config)
                 (lambda () nil))
                ((symbol-function 'agent-shell--start)
                 (lambda (&rest _) (ert-fail "Must not start without config"))))
        (should-error
         (mr-x/--restore-window-tree
          (selected-window)
          (list :type 'leaf :buffer (buffer-name)
                :restore-spec '(agent-shell :session-id "fixture"))))))))

(ert-deftest session-restore-test-missing-plain-buffer-fails ()
  (save-window-excursion
    (should-error
     (mr-x/--restore-window-tree
      (selected-window) (list :type 'leaf :buffer (make-temp-name " *absent-restore-"))))))

(ert-deftest session-restore-test-real-file-and-dired-and-existing-buffer ()
  (let* ((directory (make-temp-file "restore-success-" t))
         (file (expand-file-name "example.txt" directory))
         (existing (generate-new-buffer " *restore-existing*")))
    (unwind-protect
        (save-window-excursion
          (write-region "first\nsecond\n" nil file nil 'silent)
          (mr-x/--restore-window-tree
           (selected-window) (list :type 'leaf :file file :buffer "example.txt" :point 8))
          (should (file-equal-p file (buffer-file-name (window-buffer))))
          (should (= 8 (window-point)))
          (mr-x/--restore-window-tree
           (selected-window) (list :type 'leaf :buffer "fixture-directory"
                                   :restore-spec (list 'dired :dir directory)))
          (with-current-buffer (window-buffer)
            (should (derived-mode-p 'dired-mode))
            (should (file-equal-p default-directory directory)))
          (mr-x/--restore-window-tree
           (selected-window) (list :type 'leaf :buffer (buffer-name existing)))
          (should (eq existing (window-buffer))))
      (dolist (buffer (buffer-list))
        (when (or (eq buffer existing)
                  (with-current-buffer buffer
                    (or (equal buffer-file-name file)
                        (and (derived-mode-p 'dired-mode)
                             (file-equal-p default-directory directory)))))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest session-restore-test-bundle-kept-after-missing-file-and-retry-succeeds ()
  (let* ((user-emacs-directory (file-name-as-directory (make-temp-file "restore-bundle-" t)))
         (runs (expand-file-name "var/crash-recovery/runs/" user-emacs-directory))
         (file (expand-file-name "missing.txt" user-emacs-directory))
         (session (list (list :restore-key "fixture-frame" :width 80 :height 24
                             :window-tree (list :type 'leaf :buffer "missing.txt" :file file))))
         (deleted nil))
    (unwind-protect
        (save-window-excursion
          (make-directory runs t)
          (let* ((run (mr-x/crash-run-create runs "fixture" user-emacs-directory))
                 (identity (mr-x/crash-run-initialized run 4242))
                 (store (mr-x/crash-bundle-store user-emacs-directory)))
            (mr-x/crash-capture-save run identity (lambda () session) nil)
            (let* ((id (mr-x/crash-bundle-create store run))
                   (directory (mr-x/crash-bundle-directory store id))
                   (info (mr-x/--crash-info))
                   (digest (mr-x/crash-capture--digest (plist-get info :session))))
              (cl-letf (((symbol-function 'make-frame) (lambda (&rest _) 'fixture-frame))
                        ((symbol-function 'delete-frame) (lambda (frame &rest _) (push frame deleted)))
                        ((symbol-function 'mr-x/--crash-replay-tree)
                         (lambda (_frame tree) (mr-x/--restore-window-tree (selected-window) tree)))
                        ((symbol-function 'mr-x/crash-recovery) #'ignore)
                        ((symbol-function 'mr-x/--crash-after-consume) #'ignore))
                (mr-x/--crash-restore-bundle info)
                (should (file-directory-p directory))
                (let ((status (mr-x/crash-bundle-status directory)))
                  (should (eq 'pending-frames (plist-get status :phase)))
                  (should (= 1 (plist-get status :attempt)))
                  (should (string-match-p "missing.txt" (plist-get status :last-error))))
                (should (equal '(fixture-frame) deleted))
                (should (equal digest (mr-x/crash-capture--digest (plist-get info :session))))
                (write-region "Recovered file\n" nil file nil 'silent)
                (mr-x/--crash-restore-bundle info)
                (should (file-equal-p file (buffer-file-name (window-buffer))))
                (should-not (file-exists-p directory))
                (should-not (mr-x/crash-pending-p))))))
      (when-let ((buffer (get-file-buffer file))) (kill-buffer buffer))
      (delete-directory user-emacs-directory t))))

(provide 'session-restore-test)
;;; session-restore-test.el ends here

(ert-deftest session-restore-workspace-bundle-waits-fails-and-retries ()
  (let* ((user-emacs-directory (file-name-as-directory (make-temp-file "restore-workspace-" t)))
         (runs (expand-file-name "var/crash-recovery/runs/" user-emacs-directory))
         (major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (mr-x/--crash-restore-active nil) (mr-x/--crash-restore-operation nil)
         (major-pane-workspace-inhibit-save nil)
         buffer callback)
    (unwind-protect
        (progn
          (make-directory runs t)
          (let* ((run (mr-x/crash-run-create runs "fixture" user-emacs-directory))
                 (identity (mr-x/crash-run-initialized run 4242))
                 (store (mr-x/crash-bundle-store user-emacs-directory)))
            (mr-x/crash-capture-save
             run identity (lambda () nil) nil nil
             (lambda () '((:agent codex :session-id "saved" :cwd "/tmp/" :label "Recovered"))))
            (let* ((id (mr-x/crash-bundle-create store run))
                   (directory (mr-x/crash-bundle-directory store id))
                   (info (mr-x/--crash-info)))
              (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                        ((symbol-function 'syzygy-recall-resume-entry)
                         (lambda (_entry done)
                           (setq callback done buffer (generate-new-buffer " *bundle-agent*"))
                           `((status . "pending") (operation . "fixture")
                             (bufferName . ,(buffer-name buffer)) (existing . :false))))
                        ((symbol-function 'mr-x/crash-recovery) #'ignore)
                        ((symbol-function 'mr-x/--crash-after-consume) #'ignore))
                (mr-x/--crash-restore-bundle info)
                (should major-pane-workspace-inhibit-save)
                (should (eq (plist-get (mr-x/crash-bundle-status directory) :phase) 'restoring-frames))
                (funcall callback '((ok . :false) (error . "wrong session")))
                (should-not (buffer-live-p buffer))
                (should-not major-pane-workspace-inhibit-save)
                (should (eq (plist-get (mr-x/crash-bundle-status directory) :phase) 'pending-frames))
                (mr-x/--crash-restore-bundle info)
                (should (file-exists-p directory))
                (funcall callback `((ok . t) (status . "ready") (bufferName . ,(buffer-name buffer)) (existing . :false)))
                (should (buffer-live-p buffer))
                (should (equal (gethash buffer major-pane--labels) "Recovered"))
                (should-not (file-exists-p directory))
                (should-not mr-x/--crash-restore-active)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory user-emacs-directory t))))

(ert-deftest session-restore-workspace-bundle-keeps-evidence-when-one-conversation-fails ()
  (let* ((user-emacs-directory (file-name-as-directory (make-temp-file "restore-partial-" t)))
         (runs (expand-file-name "var/crash-recovery/runs/" user-emacs-directory))
         (major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (mr-x/--crash-restore-active nil) (mr-x/--crash-restore-operation nil)
         (major-pane-workspace-inhibit-save nil)
         buffer callback)
    (unwind-protect
        (progn
          (make-directory runs t)
          (let* ((run (mr-x/crash-run-create runs "fixture" user-emacs-directory))
                 (identity (mr-x/crash-run-initialized run 4242))
                 (store (mr-x/crash-bundle-store user-emacs-directory)))
            (mr-x/crash-capture-save
             run identity (lambda () nil) nil nil
             (lambda () '((:agent codex :session-id "huge" :cwd "/tmp/" :label "PANDORA")
                          (:agent codex :session-id "saved" :cwd "/tmp/" :label "Recovered"))))
            (let* ((id (mr-x/crash-bundle-create store run))
                   (directory (mr-x/crash-bundle-directory store id))
                   (info (mr-x/--crash-info)))
              (cl-letf (((symbol-function 'syzygy-recall--entry-initialized-p) (lambda (_) t))
                        ((symbol-function 'syzygy-recall-resume-entry)
                         (lambda (entry done)
                           (if (equal (plist-get entry :session-id) "huge")
                               (funcall done '((ok . :false) (status . "failed")
                                               (error . "The agent went silent for 45s")))
                             (setq callback done buffer (generate-new-buffer " *bundle-partial*"))
                             `((status . "pending") (operation . "fixture")
                               (bufferName . ,(buffer-name buffer)) (existing . :false)))))
                        ((symbol-function 'mr-x/crash-recovery) #'ignore)
                        ((symbol-function 'mr-x/--crash-after-consume) #'ignore))
                (mr-x/--crash-restore-bundle info)
                (should (eq (plist-get (mr-x/crash-bundle-status directory) :phase) 'restoring-frames))
                (funcall callback `((ok . t) (status . "ready") (bufferName . ,(buffer-name buffer)) (existing . :false)))
                (should (buffer-live-p buffer))
                (should (equal (gethash buffer major-pane--labels) "Recovered"))
                (should (file-exists-p directory))
                (let ((status (mr-x/crash-bundle-status directory)))
                  (should (eq (plist-get status :phase) 'pending-frames))
                  (should (string-match-p "PANDORA" (plist-get status :last-error)))
                  (should (string-match-p "went silent" (plist-get status :last-error))))
                (should-not mr-x/--crash-restore-active)
                (should-not major-pane-workspace-inhibit-save)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory user-emacs-directory t))))

(ert-deftest session-restore-cleanup-selects-only-attempt-owned-frames ()
  (cl-letf (((symbol-function 'frame-list) (lambda () '(ours unrelated)))
            ((symbol-function 'frame-parameter)
             (lambda (frame key)
               (pcase key
                 ('mr-x/restore-key "same-key")
                 ('mr-x/recovery-owner (if (eq frame 'ours) '("bundle" . 2) '("older" . 1)))))))
    (should (equal (mr-x/--crash-frames-with-keys '("same-key") '("bundle" . 2)) '(ours)))))

(ert-deftest session-restore-displayed-worker-gets-explicit-placeholder ()
  (with-temp-buffer
    (setq-local major-mode 'agent-shell-mode major-pane--excluded t)
    (let ((spec (mr-x/--buffer-restore-spec (current-buffer))))
      (should (eq (car spec) 'excluded-agent)))))

(ert-deftest session-restore-manual-save-refuses-partial-workspace ()
  (let ((major-pane-workspace-inhibit-save t))
    (should-error (mr-x/save-session-state) :type 'user-error)))
