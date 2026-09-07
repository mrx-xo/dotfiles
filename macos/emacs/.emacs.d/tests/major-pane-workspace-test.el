;;; major-pane-workspace-test.el --- Tests for the open-convo snapshot -*- lexical-binding: t; -*-

;; Run:
;;   emacs --batch -L lisp -l tests/major-pane-workspace-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'major-pane)
(require 'major-pane-workspace)
;; Loaded here so the resume path's own `require' does not reload the
;; real module over a `cl-letf' stub mid-test.
(require 'agent-shell-bookmark)

(defvar agent-shell--state)
;; Declared special so the `let' in the path tests binds it dynamically.
(defvar no-littering-var-directory)
(defvar agent-recall--index)

(defmacro mpw-test--with-convos (specs &rest body)
  "Run BODY with fake convo buffers registered in major-pane.
SPECS is a list of (NAME SESSION-ID CWD AGENT LABEL ANCHORED).  A nil
SESSION-ID mimics a shell that has not finished session/new yet.
Every test starts from an empty pane and a fresh temp workspace file."
  (declare (indent 1))
  `(let ((major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (major-pane-workspace-file (make-temp-file "mpw-test-" nil ".el"))
         (major-pane-workspace--boot nil)
         (bufs nil))
     (unwind-protect
         (progn
           (dolist (spec ',specs)
             (cl-destructuring-bind (name sid cwd agent label anchored) spec
               (let ((buf (generate-new-buffer name)))
                 (push buf bufs)
                 (with-current-buffer buf
                   (setq default-directory cwd)
                   (setq-local agent-shell--state
                               (list (cons :session (list (cons :id sid)))
                                     (cons :agent-config
                                           (list (cons :identifier agent))))))
                 (setf (major-pane-state-conversations major-pane--state)
                       (append (major-pane-state-conversations major-pane--state)
                               (list buf)))
                 (when label (puthash buf label major-pane--labels))
                 (when anchored (push buf major-pane--anchored)))))
           ,@body)
       (mapc #'kill-buffer bufs)
       (delete-file major-pane-workspace-file))))

;;; collect

(ert-deftest major-pane-workspace-collect-follows-pane-order ()
  "Entries come out in `major-pane--ordered-convos' order with all fields."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" "alpha" nil)
                          ("Agent @ b" "sid-b" "/tmp/b/" "codex" nil t))
    (let ((entries (major-pane-workspace--collect)))
      (should (equal (mapcar (lambda (e) (plist-get e :session-id)) entries)
                     '("sid-b" "sid-a")))
      (let ((a (cadr entries)))
        (should (equal (plist-get a :cwd) "/tmp/a/"))
        (should (equal (plist-get a :agent) "claude-code"))
        (should (equal (plist-get a :label) "alpha"))
        (should (equal (plist-get a :buffer-name) "Agent @ a"))
        (should-not (plist-get a :anchored)))
      (should (plist-get (car entries) :anchored)))))

(ert-deftest major-pane-workspace-collect-skips-sessionless-buffers ()
  "A shell with no session id yet cannot be resumed, so it is left out."
  (mpw-test--with-convos (("Agent @ new" nil "/tmp/n/" "claude-code" nil nil)
                          ("Agent @ old" "sid-o" "/tmp/o/" "claude-code" nil nil))
    (should (equal (mapcar (lambda (e) (plist-get e :session-id))
                           (major-pane-workspace--collect))
                   '("sid-o")))))

;;; save / load history

(ert-deftest major-pane-workspace-first-save-pushes-new-snapshot ()
  "The first save of an Emacs process adds a snapshot; later saves replace it."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" nil nil))
    ;; Pretend a previous Emacs left one snapshot behind.
    (major-pane-workspace--write
     (list (list :started "2026-01-01 00:00:00" :saved "2026-01-01 00:00:00"
                 :convos (list (list :session-id "sid-prev")))))
    (major-pane-workspace-save)
    (let ((snaps (major-pane-workspace--read)))
      (should (= (length snaps) 2))
      (should (equal (plist-get (car (plist-get (car snaps) :convos)) :session-id)
                     "sid-a"))
      (should (equal (plist-get (car (plist-get (cadr snaps) :convos)) :session-id)
                     "sid-prev")))
    ;; Second save in the same process updates the head, no new entry.
    (major-pane-workspace-save)
    (should (= (length (major-pane-workspace--read)) 2))))

(ert-deftest major-pane-workspace-history-is-capped ()
  "Only `major-pane-workspace-history-size' snapshots survive a save."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" nil nil))
    (let ((major-pane-workspace-history-size 3))
      (major-pane-workspace--write
       (cl-loop for i from 1 to 5
                collect (list :started (format "2026-01-0%d 00:00:00" i)
                              :saved (format "2026-01-0%d 00:00:00" i)
                              :convos (list (list :session-id (format "s%d" i))))))
      (major-pane-workspace-save)
      (let ((snaps (major-pane-workspace--read)))
        (should (= (length snaps) 3))
        (should (equal (plist-get (car (plist-get (car snaps) :convos)) :session-id)
                       "sid-a"))
        ;; Oldest ones fall off, newest previous ones stay.
        (should (equal (mapcar (lambda (s)
                                 (plist-get (car (plist-get s :convos)) :session-id))
                               (cdr snaps))
                       '("s1" "s2")))))))

(ert-deftest major-pane-workspace-empty-pane-does-not-create-snapshot ()
  "No convos and no snapshot for this process yet: leave the file alone."
  (mpw-test--with-convos ()
    (major-pane-workspace--write
     (list (list :started "x" :saved "x" :convos (list (list :session-id "sid-prev")))))
    (major-pane-workspace-save)
    (let ((snaps (major-pane-workspace--read)))
      (should (= (length snaps) 1))
      (should (equal (plist-get (car (plist-get (car snaps) :convos)) :session-id)
                     "sid-prev")))))

;;; file path

(ert-deftest major-pane-workspace-file-resolves-no-littering-late ()
  "With no explicit file, the path follows no-littering even when that
variable only became bound after the module loaded."
  (let ((major-pane-workspace-file nil)
        (no-littering-var-directory "/tmp/mpw-var/"))
    (should (equal (major-pane-workspace--file)
                   "/tmp/mpw-var/major-pane/workspace.el"))))

(ert-deftest major-pane-workspace-explicit-file-wins ()
  "An explicit `major-pane-workspace-file' is used as-is."
  (let ((major-pane-workspace-file "/tmp/explicit.el")
        (no-littering-var-directory "/tmp/mpw-var/"))
    (should (equal (major-pane-workspace--file) "/tmp/explicit.el"))))

;;; default snapshot

(ert-deftest major-pane-workspace-default-snapshot-skips-own-process ()
  "After a restart the picker defaults to the previous process's snapshot,
not the one this process is writing."
  (let ((major-pane-workspace--boot "now")
        (snaps (list (list :started "now" :convos nil)
                     (list :started "before" :convos nil)
                     (list :started "older" :convos nil))))
    (should (equal (plist-get (major-pane-workspace--default-snapshot snaps) :started)
                   "before"))))

(ert-deftest major-pane-workspace-default-snapshot-falls-back-to-own ()
  "With no older snapshot on file, the current process's one is used."
  (let ((major-pane-workspace--boot "now")
        (snaps (list (list :started "now" :convos nil))))
    (should (equal (plist-get (major-pane-workspace--default-snapshot snaps) :started)
                   "now"))))

;;; live lookup

(ert-deftest major-pane-workspace-live-buffer-finds-open-session ()
  "An entry whose session is already open maps back to that buffer."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" nil nil))
    (should (equal (buffer-name (major-pane-workspace--live-buffer "sid-a"))
                   "Agent @ a"))
    (should-not (major-pane-workspace--live-buffer "sid-nope"))))

;;; resume dispatch

(ert-deftest major-pane-workspace-resume-entry-switches-when-open ()
  "Resuming an already-open session displays it instead of starting another."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" nil nil))
    (let (resumed displayed)
      (cl-letf (((symbol-function 'agent-shell-bookmark--resume)
                 (lambda (&rest args) (setq resumed args) nil))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buf &rest _) (setq displayed buf))))
        (major-pane-workspace--resume-entry
         (list :session-id "sid-a" :cwd "/tmp/a/" :agent "claude-code"))
        (should-not resumed)
        (should (equal (buffer-name displayed) "Agent @ a"))))))

(ert-deftest major-pane-workspace-resume-entry-resumes-when-closed ()
  "A closed session goes through the bookmark resume path with its fields."
  (mpw-test--with-convos ()
    (let (resumed)
      (cl-letf (((symbol-function 'agent-shell-bookmark--resume)
                 (lambda (&rest args) (setq resumed args) nil)))
        (major-pane-workspace--resume-entry
         (list :session-id "sid-z" :cwd "/tmp/z/" :agent "codex"))
        (should (equal resumed '("sid-z" "/tmp/z/" "codex")))))))

(ert-deftest major-pane-workspace-candidates-mark-open-sessions ()
  "Picker rows show label, project and agent, and flag open sessions."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/proj-a/" "claude-code" "alpha" nil))
    (let* ((snap (list :started "x" :saved "x"
                       :convos (list (list :session-id "sid-a" :cwd "/tmp/proj-a/"
                                           :agent "claude-code" :label "alpha")
                                     (list :session-id "sid-b" :cwd "/tmp/proj-b/"
                                           :agent "codex" :label nil
                                           :buffer-name "Agent @ b"))))
           (rows (mapcar #'car (major-pane-workspace--candidates snap))))
      (should (= (length rows) 2))
      (should (string-match-p "alpha" (car rows)))
      (should (string-match-p "proj-a" (car rows)))
      (should (string-match-p "open" (car rows)))
      (should (string-match-p "proj-b" (cadr rows)))
      (should-not (string-match-p "open" (cadr rows))))))

;;; transcripts (agent-recall integration)

(ert-deftest major-pane-workspace-collect-captures-transcript-from-index ()
  "When agent-recall's index knows the session, its transcript path is stored."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/a/" "claude-code" nil nil))
    (let ((agent-recall--index (make-hash-table :test 'equal)))
      (puthash "/tmp/a/.agent-shell/transcripts/t.md"
               (list :session-id "sid-a") agent-recall--index)
      (should (equal (plist-get (car (major-pane-workspace--collect)) :transcript)
                     "/tmp/a/.agent-shell/transcripts/t.md")))))

(ert-deftest major-pane-workspace-candidates-carry-transcript-payload ()
  "Rows carry the transcript path as the `agent-recall-file' text property
so agent-recall's embark actions (o/r/R) work on them."
  (mpw-test--with-convos ()
    (let* ((file (make-temp-file "mpw-transcript-" nil ".md"))
           (snap (list :started "x" :saved "x"
                       :convos (list (list :session-id "sid-a" :cwd "/tmp/a/"
                                           :agent "claude-code" :label "alpha"
                                           :transcript file))))
           (row (car (car (major-pane-workspace--candidates snap)))))
      (unwind-protect
          (should (equal (get-text-property 0 'agent-recall-file row) file))
        (delete-file file)))))

(ert-deftest major-pane-workspace-select-opens-transcript-when-known ()
  "Choosing a row with a transcript opens it like agent-recall browse does."
  (mpw-test--with-convos ()
    (let ((file (make-temp-file "mpw-transcript-" nil ".md"))
          opened resumed)
      (unwind-protect
          (cl-letf (((symbol-function 'agent-recall--open-transcript)
                     (lambda (f &rest _) (setq opened f)))
                    ((symbol-function 'agent-shell-bookmark--resume)
                     (lambda (&rest args) (setq resumed args) nil)))
            (major-pane-workspace--select-entry
             (list :session-id "sid-a" :cwd "/tmp/a/" :agent "claude-code"
                   :transcript file))
            (should (equal opened file))
            (should-not resumed))
        (delete-file file)))))

(ert-deftest major-pane-workspace-select-resumes-without-transcript ()
  "With no transcript on record, choosing a row falls back to resuming."
  (mpw-test--with-convos ()
    (let (resumed)
      (cl-letf (((symbol-function 'agent-shell-bookmark--resume)
                 (lambda (&rest args) (setq resumed args) nil)))
        (major-pane-workspace--select-entry
         (list :session-id "sid-a" :cwd "/tmp/a/" :agent "claude-code"))
        (should (equal resumed '("sid-a" "/tmp/a/" "claude-code")))))))

;;; agent-recall styling

(defmacro mpw-test--with-fake-agent-recall (&rest body)
  "Run BODY with the agent-recall formatting helpers stubbed in.
The stubs mimic browse's row recipe without loading the real package."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'agent-recall--index-entry-for-file)
              (lambda (_file) (list :project "proj-a"
                                    :timestamp "2026-09-06-15-10-46")))
             ((symbol-function 'agent-recall--provider-icon)
              (lambda (_file _entry) "A "))
             ((symbol-function 'agent-recall--display-timestamp)
              (lambda (_ts) "Sep 06 15:10:46"))
             ((symbol-function 'agent-recall--make-candidate)
              (lambda (display file &optional line kind)
                (propertize (copy-sequence display)
                            'agent-recall-file file
                            'agent-recall-line line
                            'agent-recall-origin-kind kind)))
             ((symbol-function 'agent-recall--disambiguate-candidates)
              #'identity))
     ,@body))

(ert-deftest major-pane-workspace-candidates-use-browse-recipe ()
  "With agent-recall present, rows look like browse rows: icon, project,
timestamp, label, plus the open marker, and carry the browse payload."
  (mpw-test--with-convos (("Agent @ a" "sid-a" "/tmp/proj-a/" "claude-code" "alpha" nil))
    (let ((file (make-temp-file "mpw-transcript-" nil ".md")))
      (unwind-protect
          (mpw-test--with-fake-agent-recall
            (let* ((snap (list :started "x" :saved "x"
                               :convos (list (list :session-id "sid-a"
                                                   :cwd "/tmp/proj-a/"
                                                   :agent "claude-code"
                                                   :label "alpha"
                                                   :transcript file))))
                   (row (car (car (major-pane-workspace--candidates snap)))))
              (should (equal (substring-no-properties row)
                             "A [proj-a] Sep 06 15:10:46  alpha  (open)"))
              (should (equal (get-text-property 0 'agent-recall-file row) file))
              (should (eq (get-text-property 0 'agent-recall-origin-kind row)
                          'browse))))
        (delete-file file)))))

(ert-deftest major-pane-workspace-resume-reads-through-agent-recall-picker ()
  "When agent-recall's browse reader exists, the picker goes through it and
the chosen row maps back to its entry."
  (mpw-test--with-convos ()
    (let ((file (make-temp-file "mpw-transcript-" nil ".md"))
          opened seen)
      (unwind-protect
          (mpw-test--with-fake-agent-recall
            (cl-letf (((symbol-function 'agent-recall--read-browse-candidate)
                       (lambda (candidates)
                         (setq seen candidates)
                         ;; Pick the last row (the only convo).
                         (car (last candidates))))
                      ((symbol-function 'agent-recall--open-transcript)
                       (lambda (f &rest _) (setq opened f))))
              (major-pane-workspace--write
               (list (list :started "x" :saved "x"
                           :convos (list (list :session-id "sid-a"
                                               :cwd "/tmp/proj-a/"
                                               :agent "claude-code"
                                               :label "alpha"
                                               :transcript file)))))
              (major-pane-workspace-resume)
              (should (= (length seen) 2))
              (should (string-prefix-p "[resume all 1]"
                                       (substring-no-properties (car seen))))
              (should (equal opened file))))
        (delete-file file)))))

(provide 'major-pane-workspace-test)
;;; major-pane-workspace-test.el ends here
