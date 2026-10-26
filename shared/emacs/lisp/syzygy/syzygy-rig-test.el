;;; syzygy-rig-test.el --- Tests for syzygy-rig -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs without agent-shell or major-pane being needed:
;;
;;   emacs --batch -L . \
;;     -l syzygy-rig-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'syzygy-rig)

;; Nothing here changes global state at load time: the rig stays
;; defined and its advice stays installed for every other test and for
;; anyone who loads this file into a running daemon.  A test that needs
;; something absent hides it itself and restores it before returning.

(defmacro syzygy-rig-test--without-functions (functions &rest body)
  "Run BODY with each symbol in FUNCTIONS unbound, restoring them after."
  (declare (indent 1))
  (let ((saved (make-symbol "saved")))
    `(let ((,saved (mapcar (lambda (f) (cons f (and (fboundp f) (symbol-function f))))
                           ,functions)))
       (unwind-protect
           (progn (dolist (f ,functions) (fmakunbound f))
                  ,@body)
         (dolist (def ,saved)
           (when (cdr def) (fset (car def) (cdr def))))))))

(defmacro syzygy-rig-test--with-state-dir (&rest body)
  "Run BODY with `syzygy-state-directory' bound to a fresh temp directory."
  (declare (indent 0))
  (let ((dir (make-symbol "dir")))
    `(let* ((,dir (make-temp-file "syzygy-rig-test-" t))
            (syzygy-state-directory ,dir))
       (unwind-protect (progn ,@body)
         (delete-directory ,dir t)))))

(defmacro syzygy-rig-test--with-fake-shell (sid &rest body)
  "Run BODY while a fake agent-shell buffer with session SID is live."
  (declare (indent 1))
  (let ((buf (make-symbol "buf")))
    `(let ((,buf (generate-new-buffer " *syzygy-rig-test-shell*")))
       (unwind-protect
           (progn
             (with-current-buffer ,buf
               (setq-local major-mode 'agent-shell-mode)
               (setq-local agent-shell--state (list :session (list :id ,sid))))
             ,@body)
         (kill-buffer ,buf)))))

(defmacro syzygy-rig-test--without-major-pane (&rest body)
  "Run BODY with `major-pane--labels' unbound, as when major-pane is absent.
Another test file may have loaded major-pane, so the binding is removed
for BODY and restored after."
  (declare (indent 0))
  (let ((saved (make-symbol "saved")) (had (make-symbol "had")))
    `(let* ((,had (boundp 'major-pane--labels))
            (,saved (and ,had (symbol-value 'major-pane--labels))))
       (unwind-protect
           (progn (when ,had (makunbound 'major-pane--labels))
                  ,@body)
         (when ,had (set 'major-pane--labels ,saved))))))

(defun syzygy-rig-test--slurp (name)
  "Return state file NAME's contents as a string."
  (with-temp-buffer
    (insert-file-contents (syzygy-state-file name))
    (buffer-string)))

(ert-deftest syzygy-rig-provides-the-rig-helpers ()
  (dolist (f '(mr-x/agent-shell-start-preset mr-x/agent-shell-spawn-for-mobile
               mr-x/agent-spawn--send-when-ready mr-x/agent-shell--clone-config
               mr-x/agent-shell--display-new mr-x/agent-label-sync mr-x/agent-label-set
               mr-x/agent-status-sync meta-agent-shell-close-session))
    (should (fboundp f)))
  (should (boundp 'mr-x/agent-shell-presets)))

(ert-deftest syzygy-rig-label-sync-without-major-pane ()
  "Review Focus 2: no major-pane, labels.json still written, no error."
  (syzygy-rig-test--with-state-dir
    (syzygy-rig-test--without-major-pane
      (should-not (boundp 'major-pane--labels))
      (syzygy-rig-test--with-fake-shell "sid-1"
        (mr-x/agent-label-sync)))
    (should (file-exists-p (syzygy-state-file "labels.json")))
    (should (equal (gethash "sid-1" (json-parse-string
                                     (syzygy-rig-test--slurp "labels.json")))
                   ""))))

(ert-deftest syzygy-rig-status-sync-writes-idle ()
  (syzygy-rig-test--with-state-dir
    (let ((mr-x/agent-status--last nil))
      (syzygy-rig-test--with-fake-shell "sid-1"
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil)))
          (mr-x/agent-status-sync))))
    ;; Hash tables are never `equal', so compare the decoded alist.
    (should (equal (json-parse-string (syzygy-rig-test--slurp "status.json")
                                      :object-type 'alist)
                   '((sid-1 . "idle"))))))

(ert-deftest syzygy-rig-status-sync-skips-unchanged ()
  "Review Focus 3: {} written once; an identical tick does not rewrite."
  (syzygy-rig-test--with-state-dir
    (let ((mr-x/agent-status--last nil))
      (mr-x/agent-status-sync)
      (let ((mtime (file-attribute-modification-time
                    (file-attributes (syzygy-state-file "status.json")))))
        (sleep-for 1.1)
        (mr-x/agent-status-sync)
        (should (equal mtime (file-attribute-modification-time
                              (file-attributes (syzygy-state-file "status.json")))))))))

(ert-deftest syzygy-rig-close-session-kills-buffer ()
  (with-temp-buffer
    (let ((name (buffer-name)))
      (setq-local agent-shell-on-exit (lambda () (error "must be cleared")))
      (should (meta-agent-shell-close-session name))
      (should-not (get-buffer name)))))

(ert-deftest syzygy-rig-load-starts-nothing-without-agent-shell ()
  "A bare require starts no sidecar timer and adds no live-turn hook."
  (let* ((dir (file-name-directory (locate-library "syzygy-rig.el")))
         (form (prin1-to-string
                '(progn
                   (require 'syzygy-rig)
                   (princ (format "RESULT %S %S"
                                  (length (seq-filter
                                           (lambda (tm)
                                             (memq (timer--function tm)
                                                   '(mr-x/agent-status-sync
                                                     mr-x/agent-label-heal)))
                                           timer-list))
                                  (and (memq 'mr-x/agent-status-sync
                                             syzygy-live-turn-state-change-hook)
                                       t))))))
         (output
          (with-temp-buffer
            (call-process (expand-file-name invocation-name invocation-directory)
                          nil t nil "--batch"
                          "-L" dir
                          "-L" (expand-file-name "~/roaming/projects/agent-recall")
                          "--eval" form)
            (buffer-string))))
    (should (string-match "RESULT \\([0-9]+\\) \\([a-z]+\\)" output))
    (should (equal (match-string 1 output) "0"))
    (should (equal (match-string 2 output) "nil"))))

;;;; Presets without the Mac helpers (the Windows rig)

(defconst syzygy-rig-test--mac-helpers
  '(mr-x/color mr-x/agent-shell--codex-preset-p
    mr-x/agent-shell--read-codex-account major-pane-mode-word)
  "Mac-rig functions the preset picker and spawn path may call.")

(defmacro syzygy-rig-test--with-stub-start (started &rest body)
  "Run BODY with `agent-shell--start' stubbed; STARTED collects its args.
The stub returns a fresh buffer, killed after BODY."
  (declare (indent 1))
  (let ((buffers (make-symbol "buffers")))
    `(let ((,started nil) (,buffers nil))
       ;; `dlet': a plain `let' of `features' is lexical here, and the
       ;; spawn path's (require 'agent-shell) must see it as loaded.
       (dlet ((features (cons 'agent-shell features))
              (agent-shell-prefer-viewport-interaction nil))
         (unwind-protect
             (cl-letf (((symbol-function 'agent-shell--start)
                        (lambda (&rest args)
                          (push args ,started)
                          (car (push (generate-new-buffer " *syzygy-rig-test-new*")
                                     ,buffers))))
                       ((symbol-function 'agent-shell--resolve-preferred-config)
                        (lambda () (list (cons :identifier 'claude-code))))
                       ((symbol-function 'run-at-time) #'ignore))
               (save-window-excursion ,@body))
           (mapc #'kill-buffer (seq-filter #'buffer-live-p ,buffers)))))))

(ert-deftest syzygy-rig-preset-picker-without-mac-helpers ()
  "Windows has no `mr-x/color', Codex-account helpers or major-pane words:
the picker still renders and a preset still spawns."
  (syzygy-rig-test--without-functions syzygy-rig-test--mac-helpers
    (dolist (f syzygy-rig-test--mac-helpers) (should-not (fboundp f)))
    (let ((prompt (mr-x/agent-shell--preset-prompt "Preset: ")))
      (should (string-suffix-p "Preset: " prompt))
      (should (string-match-p "bypassPermissions" prompt)))
    (let ((preset (mr-x/agent-shell--read-preset ?f)))
      (should (eq (car preset) ?f))
      (should (equal preset (assq ?f mr-x/agent-shell-presets)))
      (syzygy-rig-test--with-stub-start started
        (mr-x/agent-shell--spawn-preset preset)
        (should (= (length started) 1))
        (let ((config (plist-get (car started) :config)))
          (should (equal (funcall (alist-get :default-model-id config))
                         (nth 2 preset)))
          (should (equal (funcall (alist-get :default-session-mode-id config))
                         (nth 3 preset))))))))

(ert-deftest syzygy-rig-windows-preset-shape-spawns ()
  "A Windows tuple (CHAR LABEL MODEL MODE), so CONFIG-FN is nil, goes
through `--config-with' and `start-preset' on the preferred config."
  (let ((mr-x/agent-shell-presets
         '((?h "Haiku · Auto" "haiku" "auto"))))
    (syzygy-rig-test--with-stub-start started
      (let ((config (mr-x/agent-shell--config-with "haiku" "auto"
                                                   (nth 4 (car mr-x/agent-shell-presets)))))
        (should (eq (alist-get :identifier config) 'claude-code))
        (should (equal (funcall (alist-get :default-model-id config)) "haiku"))
        (should (equal (funcall (alist-get :default-session-mode-id config)) "auto")))
      (syzygy-rig-test--without-functions syzygy-rig-test--mac-helpers
        (mr-x/agent-shell-start-preset ?h))
      (should (= (length started) 1)))))

(provide 'syzygy-rig-test)
;;; syzygy-rig-test.el ends here
