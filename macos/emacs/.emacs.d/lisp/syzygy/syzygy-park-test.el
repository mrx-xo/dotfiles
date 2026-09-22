;;; syzygy-park-test.el --- Tests for syzygy-park -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)

(defvar agent-recall--index nil)
(provide 'agent-recall)

;; The park module only needs the chat's mode and its ACP state.
(unless (fboundp 'agent-shell-mode)
  (define-derived-mode agent-shell-mode fundamental-mode "Agent"))
(defvar-local agent-shell--state nil)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "syzygy-bridge.el" dir) nil t)
  (load (expand-file-name "syzygy-recall.el" dir) nil t)
  (load (expand-file-name "syzygy-park.el" dir) nil t))

(defun syzygy-park-test--item (question &optional context origin)
  "Build the item plist the module stores for QUESTION."
  (list :question question :context context :origin origin))

(defmacro syzygy-park-test--with-chat (session-id &rest body)
  "Run BODY in a fake agent-shell chat with SESSION-ID and a temp park file.
The chat's project root is a fresh temp directory bound as `root'."
  (declare (indent 1))
  `(let* ((syzygy-park-file (make-temp-file "syzygy-park-" nil ".org"))
          (syzygy-park--project-items (make-hash-table :test #'equal))
          (root (file-name-as-directory (make-temp-file "syzygy-park-root-" t)))
          (chat (generate-new-buffer " *park-chat*")))
     (unwind-protect
         (with-current-buffer chat
           (agent-shell-mode)
           (setq default-directory root)
           (setq agent-shell--state (list :session (list :id ,session-id)))
           ,@body)
       (when-let ((org (find-buffer-visiting syzygy-park-file)))
         (with-current-buffer org (set-buffer-modified-p nil))
         (kill-buffer org))
       (delete-file syzygy-park-file)
       (delete-directory root t)
       (kill-buffer chat))))

(defmacro syzygy-park-test--with-file (&rest body)
  "Run BODY visiting a temp file inside a temp project root bound as `root'.
No chat exists, so parking lands on the project scope."
  (declare (indent 0))
  `(let* ((syzygy-park-file (make-temp-file "syzygy-park-" nil ".org"))
          (syzygy-park--project-items (make-hash-table :test #'equal))
          (root (file-name-as-directory (make-temp-file "syzygy-park-root-" t)))
          (file (expand-file-name "notes.txt" root))
          (buf (progn (with-temp-file file (insert "alpha\nbeta\ngamma\n"))
                      (find-file-noselect file))))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (when-let ((org (find-buffer-visiting syzygy-park-file)))
         (with-current-buffer org (set-buffer-modified-p nil))
         (kill-buffer org))
       (delete-file syzygy-park-file)
       (with-current-buffer buf (set-buffer-modified-p nil))
       (kill-buffer buf)
       (delete-directory root t))))

(defun syzygy-park-test--file-string ()
  "Return the park file's contents from disk."
  (with-temp-buffer
    (insert-file-contents syzygy-park-file)
    (buffer-string)))

(defun syzygy-park-test--list-text (list)
  "Return LIST's text, killing it after."
  (unwind-protect
      (with-current-buffer list (buffer-substring-no-properties (point-min) (point-max)))
    (kill-buffer list)))

(defmacro syzygy-park-test--on-line (list regexp &rest body)
  "In LIST, move point to the first line matching REGEXP and run BODY."
  (declare (indent 2))
  `(with-current-buffer ,list
     (goto-char (point-min))
     (re-search-forward ,regexp)
     ,@body))

(defun syzygy-park-test--open-list ()
  "Open the list without displaying it and return its buffer."
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (syzygy-park-list))
  (syzygy-park-list--buffer (syzygy-park--scopes-visible)))

;;; Chat scope

(ert-deftest syzygy-park-record-creates-heading-once-per-session ()
  "Two questions for one chat share a heading keyed by the session id."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why is X?")
    (syzygy-park "And Y?")
    (let ((text (syzygy-park-test--file-string)))
      (should (= 1 (length (seq-filter (lambda (l) (string-prefix-p "* " l))
                                       (split-string text "\n")))))
      (should (string-match-p "^:SESSION_ID: sess-1$" text))
      (should (string-match-p "^- \\[ \\] Why is X\\?$" text))
      (should (string-match-p "^- \\[ \\] And Y\\?$" text)))))

(ert-deftest syzygy-park-mark-asked-ticks-only-the-named-questions ()
  "Flushing some questions leaves the others open."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Q1")
    (syzygy-park "Q2")
    (syzygy-park--mark-asked syzygy-park-file '("SESSION_ID" . "sess-1") '("Q1"))
    (let ((text (syzygy-park-test--file-string)))
      (should (string-match-p "^- \\[X\\] Q1$" text))
      (should (string-match-p "^- \\[ \\] Q2$" text)))))

(ert-deftest syzygy-park-adds-to-chat-and-modeline ()
  "Parking in a chat stores the item on it and shows a mode-line count."
  (syzygy-park-test--with-chat "sess-1"
    (should (null (syzygy-park--modeline-indicator)))
    (syzygy-park "Why X?")
    (should (equal syzygy-park--questions (list (syzygy-park-test--item "Why X?"))))
    (should (string-suffix-p " 1" (syzygy-park--modeline-indicator)))
    (syzygy-park "Why Y?")
    (should (= 2 (length syzygy-park--questions)))
    ;; Batch has no nerd-icons, so the glyph falls back to a plain P.
    (should (equal (substring-no-properties (syzygy-park--modeline-indicator))
                   " P 2"))))

(ert-deftest syzygy-park-in-a-chat-has-no-origin ()
  "A chat is its own origin; nothing extra is recorded."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why?")
    (should (null (plist-get (car syzygy-park--questions) :origin)))
    (should-not (string-match-p "from:" (syzygy-park-test--file-string)))))

(ert-deftest syzygy-park-rejects-blank-question ()
  "An empty park is a mistake, not a record."
  (syzygy-park-test--with-chat "sess-1"
    (should-error (syzygy-park "   ") :type 'user-error)
    (should (null syzygy-park--questions))))

(ert-deftest syzygy-park-ask-with-nothing-parked-errors ()
  "Flushing an empty list must not fork a chat."
  (syzygy-park-test--with-chat "sess-1"
    (let ((forked nil))
      (cl-letf (((symbol-function 'syzygy-fork--run)
                 (lambda (_source) (setq forked t))))
        (should-error (syzygy-park-ask) :type 'user-error)
        (should-not forked)))))

(ert-deftest syzygy-park-ask-forks-and-sends-then-clears ()
  "Flushing forks the chat, sends one numbered prompt, and resets."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (let ((child (generate-new-buffer " *park-child*"))
          (sent nil)
          (shown nil))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-fork--run)
                     (lambda (source) (should (eq source chat)) child))
                    ((symbol-function 'syzygy-park--send-when-ready)
                     (lambda (buffer prompt)
                       (should (eq buffer child))
                       (setq sent prompt)))
                    ((symbol-function 'syzygy-park--display)
                     (lambda (_source buffer) (setq shown buffer))))
            (syzygy-park-ask)
            (should (eq shown child))
            (should (string-match-p "^1\\. Why X\\?$" sent))
            (should (string-match-p "^2\\. Why Y\\?$" sent))
            (should (null syzygy-park--questions))
            (should (null (syzygy-park--modeline-indicator)))
            (let ((text (syzygy-park-test--file-string)))
              (should (string-match-p "^- \\[X\\] Why X\\?$" text))
              (should (string-match-p "^- \\[X\\] Why Y\\?$" text))))
        (kill-buffer child)))))

(ert-deftest syzygy-park-ask-here-sends-into-the-same-chat ()
  "With HERE, the prompt goes into the current chat and nothing forks."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (let ((forked nil) (sent nil))
      (cl-letf (((symbol-function 'syzygy-fork--run)
                 (lambda (_source) (setq forked t)))
                ((symbol-function 'syzygy-park--send-here)
                 (lambda (buffer prompt)
                   (should (eq buffer chat))
                   (setq sent prompt))))
        (syzygy-park-ask t)
        (should-not forked)
        (should (string-match-p "^1\\. Why X\\?$" sent))
        (should (null syzygy-park--questions))))))

;;; Context

(ert-deftest syzygy-park-context-records-an-org-quote-block ()
  "Highlighted text lands under the checkbox as an indented quote block."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "line one\n\nline three\n")
    (syzygy-park "Plain one")
    (should (equal (plist-get (car syzygy-park--questions) :context)
                   "line one\n\nline three\n"))
    (should (string-match-p
             (concat "^- \\[ \\] Why this\\?\n"
                     "  #\\+begin_quote\n"
                     "  line one\n"
                     "  \n"
                     "  line three\n"
                     "  #\\+end_quote\n"
                     "- \\[ \\] Plain one\n")
             (syzygy-park-test--file-string)))))

(ert-deftest syzygy-park-context-drops-outer-blank-lines-keeps-indent ()
  "A region starting on a blank line quotes cleanly; inner indentation stays."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why?" "\n\n  indented\nplain\n\n")
    (should (string-match-p
             "  #\\+begin_quote\n    indented\n  plain\n  #\\+end_quote\n"
             (syzygy-park-test--file-string)))
    (should (string-match-p "^1\\. Why\\?\n   >   indented\n   > plain$"
                            (syzygy-park--prompt syzygy-park--questions)))))

(ert-deftest syzygy-park-blank-context-is-no-context ()
  "A whitespace-only region parks as a plain question."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why?" "  \n ")
    (should (null (plist-get (car syzygy-park--questions) :context)))
    (should-not (string-match-p "begin_quote" (syzygy-park-test--file-string)))))

(ert-deftest syzygy-park-interactive-takes-the-region-as-context ()
  "Calling park with an active region captures its text and clears it."
  (syzygy-park-test--with-chat "sess-1"
    ;; Batch runs without transient-mark-mode; `use-region-p' needs it.
    (let ((transient-mark-mode t))
      (insert "alpha\nbeta\ngamma\n")
      (goto-char (point-min))
      (push-mark (point) t t)
      (forward-line 2)
      (should (use-region-p))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (should (string-match-p "region" prompt))
                   "What is beta?")))
        (call-interactively #'syzygy-park))
      (should (equal (plist-get (car syzygy-park--questions) :context) "alpha\nbeta\n"))
      (should-not (use-region-p)))))

(ert-deftest syzygy-park-prompt-quotes-context-and-names-origin ()
  "The prompt shows the origin in parentheses and the context as a blockquote."
  (let ((prompt (syzygy-park--prompt
                 (list (syzygy-park-test--item "Why this?" "line one\nline two\n"
                                               '(:label "src/x.py:3-4" :link "file:/x.py::3" :url nil))
                       (syzygy-park-test--item "Plain one")
                       (syzygy-park-test--item "PR one" nil
                                               '(:label "mr-x/home-lab#32" :link "forgejo:mr-x/home-lab#32"
                                                        :url "https://omphalos.io/mr-x/home-lab/pulls/32"))))))
    (should (string-match-p
             "^1\\. Why this\\?\n   (src/x\\.py:3-4)\n   > line one\n   > line two\n2\\. Plain one\n3\\. PR one\n   (mr-x/home-lab#32 https://omphalos\\.io/mr-x/home-lab/pulls/32)$"
             prompt))))

;;; Project scope

(ert-deftest syzygy-park-from-a-file-lands-on-the-project-with-an-origin ()
  "Outside a chat the question goes under a PROJECT heading with a file origin."
  (syzygy-park-test--with-file
    (goto-char (point-min))
    (forward-line 1)
    (syzygy-park "What is beta?")
    (let ((items (syzygy-park--items (list :project root))))
      (should (= 1 (length items)))
      (should (equal (plist-get (plist-get (car items) :origin) :label) "notes.txt:2"))
      (should (string-prefix-p "file:" (plist-get (plist-get (car items) :origin) :link))))
    (let ((text (syzygy-park-test--file-string)))
      (should (string-match-p (concat "^:PROJECT: " (regexp-quote root) "$") text))
      (should (string-match-p "^- \\[ \\] What is beta\\?\n  from: \\[\\[file:.*notes\\.txt::2\\]\\[notes\\.txt:2\\]\\]$"
                              text)))
    (should (string-suffix-p " 1" (syzygy-park--modeline-indicator)))))

(ert-deftest syzygy-park-file-origin-covers-the-region-lines ()
  "A region origin names the first and last highlighted lines."
  (syzygy-park-test--with-file
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (push-mark (point) t t)
      (forward-line 2)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Why these?")))
        (call-interactively #'syzygy-park))
      (let ((item (car (syzygy-park--items (list :project root)))))
        (should (equal (plist-get (plist-get item :origin) :label) "notes.txt:1-2"))
        (should (equal (plist-get item :context) "alpha\nbeta\n"))))))

(ert-deftest syzygy-park-project-items-survive-a-restart ()
  "Open project items are read back from the org file when memory is empty."
  (syzygy-park-test--with-file
    (syzygy-park "Kept?" "some\n  code\n")
    (syzygy-park "Asked already")
    (syzygy-park--mark-asked syzygy-park-file (cons "PROJECT" root) '("Asked already"))
    ;; Simulate a restart: forget everything in memory.
    (clrhash syzygy-park--project-items)
    (let ((items (syzygy-park--items (list :project root))))
      (should (= 1 (length items)))
      (should (equal (plist-get (car items) :question) "Kept?"))
      (should (equal (plist-get (car items) :context) "some\n  code\n"))
      (should (equal (plist-get (plist-get (car items) :origin) :label) "notes.txt:1")))))

(ert-deftest syzygy-park-hydrate-parses-links-without-org-store ()
  "A plain origin line (no link) round-trips as a label."
  (let ((syzygy-park-file (make-temp-file "syzygy-park-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file syzygy-park-file
            (insert "* proj\n:PROPERTIES:\n:PROJECT: /tmp/proj/\n:END:\n"
                    "- [ ] one\n  from: *scratch*\n"
                    "- [X] done\n"
                    "- [ ] two\n"))
          (let ((items (syzygy-park--hydrate syzygy-park-file "PROJECT" "/tmp/proj/")))
            (should (equal (mapcar (lambda (i) (plist-get i :question)) items) '("one" "two")))
            (should (equal (plist-get (car items) :origin)
                           '(:label "*scratch*" :link nil :url nil)))))
      (delete-file syzygy-park-file))))

(ert-deftest syzygy-park-chat-sees-its-project-questions ()
  "A chat lists its own questions and the ones parked on its project."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Mine")
    (puthash root (list (syzygy-park-test--item "From the project" nil
                                                '(:label "x.py:3" :link "file:/x.py::3" :url nil)))
             syzygy-park--project-items)
    (should (= 2 (syzygy-park--count-here)))
    (let ((text (syzygy-park-test--list-text (syzygy-park-test--open-list))))
      (should (string-match-p "^1\\. Mine$" text))
      (should (string-match-p "^2\\. From the project\n   from: x\\.py:3$" text)))))

(ert-deftest syzygy-park-ask-from-a-file-picks-a-chat ()
  "Outside a chat, asking goes through the pane picker to a chat."
  (syzygy-park-test--with-file
    (syzygy-park "Why?")
    (let ((target (generate-new-buffer " *picked-chat*"))
          (sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'major-pane-pick-buffer)
                     (lambda (callback &rest _) (funcall callback target)))
                    ((symbol-function 'syzygy-park--send-here)
                     (lambda (buffer prompt) (should (eq buffer target)) (setq sent prompt))))
            (syzygy-park-ask t)
            (should (string-match-p "^1\\. Why\\?\n   (notes\\.txt:1)$" sent))
            (should (null (syzygy-park--items (list :project root))))
            (should (string-match-p "^- \\[X\\] Why\\?$" (syzygy-park-test--file-string))))
        (kill-buffer target)))))

;;; List buffer

(ert-deftest syzygy-park-list-shows-numbered-questions ()
  "The list buffer names the scope and numbers its parked questions."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (let ((text (syzygy-park-test--list-text (syzygy-park-test--open-list))))
      (should (string-match-p "^1\\. Why X\\?$" text))
      (should (string-match-p "^2\\. Why Y\\?$" text)))))

(ert-deftest syzygy-park-list-is-a-popper-candidate-mode ()
  "The list buffer runs its own mode so display rules can route it."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (let ((list (syzygy-park-test--open-list)))
      (unwind-protect
          (should (eq (buffer-local-value 'major-mode list) 'syzygy-park-list-mode))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-drop-removes-from-chat-and-file ()
  "Dropping a question at point forgets it everywhere and re-renders."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (let ((list (syzygy-park-test--open-list)))
      (unwind-protect
          (progn
            (syzygy-park-test--on-line list "Why X"
              (syzygy-park-list-drop))
            (should (equal (mapcar (lambda (i) (plist-get i :question)) syzygy-park--questions)
                           '("Why Y?")))
            (let ((text (syzygy-park-test--file-string)))
              (should-not (string-match-p "Why X" text))
              (should (string-match-p "^- \\[ \\] Why Y\\?$" text)))
            (with-current-buffer list
              (should-not (string-match-p "Why X" (buffer-string)))
              (should (string-match-p "^1\\. Why Y\\?$" (buffer-string)))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-drop-removes-the-context-block-too ()
  "Dropping a question with context deletes its quote block from the file."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "quoted line\n")
    (syzygy-park "Keep me")
    (let ((list (syzygy-park-test--open-list)))
      (unwind-protect
          (progn
            ;; Point on the context line, not the question line.
            (syzygy-park-test--on-line list "quoted line"
              (syzygy-park-list-drop))
            (should (= 1 (length syzygy-park--questions)))
            (let ((text (syzygy-park-test--file-string)))
              (should-not (string-match-p "Why this\\|quoted line\\|begin_quote" text))
              (should (string-match-p "^- \\[ \\] Keep me$" text))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-shows-context-dimmed ()
  "The list buffer shows a question's context indented under it."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "quoted line\n")
    (let ((text (syzygy-park-test--list-text (syzygy-park-test--open-list))))
      (should (string-match-p "^1\\. Why this\\?\n   quoted line\n" text)))))

(ert-deftest syzygy-park-list-ask-all-here-flushes-the-chat ()
  "Asking all from the list runs the chat's flush and empties the list."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (let ((list (syzygy-park-test--open-list))
          (asked nil))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-park--send-here)
                     (lambda (_buffer prompt) (setq asked prompt))))
            (with-current-buffer list (syzygy-park-list-ask-all-here))
            (should (string-match-p "Why X" asked))
            (should (null syzygy-park--questions))
            (with-current-buffer list
              (should (string-match-p "Nothing parked" (buffer-string)))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-ask-here-asks-only-the-question-at-point ()
  "Asking one question here sends just it, ticks just it, keeps the rest."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?" "some context\n")
    (let ((list (syzygy-park-test--open-list))
          (asked nil) (forked nil))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-park--send-here)
                     (lambda (buffer prompt) (should (eq buffer chat)) (setq asked prompt)))
                    ((symbol-function 'syzygy-fork--run)
                     (lambda (_source) (setq forked t))))
            ;; Point on the context line of the second question.
            (syzygy-park-test--on-line list "some context"
              (syzygy-park-list-ask-here))
            (should-not forked)
            (should (string-match-p "^1\\. Why Y\\?\n   > some context$" asked))
            (should-not (string-match-p "Why X" asked))
            (should (equal (mapcar (lambda (i) (plist-get i :question)) syzygy-park--questions)
                           '("Why X?")))
            (let ((text (syzygy-park-test--file-string)))
              (should (string-match-p "^- \\[ \\] Why X\\?$" text))
              (should (string-match-p "^- \\[X\\] Why Y\\?$" text)))
            (with-current-buffer list
              (should (string-match-p "^1\\. Why X\\?$" (buffer-string)))
              (should-not (string-match-p "Why Y" (buffer-string)))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-ask-fork-forks-for-one-question ()
  "Asking one question in a fork forks the chat and sends only that one."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (let ((list (syzygy-park-test--open-list))
          (child (generate-new-buffer " *park-child*"))
          (sent nil))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-fork--run)
                     (lambda (source) (should (eq source chat)) child))
                    ((symbol-function 'syzygy-park--send-when-ready)
                     (lambda (buffer prompt) (should (eq buffer child)) (setq sent prompt)))
                    ((symbol-function 'syzygy-park--display) #'ignore))
            (syzygy-park-test--on-line list "Why X"
              (syzygy-park-list-ask-fork))
            (should (string-match-p "^1\\. Why X\\?$" sent))
            (should-not (string-match-p "Why Y" sent))
            (should (equal (mapcar (lambda (i) (plist-get i :question)) syzygy-park--questions)
                           '("Why Y?"))))
        (kill-buffer child)
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-ask-one-project-question-from-a-chat ()
  "From a chat's list, asking a project question ticks the project heading."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Mine")
    ;; Park one on the project as if from a file in it.
    (syzygy-park--set-items (list :project root)
                            (list (syzygy-park-test--item "Project one")))
    (syzygy-park--record syzygy-park-file (cons "PROJECT" root) "proj"
                         (syzygy-park-test--item "Project one"))
    (let ((list (syzygy-park-test--open-list))
          (asked nil))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-park--send-here)
                     (lambda (buffer prompt) (should (eq buffer chat)) (setq asked prompt))))
            (syzygy-park-test--on-line list "Project one"
              (syzygy-park-list-ask-here))
            (should (string-match-p "Project one" asked))
            (should (null (syzygy-park--items (list :project root))))
            (should (= 1 (length syzygy-park--questions)))
            (let ((text (syzygy-park-test--file-string)))
              (should (string-match-p "^- \\[X\\] Project one$" text))
              (should (string-match-p "^- \\[ \\] Mine$" text))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-keys-live-under-C-c-only ()
  "The list must not shadow single-letter normal-state keys."
  ;; Letters resolve to whatever special-mode already has, nothing of ours.
  (dolist (key '("d" "a" "g" "h" "f" "q"))
    (should (eq (lookup-key syzygy-park-list-mode-map (kbd key))
                (lookup-key special-mode-map (kbd key)))))
  (should (eq (lookup-key syzygy-park-list-mode-map (kbd "C-c d")) #'syzygy-park-list-drop))
  (should (eq (lookup-key syzygy-park-list-mode-map (kbd "C-c h")) #'syzygy-park-list-ask-here))
  (should (eq (lookup-key syzygy-park-list-mode-map (kbd "C-c f")) #'syzygy-park-list-ask-fork))
  (should (eq (lookup-key syzygy-park-list-mode-map (kbd "C-c H")) #'syzygy-park-list-ask-all-here))
  (should (eq (lookup-key syzygy-park-list-mode-map (kbd "C-c F")) #'syzygy-park-list-ask-all-fork)))

(provide 'syzygy-park-test)
;;; syzygy-park-test.el ends here
