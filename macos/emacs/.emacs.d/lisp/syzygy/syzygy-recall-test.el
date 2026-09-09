;;; syzygy-recall-test.el --- Tests for syzygy-recall -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)

(defvar agent-recall--index nil)

;; `syzygy-recall' only needs these agent-recall entry points.  Supplying the
;; feature keeps this unit test independent from the user's installed package.
(provide 'agent-recall)

(load (expand-file-name "syzygy-recall.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun syzygy-recall-test--decode (encoded)
  "Decode ENCODED JSON returned by `syzygy-recall-transcripts-json'."
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist
   :array-type 'list))

(ert-deftest syzygy-recall-transcripts-json-includes-durable-label ()
  "A missing label field would make archived labels unsearchable on phone."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (unwind-protect
        (progn
          (puthash file
                   '(:project "syzygy" :timestamp "2026-09-01-12-00-00"
                     :preview "Search the archive" :session-id "session-1")
                   agent-recall--index)
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'syzygy-recall--resume-readiness)
                     (lambda (_file _entry) (cons t "")))
                    ((symbol-function 'agent-recall-catalogue-get) #'ignore)
                    ((symbol-function 'agent-recall-session-label)
                     (lambda (session-id)
                       (and (equal session-id "session-1") "Recall UX")))
                    ((symbol-function 'syzygy-recall--agent)
                     (lambda (_file) "Codex")))
            (let* ((rows (syzygy-recall-test--decode
                          (syzygy-recall-transcripts-json 1)))
                   (row (car rows)))
              (should (equal (alist-get 'label row) "Recall UX")))))
      (delete-file file))))

(ert-deftest syzygy-recall-transcripts-json-zero-limit-means-all ()
  "A zero LIMIT must export the complete index used by global search."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (files (list (make-temp-file "syzygy-recall-a-" nil ".md")
                     (make-temp-file "syzygy-recall-b-" nil ".md"))))
    (unwind-protect
        (progn
          (cl-loop for file in files
                   for n from 1
                   do (puthash file
                               `(:project "syzygy"
                                 :timestamp ,(format "2026-09-01-12-00-0%d" n)
                                 :preview "Conversation"
                                 :session-id ,(format "session-%d" n))
                               agent-recall--index))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'syzygy-recall--resume-readiness)
                     (lambda (_file _entry) (cons t "")))
                    ((symbol-function 'agent-recall-catalogue-get) #'ignore)
                    ((symbol-function 'agent-recall-session-label)
                     (lambda (_session-id) nil))
                    ((symbol-function 'syzygy-recall--agent)
                     (lambda (_file) "Codex")))
            (should (= (length (syzygy-recall-test--decode
                                (syzygy-recall-transcripts-json 0)))
                       2))))
      (mapc #'delete-file files))))

(ert-deftest syzygy-recall-sidecar-label-put-preserves-clear-tombstone ()
  "A live clear must override an older durable agent-recall label immediately."
  (let ((labels (make-hash-table :test #'equal)))
    (syzygy-recall-sidecar-label-put labels "session-1" nil)
    (should (equal (gethash "session-1" labels 'missing) ""))))

;;;; Catalogue bridges

(defmacro syzygy-recall-test--with-catalogue-stubs (store &rest body)
  "Run BODY with agent-recall's catalogue API stubbed over hash STORE.
STORE maps session id to a catalogue alist; the stubs mirror the real
API closely enough for the bridges: put returns the entry, remove drops
it, get returns nil for an unknown session."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
             ((symbol-function 'syzygy-recall--resume-readiness)
              (lambda (_file _entry) (cons t "")))
             ((symbol-function 'agent-recall-session-label) (lambda (_id) nil))
             ((symbol-function 'syzygy-recall--agent) (lambda (_file) "Claude"))
             ((symbol-function 'agent-recall-catalogue-get)
              (lambda (id) (gethash id ,store)))
             ((symbol-function 'agent-recall-catalogue-put)
              (lambda (id &rest args)
                (puthash id
                         (delq nil
                               (list (cons 'catalogued "2026-09-08T10:00:00+0000")
                                     (and (plist-get args :note)
                                          (cons 'note (plist-get args :note)))
                                     (and (plist-get args :tags)
                                          (cons 'tags (plist-get args :tags)))))
                         ,store)))
             ((symbol-function 'agent-recall-catalogue-remove)
              (lambda (id) (remhash id ,store) nil))
             ((symbol-function 'agent-recall-catalogue-tags) (lambda () nil)))
     ,@body))

(ert-deftest syzygy-recall-transcripts-json-carries-catalogue-fields ()
  "History rows need catalogued, note and tags to draw the chip and note."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (puthash "session-1" '((catalogued . "2026-09-08T10:00:00+0000")
                           (note . "why kept")
                           (tags . ("syzygy" "resume")))
             store)
    (unwind-protect
        (progn
          (puthash file
                   '(:project "syzygy" :timestamp "2026-09-01-12-00-00"
                     :preview "Search the archive" :session-id "session-1")
                   agent-recall--index)
          (syzygy-recall-test--with-catalogue-stubs store
            (let ((row (car (syzygy-recall-test--decode
                             (syzygy-recall-transcripts-json 1)))))
              (should (equal (alist-get 'catalogued row) "2026-09-08T10:00:00+0000"))
              (should (equal (alist-get 'note row) "why kept"))
              (should (equal (alist-get 'tags row) '("syzygy" "resume"))))))
      (delete-file file))))

(defun syzygy-recall-test--b64 (string)
  "Encode STRING as UTF-8 base64 without line breaks."
  (base64-encode-string (encode-coding-string string 'utf-8) t))

(ert-deftest syzygy-recall-catalogue-json-round-trip ()
  "Cataloguing must preserve the session, note and tags in its response."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-1") agent-recall--index)
          (syzygy-recall-test--with-catalogue-stubs store
            (let ((row (syzygy-recall-test--decode
                        (syzygy-recall-catalogue-json
                         (syzygy-recall-test--b64 "session-1")
                         (syzygy-recall-test--b64 "why kept")
                         (syzygy-recall-test--b64 "[\"Syzygy\",\"resume\"]")))))
              (should (equal (alist-get 'sessionId row) "session-1"))
              (should (equal (alist-get 'note row) "why kept"))
              (should (equal (alist-get 'tags row) '("Syzygy" "resume")))
              (should (stringp (alist-get 'catalogued row)))
              (should-not (equal (alist-get 'catalogued row) "")))))
      (delete-file file))))

(ert-deftest syzygy-recall-catalogue-json-non-ascii-note ()
  "Cataloguing must preserve every UTF-8 byte of a non-ASCII note."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md"))
        (note "por que — guardado"))
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-1") agent-recall--index)
          (syzygy-recall-test--with-catalogue-stubs store
            (let ((row (syzygy-recall-test--decode
                        (syzygy-recall-catalogue-json
                         (syzygy-recall-test--b64 "session-1")
                         (syzygy-recall-test--b64 note)))))
              (should (equal (alist-get 'note row) note))
              (should (equal (encode-coding-string (alist-get 'note row) 'utf-8)
                             (encode-coding-string note 'utf-8))))))
      (delete-file file))))

(ert-deftest syzygy-recall-catalogue-json-unknown-session ()
  "An unknown session must not create a catalogue entry."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal)))
    (syzygy-recall-test--with-catalogue-stubs store
      (should-not (syzygy-recall-catalogue-json
                   (syzygy-recall-test--b64 "session-1")))
      (should (= (hash-table-count store) 0)))))

(ert-deftest syzygy-recall-catalogue-json-optional-fields ()
  "Omitted note and tags must return an empty string and an empty list."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-1") agent-recall--index)
          (syzygy-recall-test--with-catalogue-stubs store
            (let ((row (syzygy-recall-test--decode
                        (syzygy-recall-catalogue-json
                         (syzygy-recall-test--b64 "session-1")))))
              (should (equal (alist-get 'note row) ""))
              (should (equal (alist-get 'tags row) '())))))
      (delete-file file))))

(ert-deftest syzygy-recall-uncatalogue-json-round-trip ()
  "Uncataloguing must clear the returned state and remove the stored entry."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-1") agent-recall--index)
          (puthash "session-1"
                   '((catalogued . "2026-09-08T10:00:00+0000")
                     (note . "why kept") (tags . ("Syzygy" "resume")))
                   store)
          (syzygy-recall-test--with-catalogue-stubs store
            (let ((row (syzygy-recall-test--decode
                        (syzygy-recall-uncatalogue-json
                         (syzygy-recall-test--b64 "session-1")))))
              (should (equal (alist-get 'catalogued row) ""))
              (should (equal (alist-get 'note row) ""))
              (should (eq (gethash "session-1" store 'missing) 'missing)))))
      (delete-file file))))

(ert-deftest syzygy-recall-uncatalogue-json-unknown-session ()
  "Uncataloguing an unknown session must return nil."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (store (make-hash-table :test #'equal)))
    (syzygy-recall-test--with-catalogue-stubs store
      (should-not (syzygy-recall-uncatalogue-json
                   (syzygy-recall-test--b64 "session-1"))))))

;;;; Phone pins

(ert-deftest syzygy-recall-orrery-pin-json-toggles ()
  "Toggling a phone pin must add it once and remove it on the next call."
  (let ((syzygy-orrery--pins nil)
        (buffer (generate-new-buffer "syzygy-pin-test")))
    (unwind-protect
        (let* ((name (buffer-name buffer))
               (encoded (syzygy-recall-test--b64 name))
               (row (syzygy-recall-test--decode
                     (syzygy-orrery-pin-json encoded))))
          (should (eq (alist-get 'pinned row) t))
          (should (equal (alist-get 'pins row) (list name)))
          (setq row (syzygy-recall-test--decode
                     (syzygy-orrery-pin-json encoded)))
          (should (eq (alist-get 'pinned row) :false))
          (should (equal (alist-get 'pins row) '())))
      (kill-buffer buffer))))

(ert-deftest syzygy-recall-orrery-pin-json-explicit-actions ()
  "Repeated explicit pins must not duplicate entries, and unpin must remove them."
  (let ((syzygy-orrery--pins nil)
        (buffer (generate-new-buffer "syzygy-pin-test")))
    (unwind-protect
        (let* ((name (buffer-name buffer))
               (encoded (syzygy-recall-test--b64 name)))
          (dotimes (_ 2)
            (let ((row (syzygy-recall-test--decode
                        (syzygy-orrery-pin-json encoded "pin"))))
              (should (eq (alist-get 'pinned row) t))
              (should (equal (alist-get 'pins row) (list name)))
              (should (equal syzygy-orrery--pins (list name)))))
          (let ((row (syzygy-recall-test--decode
                      (syzygy-orrery-pin-json encoded "unpin"))))
            (should (eq (alist-get 'pinned row) :false))
            (should (equal (alist-get 'pins row) '()))
            (should-not syzygy-orrery--pins)))
      (kill-buffer buffer))))

(ert-deftest syzygy-recall-orrery-pin-json-unknown-buffer ()
  "An unknown buffer must not become a phone pin."
  (let ((syzygy-orrery--pins nil)
        (name (generate-new-buffer-name "syzygy-pin-test-missing")))
    (should-not (get-buffer name))
    (should-not (syzygy-orrery-pin-json (syzygy-recall-test--b64 name)))
    (should-not syzygy-orrery--pins)))

(ert-deftest syzygy-recall-orrery-pin-json-report-drops-killed-buffer ()
  "Reporting phone pins must retain live buffers and discard killed buffers."
  (let ((syzygy-orrery--pins nil)
        (buffer (generate-new-buffer "syzygy-pin-test")))
    (unwind-protect
        (let ((name (buffer-name buffer)))
          (syzygy-orrery-pin-json (syzygy-recall-test--b64 name) "pin")
          (let ((row (syzygy-recall-test--decode (syzygy-orrery-pin-json))))
            (should (equal (alist-get 'pins row) (list name))))
          (kill-buffer buffer)
          (let ((row (syzygy-recall-test--decode (syzygy-orrery-pin-json))))
            (should (equal (alist-get 'pins row) '()))
            (should-not syzygy-orrery--pins)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;;; Mac-side strict resume

(ert-deftest syzygy-recall-strict-start-resume-routes-catalogued ()
  "A catalogued chat resumed on the Mac must take the strict path, never fallback."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md"))
        (syzygy-recall--starting-session-id nil)
        (syzygy-recall-strict-resume-predicate (lambda (id _file) (equal id "kept")))
        strict original)
    (unwind-protect
        (progn
          (puthash file '(:project "p" :timestamp "2026-09-01-12-00-00"
                          :session-id "kept")
                   agent-recall--index)
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'syzygy-recall-resume-strict)
                     (lambda (f) (setq strict f) 'strict-buffer)))
            (let ((orig (lambda (&rest args) (setq original args) 'plain-buffer)))
              ;; Catalogued and indexed: strict.
              (should (eq 'strict-buffer
                          (syzygy-recall--strict-start-resume orig "kept" file)))
              (should (equal strict file))
              (should-not original)
              ;; Not catalogued: agent-recall's own path.
              (should (eq 'plain-buffer
                          (syzygy-recall--strict-start-resume orig "other" file)))
              (should (equal original (list "other" file)))
              ;; Already inside a strict resume: no recursion.
              (setq original nil)
              (let ((syzygy-recall--starting-session-id "kept"))
                (should (eq 'plain-buffer
                            (syzygy-recall--strict-start-resume orig "kept" file))))
              (should (equal original (list "kept" file))))))
      (delete-file file))))

(provide 'syzygy-recall-test)
;;; syzygy-recall-test.el ends here

;;;; Phone fork

(defvar major-pane--labels)

(ert-deftest syzygy-fork-json-rejects-non-chat-buffers ()
  "Unknown names and live non-agent buffers must return nil."
  (let ((missing (generate-new-buffer-name "syzygy-fork-test-missing"))
        (buffer (generate-new-buffer "syzygy-fork-test-plain")))
    (unwind-protect
        (progn
          (should-not (get-buffer missing))
          (should-not (syzygy-fork-json (syzygy-recall-test--b64 missing)))
          (with-current-buffer buffer
            (setq-local major-mode 'fundamental-mode))
          (should-not
           (syzygy-fork-json
            (syzygy-recall-test--b64 (buffer-name buffer)))))
      (kill-buffer buffer))))

(ert-deftest syzygy-fork-json-probe ()
  "Probing reports support without trying to fork."
  (let ((buffer (generate-new-buffer "syzygy-fork-test-probe")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local major-mode 'agent-shell-mode))
          (cl-letf (((symbol-function 'agent-shell-fork)
                     (lambda () (ert-fail "Probe attempted to fork"))))
            (dolist (supported '(t nil))
              (with-current-buffer buffer
                (setq-local agent-shell--state
                            (list (cons :supports-session-fork supported)
                                  '(:session . ((:id . "sess-1"))))))
              (let ((row (syzygy-recall-test--decode
                          (syzygy-fork-json
                           (syzygy-recall-test--b64 (buffer-name buffer)) t))))
                (should (eq (alist-get 'ok row) t))
                (should (eq (alist-get 'supported row)
                            (if supported t :false)))
                (should (equal (alist-get 'bufferName row)
                               (buffer-name buffer)))))))
      (kill-buffer buffer))))

(ert-deftest syzygy-fork-json-unsupported ()
  "Unsupported forks return an error without creating a buffer."
  (let ((buffer (generate-new-buffer "syzygy-fork-test-unsupported")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local major-mode 'agent-shell-mode)
            (setq-local agent-shell--state
                        '((:supports-session-fork . nil)
                          (:session . ((:id . "sess-1"))))))
          (cl-letf (((symbol-function 'agent-shell-fork)
                     (lambda () (ert-fail "Unsupported agent was forked"))))
            (let* ((existing (buffer-list))
                   (row (syzygy-recall-test--decode
                         (syzygy-fork-json
                          (syzygy-recall-test--b64 (buffer-name buffer))))))
              (should (eq (alist-get 'ok row) :false))
              (should (eq (alist-get 'supported row) :false))
              (should (stringp (alist-get 'error row)))
              (should-not (equal (alist-get 'error row) ""))
              (should-not (cl-set-difference (buffer-list) existing)))))
      (kill-buffer buffer))))

(ert-deftest syzygy-fork-json-no-session-yet ()
  "A supported chat whose session has not initialised cannot be forked."
  (let ((buffer (generate-new-buffer "syzygy-fork-test-early")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local major-mode 'agent-shell-mode)
            (setq-local agent-shell--state '((:supports-session-fork . t))))
          (cl-letf (((symbol-function 'syzygy-fork--request)
                     (lambda (&rest _) (ert-fail "Fork requested without a session"))))
            (let ((row (syzygy-recall-test--decode
                        (syzygy-fork-json
                         (syzygy-recall-test--b64 (buffer-name buffer))))))
              (should (eq (alist-get 'ok row) :false))
              (should (eq (alist-get 'supported row) t))
              (should (equal (alist-get 'error row) "No active session to fork")))))
      (kill-buffer buffer))))

(ert-deftest syzygy-fork-json-round-trip ()
  "Fork through the source's client, resume the new id, carry the label."
  (let ((source (generate-new-buffer "syzygy-fork-test-source"))
        (major-pane--labels (make-hash-table :test #'eq))
        (requested nil)
        (start-args nil)
        new)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local major-mode 'agent-shell-mode)
            (setq-local default-directory "/tmp/")
            (setq-local agent-shell--state
                        '((:supports-session-fork . t)
                          (:agent-config . ((:name . "Fake")))
                          (:session . ((:id . "sess-1"))))))
          (puthash source "Lab" major-pane--labels)
          (should-not (fboundp 'mr-x/agent-spawn--send-when-ready))
          (should-not (fboundp 'mr-x/agent-shell--clone-config))
          (cl-letf (((symbol-function 'syzygy-fork--request)
                     (lambda (buffer)
                       (should (eq buffer source))
                       (setq requested t)
                       "sess-2"))
                    ((symbol-function 'agent-shell--start)
                     (lambda (&rest args)
                       (setq start-args args)
                       (should (equal default-directory "/tmp/"))
                       (setq new (generate-new-buffer "syzygy-fork-test-new"))
                       new))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _) (ert-fail "Fork scheduled a timer"))))
            (let ((row (syzygy-recall-test--decode
                        (syzygy-fork-json
                         (syzygy-recall-test--b64 (buffer-name source))))))
              (should requested)
              (should (equal (plist-get start-args :session-id) "sess-2"))
              (should (equal (plist-get start-args :config) '((:name . "Fake"))))
              (should (eq (plist-get start-args :no-focus) t))
              (should (eq (plist-get start-args :new-session) t))
              (should (eq (alist-get 'ok row) t))
              (should (eq (alist-get 'supported row) t))
              (should (equal (alist-get 'forkedFrom row) (buffer-name source)))
              (should (equal (alist-get 'bufferName row) (buffer-name new)))
              (should (equal (gethash new major-pane--labels) "Lab fork"))
              (should (equal (gethash source major-pane--labels) "Lab")))))
      (when (buffer-live-p new)
        (kill-buffer new))
      (kill-buffer source))))

(ert-deftest syzygy-fork-json-request-failure-is-structured ()
  "An agent refusal comes back as ok false with its message, no new chat."
  (let ((source (generate-new-buffer "syzygy-fork-test-refused")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local major-mode 'agent-shell-mode)
            (setq-local agent-shell--state
                        '((:supports-session-fork . t)
                          (:session . ((:id . "sess-1"))))))
          (cl-letf (((symbol-function 'syzygy-fork--request)
                     (lambda (_) (error "Fork failed: nope")))
                    ((symbol-function 'agent-shell--start)
                     (lambda (&rest _) (ert-fail "Started a chat after a refusal"))))
            (let ((row (syzygy-recall-test--decode
                        (syzygy-fork-json
                         (syzygy-recall-test--b64 (buffer-name source))))))
              (should (eq (alist-get 'ok row) :false))
              (should (equal (alist-get 'error row) "Fork failed: nope")))))
      (kill-buffer source))))

(ert-deftest syzygy-fork-request-timeout-retires-active-request ()
  "An unanswered fork must not leave the source chat looking busy."
  (let ((source (generate-new-buffer "syzygy-fork-test-timeout"))
        (syzygy-fork-timeout 0.1))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local major-mode 'agent-shell-mode)
            (setq-local agent-shell--state
                        (list '(:session . ((:id . "sess-1")))
                              '(:client . ((:process . nil)))
                              '(:active-requests . nil))))
          (cl-letf (((symbol-function 'agent-shell--state)
                     (lambda () agent-shell--state))
                    ((symbol-function 'acp-make-session-fork-request)
                     (lambda (&rest args) (cons 'fork-request args)))
                    ((symbol-function 'agent-shell--resolve-path) #'identity)
                    ((symbol-function 'agent-shell-cwd) (lambda () "/tmp/"))
                    ((symbol-function 'agent-shell--mcp-servers) (lambda () nil))
                    ((symbol-function 'agent-shell--send-request)
                     (cl-function
                      (lambda (&key state request &allow-other-keys)
                        ;; What agent-shell does on send; nothing ever replies.
                        (map-put! state :active-requests
                                  (cons request (map-elt state :active-requests)))))))
            (let ((err (should-error (syzygy-fork--request source))))
              (should (string-match-p "timed out" (error-message-string err))))
            (should-not (map-elt (buffer-local-value 'agent-shell--state source)
                                 :active-requests))))
      (kill-buffer source))))
