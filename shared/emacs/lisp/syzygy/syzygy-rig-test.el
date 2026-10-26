;;; syzygy-rig-test.el --- Tests for syzygy-rig -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs without agent-shell or major-pane being needed.  Until
;; syzygy-recall stops hard-requiring major-pane, add the Mac's lisp
;; directory to the load path:
;;
;;   emacs --batch -L . -L ~/.dotfiles/macos/emacs/.emacs.d/lisp \
;;     -l syzygy-rig-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'syzygy-rig)

;; The timers, hook and emit-event advice wait for agent-shell, which
;; batch never loads.  The major-pane advice does install here, because
;; syzygy-recall loads major-pane; a recall test that sets a label would
;; then write the real ~/.acp-mobile/labels.json, so remove it.
(advice-remove 'major-pane-set-label #'mr-x/agent-label-sync)
(advice-remove 'agent-shell-restart #'mr-x/agent-label--keep-across-restart)

;; syzygy-recall's fork tests cover the case where the rig helpers are
;; absent (a machine without the rig) and check `fboundp'.  Hide every
;; function syzygy-rig defines and give them back only inside these tests.
(defconst syzygy-rig-test--definitions
  (let (defs)
    (dolist (entry (cdr (seq-find (lambda (file) (member '(provide . syzygy-rig) (cdr file)))
                                    load-history)))
      (when (eq (car-safe entry) 'defun)
        (push (cons (cdr entry) (symbol-function (cdr entry))) defs)))
    (dolist (def defs) (fmakunbound (car def)))
    defs)
  "Alist of (FUNCTION . DEFINITION) that syzygy-rig defined.")

(defmacro syzygy-rig-test--with-rig (&rest body)
  "Run BODY with syzygy-rig's functions defined."
  (declare (indent 0))
  `(let ((saved (mapcar (lambda (def) (cons (car def) (symbol-function (car def))))
                        syzygy-rig-test--definitions)))
     (unwind-protect
         (progn
           (dolist (def syzygy-rig-test--definitions) (fset (car def) (cdr def)))
           ,@body)
       (dolist (def saved) (fset (car def) (cdr def))))))

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
In the combined SYZYGY suite syzygy-recall has already loaded
major-pane, so the binding is removed for BODY and restored after."
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
  (syzygy-rig-test--with-rig
    (dolist (f '(mr-x/agent-shell-start-preset mr-x/agent-shell-spawn-for-mobile
                 mr-x/agent-spawn--send-when-ready mr-x/agent-shell--clone-config
                 mr-x/agent-shell--display-new mr-x/agent-label-sync mr-x/agent-label-set
                 mr-x/agent-status-sync meta-agent-shell-close-session))
      (should (fboundp f)))
    (should (boundp 'mr-x/agent-shell-presets))))

(ert-deftest syzygy-rig-label-sync-without-major-pane ()
  "Review Focus 2: no major-pane, labels.json still written, no error."
  (syzygy-rig-test--with-rig
    (syzygy-rig-test--with-state-dir
      (syzygy-rig-test--without-major-pane
        (should-not (boundp 'major-pane--labels))
        (syzygy-rig-test--with-fake-shell "sid-1"
          (mr-x/agent-label-sync)))
      (should (file-exists-p (syzygy-state-file "labels.json")))
      (should (equal (gethash "sid-1" (json-parse-string
                                       (syzygy-rig-test--slurp "labels.json")))
                     "")))))

(ert-deftest syzygy-rig-status-sync-writes-idle ()
  (syzygy-rig-test--with-rig
    (syzygy-rig-test--with-state-dir
      (let ((mr-x/agent-status--last nil))
        (syzygy-rig-test--with-fake-shell "sid-1"
          (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil)))
            (mr-x/agent-status-sync))))
      ;; Hash tables are never `equal', so compare the decoded alist.
      (should (equal (json-parse-string (syzygy-rig-test--slurp "status.json")
                                        :object-type 'alist)
                     '((sid-1 . "idle")))))))

(ert-deftest syzygy-rig-status-sync-skips-unchanged ()
  "Review Focus 3: {} written once; an identical tick does not rewrite."
  (syzygy-rig-test--with-rig
    (syzygy-rig-test--with-state-dir
      (let ((mr-x/agent-status--last nil))
        (mr-x/agent-status-sync)
        (let ((mtime (file-attribute-modification-time
                      (file-attributes (syzygy-state-file "status.json")))))
          (sleep-for 1.1)
          (mr-x/agent-status-sync)
          (should (equal mtime (file-attribute-modification-time
                                (file-attributes (syzygy-state-file "status.json"))))))))))

(ert-deftest syzygy-rig-close-session-kills-buffer ()
  (syzygy-rig-test--with-rig
    (with-temp-buffer
      (let ((name (buffer-name)))
        (setq-local agent-shell-on-exit (lambda () (error "must be cleared")))
        (should (meta-agent-shell-close-session name))
        (should-not (get-buffer name))))))

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
                          "-L" (expand-file-name "~/.dotfiles/macos/emacs/.emacs.d/lisp")
                          "-L" (expand-file-name "~/roaming/projects/agent-recall")
                          "--eval" form)
            (buffer-string))))
    (should (string-match "RESULT \\([0-9]+\\) \\([a-z]+\\)" output))
    (should (equal (match-string 1 output) "0"))
    (should (equal (match-string 2 output) "nil"))))

(provide 'syzygy-rig-test)
;;; syzygy-rig-test.el ends here
