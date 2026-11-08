;;; review-conversation-test.el --- Walkthrough conversation contract -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-conversation)
(require 'review-walkthrough-test)

(defmacro review-conversation-test--with (session &rest body)
  (declare (indent 1))
  `(let ((review-session-pop-out nil) (review-panel-pop-out nil)
         (review-session-pulse nil)
         (review-conversation--shells (make-hash-table :test #'equal))
         (review-conversation--visible nil)
         (review-conversation--visible-buffer nil)
         (review-conversation--selection nil)
         (review-conversation--resume-operation nil)
         (review-conversation--resume-token nil))
     (review-conversation-mode 1)
     (unwind-protect
         (review-walk-test--with ,session ,@body)
       (review-conversation-mode -1))))

(defun review-conversation-test--shell (id)
  (let ((buffer (generate-new-buffer " *review test agent*")))
    (with-current-buffer buffer
      (setq-local agent-shell--state
                  `((:session . ((:id . ,id))) (:agent-config . ((:identifier . test-agent))))))
    buffer))

(ert-deftest review-conversation-persists-producer-after-route-end-and-quit ()
  (review-conversation-test--with s
    (let ((shell (review-conversation-test--shell "producer")))
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (review-conversation--accepted s shell)
            (let ((identity (review-conversation--identity shell))
                  (key (review-source-key (review-source-recipe (review-session-source s)))))
              (review-walkthrough-quit)
              (review-session-quit)
              (clrhash review-store--memory)
              (let* ((record (review-store-load key)) (restored (review-store-restore record)))
                (should-not (review-session-walkthrough restored))
                (should (equal identity (plist-get (review-conversation--data restored) :producer)))
                (should (equal identity (plist-get (review-conversation--data restored) :session))))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-live-reuse-and-bottom-window-survive-navigation ()
  (review-conversation-test--with s
    (review-panel-open s)
    (let ((shell (review-conversation-test--shell "producer")))
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (review-conversation--accepted s shell)
            (let ((old (review-session-old-window s)) (new (review-session-new-window s)))
              (review-conversation-continue)
              (should (eq (window-buffer (review-conversation--window s)) shell))
              (should (>= (window-total-height (review-conversation--window s)) 6))
              (should (eq old (review-session-old-window s)))
              (should (eq new (review-session-new-window s)))
              (let ((edges (window-edges (review-conversation--window s))))
                (should (<= (car edges) (car (window-edges old))))
                (should (>= (nth 2 edges) (nth 2 (window-edges new))))
                (should (>= (nth 1 edges) (nth 3 (window-edges old)))))
              (review-walkthrough-next)
              (should (eq shell (window-buffer (review-conversation--window s))))
              (review-conversation-hide)
              (should-not (review-conversation--window s))
              (should (buffer-live-p shell))
              (review-conversation-continue)
              (should (eq shell (window-buffer (review-conversation--window s))))
              (should (= (car (window-edges old))
                         (car (window-edges (review-conversation--window s)))))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-two-reviews-do-not-borrow-project-agent ()
  (review-conversation-test--with s
    (let ((other (make-review-session :source (review-walk-test--source)))
          created)
      (setf (review-source-recipe (review-session-source other)) '(:kind fake :id "other"))
      (cl-letf (((symbol-function 'review-conversation--new-shell)
                 (lambda (session)
                   (let ((shell (generate-new-buffer " *review isolated*")))
                     (push shell created)
                     (puthash (review-conversation--key session) shell review-conversation--shells)
                     shell))))
        (unwind-protect
            (let ((first (review-conversation--ensure-shell s))
                  (second (review-conversation--ensure-shell other)))
              (should-not (eq first second))
              (should (eq first (review-conversation--ensure-shell s)))
              (should (eq second (review-conversation--ensure-shell other))))
          (mapc #'kill-buffer created))))))

(ert-deftest review-conversation-unlinked-route-does-not-guess-producer ()
  (review-conversation-test--with s
    (let ((shell (review-conversation-test--shell "unrelated")) offered)
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (puthash (review-conversation--key s) shell review-conversation--shells)
            (cl-letf (((symbol-function 'review-conversation--fallback)
                       (lambda (_session reason) (setq offered reason))))
              (review-conversation-continue)
              (should (string-match-p "No agent session" offered))
              (should-not (plist-get (review-conversation--data s) :session))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-new-external-route-does-not-inherit-old-producer ()
  (review-conversation-test--with s
    (let ((shell (review-conversation-test--shell "producer")))
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (review-conversation--accepted s shell)
            (review-walkthrough-start review-walk-test--steps)
            (should-not (plist-get (review-conversation--data s) :producer))
            (should (equal "producer"
                           (plist-get (plist-get (car (plist-get (review-conversation--data s) :history))
                                                :producer) :session-id))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-resume-rejects-new-session-fallback ()
  (review-conversation-test--with s
    (let ((wrong (review-conversation-test--shell "different")) offered)
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (let ((identity (plist-put (review-conversation--identity wrong) :session-id "original")))
              (review-conversation--put s (plist-put (review-conversation--data s) :session identity)))
            (cl-letf (((symbol-function 'require)
                       (let ((original (symbol-function 'require)))
                         (lambda (feature &rest rest)
                           (unless (eq feature 'syzygy-recall) (apply original feature rest)))))
                      ((symbol-function 'syzygy-recall-resume-entry)
                       (lambda (_entry callback)
                         (funcall callback `((ok . t) (bufferName . ,(buffer-name wrong))))))
                      ((symbol-function 'review-conversation--fallback)
                       (lambda (_session reason) (setq offered reason))))
              (review-conversation-continue)
              (should (string-match-p "identity did not match" offered))))
        (kill-buffer wrong)))))

(ert-deftest review-conversation-late-resume-does-not-reopen-closed-review ()
  (review-conversation-test--with s
    (let (callback shown)
      (review-walkthrough-start review-walk-test--steps)
      (review-conversation--put s
       (plist-put (review-conversation--data s) :session
                  (list :agent 'test :session-id "original" :machine (review-conversation--machine))))
      (cl-letf (((symbol-function 'require)
                 (let ((original (symbol-function 'require)))
                   (lambda (feature &rest rest)
                     (unless (eq feature 'syzygy-recall) (apply original feature rest)))))
                ((symbol-function 'syzygy-recall-resume-entry)
                 (lambda (_entry fn) (setq callback fn) nil))
                ((symbol-function 'review-conversation--fallback)
                 (lambda (&rest _) (setq shown t))))
        (review-conversation-continue)
        (review-session-quit)
        (funcall callback '((ok . nil) (error . "missing")))
        (should-not shown)))))

(ert-deftest review-conversation-prompt-carries-step-selection-and-snapshot ()
  (review-conversation-test--with s
    (let ((shell (review-conversation-test--shell "producer")))
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (review-conversation--accepted s shell)
            (review-conversation-continue)
            (setq review-conversation--selection
                  (list :key (review-conversation--key s) :path "a.el" :side 'old
                        :selection '(:start 3 :end 3 :text "3" :diff "- 3\n+ THREE")))
            (let ((prompt (plist-get (review-conversation--prompt-args
                                     (list :shell-buffer shell :prompt "Why?")) :prompt)))
              (should (string-match-p "Why?" prompt))
              (should (string-match-p "a.el:3-3 (old)" prompt))
              (should (string-match-p "step 1" prompt))
              (should (string-match-p "Snapshot:" prompt))
              (should (string-match-p (regexp-quote "- 3\n+ THREE") prompt)))
            (review-walkthrough-next)
            (should-not review-conversation--selection)
            (should (string-match-p "b.el:2-2 (new)"
                                    (plist-get (review-conversation--context s) :label))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-refresh-keeps-chat-and-marks-old-route-stale ()
  (review-conversation-test--with s
    (let ((shell (review-conversation-test--shell "producer"))
          (review-store-refresh-functions
           (list (cons 'fake (lambda (_recipe _record)
                              (review-session-start (review-walk-test--source)))))))
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (review-conversation--accepted s shell)
            (let ((fresh (review-session-refresh)))
              (should (plist-get (review-conversation--data fresh) :stale))
              (should-not (review-session-walkthrough fresh))
              (should (equal "producer" (plist-get (plist-get (review-conversation--data fresh) :session)
                                                    :session-id)))
              (review-conversation-continue)
              (should (eq shell (window-buffer (review-conversation--window fresh))))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-card-and-menu-expose-action ()
  (review-conversation-test--with s
    (require 'review-hydra)
    (review-walkthrough-start review-walk-test--steps)
    (with-current-buffer (review-session-new-buffer s)
      (goto-char (point-min))
      (search-forward "Continue conversation")
      (should (eq (lookup-key (get-text-property (1- (point)) 'keymap) (kbd "RET"))
                  #'review-conversation-continue)))
    (should (eq (lookup-key hydra-review/keymap (kbd "C"))
                'hydra-review/review-conversation-continue-and-exit))))

(ert-deftest review-conversation-replacement-initializes-after-pause ()
  (review-conversation-test--with s
    (let ((shell (generate-new-buffer " *replacement test*")) callback)
      (unwind-protect
          (progn
            (review-walkthrough-start review-walk-test--steps)
            (cl-letf (((symbol-function 'review-conversation--new-shell) (lambda (_) shell))
                      ((symbol-function 'agent-shell-subscribe-to)
                       (lambda (&rest args) (setq callback (plist-get args :on-event)))))
              (review-conversation-start-replacement))
            (let ((key (review-source-key (review-source-recipe (review-session-source s)))))
              (review-session-pause)
              (with-current-buffer shell
                (setq-local agent-shell--state
                            '((:session . ((:id . "replacement"))) (:agent-config . ((:identifier . test-agent))))))
              (funcall callback nil)
              (clrhash review-store--memory)
              (let* ((restored (review-store-restore (review-store-load key)))
                     (data (review-conversation--data restored)))
                (should (equal "replacement" (plist-get (plist-get data :session) :session-id)))
                (should (eq 'replacement (plist-get data :relationship)))
                (should (string-match-p "replacement agent" (plist-get data :seed)))
                (review-conversation-continue)
                (should (string-match-p "Saved walkthrough and evidence"
                                       (plist-get (review-conversation--prompt-args
                                                   (list :shell-buffer shell :prompt "Why?")) :prompt))))))
        (kill-buffer shell)))))

(ert-deftest review-conversation-hide-cancels-owned-recovery ()
  (review-conversation-test--with _s
    (let ((review-conversation--resume-token 'viewer)
          (review-conversation--resume-operation 'owned-operation) cancelled)
      (cl-letf (((symbol-function 'syzygy-recall-cancel-resume)
                 (lambda (token) (setq cancelled token))))
        (review-conversation-hide)
        (should (eq cancelled 'owned-operation))
        (should-not review-conversation--resume-token)
        (should-not review-conversation--resume-operation)))))

(ert-deftest review-conversation-ended-route-sends-current-hunk ()
  (review-conversation-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (review-walkthrough-quit)
    (should (string-match-p "THREE" (plist-get (review-conversation--context s) :text)))))

(ert-deftest review-conversation-failed-refresh-saves-latest-state ()
  (review-conversation-test--with s
    (let ((review-store-refresh-functions
           '((fake . (lambda (&rest _) (error "offline")))))
          (key (review-source-key (review-source-recipe (review-session-source s)))))
      (review-session-show 1)
      (should-error (review-session-refresh))
      (clrhash review-store--memory)
      (should (equal "b.el" (plist-get (review-store-load key) :current-path))))))

(ert-deftest review-conversation-forge-hosts-have-distinct-persistent-keys ()
  (should-not (equal (review-source-key '(:kind forgejo :host "https://one.example" :owner "o" :repo "r" :number 1))
                     (review-source-key '(:kind forgejo :host "https://two.example" :owner "o" :repo "r" :number 1)))))

(ert-deftest review-conversation-legacy-forge-record-is-upgraded-with-backup ()
  (review-conversation-test--with s
    (let* ((recipe '(:kind forgejo :host "https://one.example" :owner "o" :repo "r" :number 1))
           (record (review-store-record s))
           (old-key "forgejo:o/r#1")
           (new-key (review-source-key recipe)))
      (setq record (plist-put record :key old-key))
      (setq record (plist-put record :recipe recipe))
      (review-store--write record)
      (review-session-quit)
      (review-store-restore record)
      (should (equal new-key (plist-get (review-store-load new-key) :key)))
      (should-not (review-store-load old-key))
      (should (directory-files review-store-directory nil "legacy-")))))

(provide 'review-conversation-test)
