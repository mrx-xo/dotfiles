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

(defmacro syzygy-park-test--with-chat (session-id &rest body)
  "Run BODY in a fake agent-shell chat with SESSION-ID and a temp park file."
  (declare (indent 1))
  `(let ((syzygy-park-file (make-temp-file "syzygy-park-" nil ".org"))
         (chat (generate-new-buffer " *park-chat*")))
     (unwind-protect
         (with-current-buffer chat
           (agent-shell-mode)
           (setq agent-shell--state (list :session (list :id ,session-id)))
           ,@body)
       (when-let ((org (find-buffer-visiting syzygy-park-file)))
         (with-current-buffer org (set-buffer-modified-p nil))
         (kill-buffer org))
       (delete-file syzygy-park-file)
       (kill-buffer chat))))

(defun syzygy-park-test--file-string ()
  "Return the park file's contents from disk."
  (with-temp-buffer
    (insert-file-contents syzygy-park-file)
    (buffer-string)))

(ert-deftest syzygy-park-record-creates-heading-once-per-session ()
  "Two questions for one chat share a heading keyed by the session id."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park--record syzygy-park-file "sess-1" "My task" "Why is X?")
    (syzygy-park--record syzygy-park-file "sess-1" "My task" "And Y?")
    (let ((text (syzygy-park-test--file-string)))
      (should (= 1 (cl-count ?* (replace-regexp-in-string "[^*\n]" "" text))))
      (should (string-match-p "^\\* My task$" text))
      (should (string-match-p "^:SESSION_ID: sess-1$" text))
      (should (string-match-p "^- \\[ \\] Why is X\\?$" text))
      (should (string-match-p "^- \\[ \\] And Y\\?$" text)))))

(ert-deftest syzygy-park-record-keeps-sessions-apart ()
  "A second chat gets its own heading, not the first chat's list."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park--record syzygy-park-file "sess-1" "One" "Q1")
    (syzygy-park--record syzygy-park-file "sess-2" "Two" "Q2")
    (let ((text (syzygy-park-test--file-string)))
      (should (string-match-p "^\\* One$" text))
      (should (string-match-p "^\\* Two$" text))
      (should (< (string-match "Q1" text) (string-match "\\* Two" text))))))

(ert-deftest syzygy-park-mark-asked-ticks-only-that-session ()
  "Flushing one chat leaves another chat's parked questions open."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park--record syzygy-park-file "sess-1" "One" "Q1")
    (syzygy-park--record syzygy-park-file "sess-2" "Two" "Q2")
    (syzygy-park--mark-asked syzygy-park-file "sess-1")
    (let ((text (syzygy-park-test--file-string)))
      (should (string-match-p "^- \\[X\\] Q1$" text))
      (should (string-match-p "^- \\[ \\] Q2$" text)))))

(ert-deftest syzygy-park-prompt-numbers-questions ()
  "The flushed prompt is a numbered list the agent answers in order."
  (let ((prompt (syzygy-park--prompt '(("Why X?") ("Why Y?")))))
    (should (string-match-p "^1\\. Why X\\?$" prompt))
    (should (string-match-p "^2\\. Why Y\\?$" prompt))
    (should (< (string-match "1\\. Why X" prompt)
               (string-match "2\\. Why Y" prompt)))))

(ert-deftest syzygy-park-adds-to-chat-and-modeline ()
  "Parking stores the question on the chat and shows a mode-line count."
  (syzygy-park-test--with-chat "sess-1"
    (should (null (syzygy-park--modeline-indicator)))
    (syzygy-park "Why X?")
    (should (equal syzygy-park--questions '(("Why X?"))))
    (should (string-suffix-p " 1" (syzygy-park--modeline-indicator)))
    (syzygy-park "Why Y?")
    (should (equal syzygy-park--questions '(("Why X?") ("Why Y?"))))
    (should (string-suffix-p " 2" (syzygy-park--modeline-indicator)))
    ;; Batch has no nerd-icons, so the glyph falls back to a plain P.
    (should (equal (substring-no-properties (syzygy-park--modeline-indicator))
                   " P 2"))
    (should (string-match-p "Why Y\\?" (syzygy-park-test--file-string)))))

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

(defun syzygy-park-test--list-text ()
  "Return the list buffer's text for the current chat, killing it after."
  (let ((list (syzygy-park-list--buffer (current-buffer))))
    (unwind-protect
        (with-current-buffer list (buffer-substring-no-properties (point-min) (point-max)))
      (kill-buffer list))))

(ert-deftest syzygy-park-list-shows-numbered-questions ()
  "The list buffer names the chat and numbers its parked questions."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((text (syzygy-park-test--list-text)))
      (should (string-match-p "^1\\. Why X\\?$" text))
      (should (string-match-p "^2\\. Why Y\\?$" text)))))

(ert-deftest syzygy-park-list-is-a-popper-candidate-mode ()
  "The list buffer runs its own mode so display rules can route it."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer (current-buffer))))
      (unwind-protect
          (should (eq (buffer-local-value 'major-mode list) 'syzygy-park-list-mode))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-drop-removes-from-chat-and-file ()
  "Dropping a question at point forgets it everywhere and re-renders."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer chat)))
      (unwind-protect
          (progn
            (with-current-buffer list
              (goto-char (point-min))
              (re-search-forward "Why X")
              (syzygy-park-list-drop))
            (should (equal syzygy-park--questions '(("Why Y?"))))
            (let ((text (syzygy-park-test--file-string)))
              (should-not (string-match-p "Why X" text))
              (should (string-match-p "^- \\[ \\] Why Y\\?$" text)))
            (with-current-buffer list
              (should-not (string-match-p "Why X" (buffer-string)))
              (should (string-match-p "^1\\. Why Y\\?$" (buffer-string)))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-ask-all-here-flushes-the-chat ()
  "Asking all from the list runs the chat's flush and empties the list."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer chat))
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

(defmacro syzygy-park-test--on-line (list regexp &rest body)
  "In LIST, move point to the first line matching REGEXP and run BODY."
  (declare (indent 2))
  `(with-current-buffer ,list
     (goto-char (point-min))
     (re-search-forward ,regexp)
     ,@body))

(ert-deftest syzygy-park-list-ask-here-asks-only-the-question-at-point ()
  "Asking one question here sends just it, ticks just it, keeps the rest."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why X?")
    (syzygy-park "Why Y?" "some context\n")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer chat))
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
            (should (equal syzygy-park--questions '(("Why X?"))))
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
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer chat))
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
            (should (equal syzygy-park--questions '(("Why Y?")))))
        (kill-buffer child)
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

(ert-deftest syzygy-park-context-records-an-org-quote-block ()
  "Highlighted text lands under the checkbox as an indented quote block."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "line one\n\nline three\n")
    (syzygy-park "Plain one")
    (should (equal syzygy-park--questions
                   '(("Why this?" . "line one\n\nline three\n") ("Plain one"))))
    (let ((text (syzygy-park-test--file-string)))
      (should (string-match-p
               (concat "^- \\[ \\] Why this\\?\n"
                       "  #\\+begin_quote\n"
                       "  line one\n"
                       "  \n"
                       "  line three\n"
                       "  #\\+end_quote\n"
                       "- \\[ \\] Plain one\n")
               text)))))

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
    (should (equal syzygy-park--questions '(("Why?"))))
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
      (should (equal syzygy-park--questions '(("What is beta?" . "alpha\nbeta\n"))))
      (should-not (use-region-p)))))

(ert-deftest syzygy-park-prompt-quotes-context ()
  "The flushed prompt carries the context as a blockquote under its question."
  (let ((prompt (syzygy-park--prompt '(("Why this?" . "line one\nline two\n")
                                       ("Plain one")))))
    (should (string-match-p "^1\\. Why this\\?\n   > line one\n   > line two\n2\\. Plain one$"
                            prompt))))

(ert-deftest syzygy-park-drop-removes-the-context-block-too ()
  "Dropping a question with context deletes its quote block from the file."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "quoted line\n")
    (syzygy-park "Keep me")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((list (syzygy-park-list--buffer chat)))
      (unwind-protect
          (progn
            (with-current-buffer list
              (goto-char (point-min))
              ;; Point on the context line, not the question line.
              (re-search-forward "quoted line")
              (syzygy-park-list-drop))
            (should (equal syzygy-park--questions '(("Keep me"))))
            (let ((text (syzygy-park-test--file-string)))
              (should-not (string-match-p "Why this\\|quoted line\\|begin_quote" text))
              (should (string-match-p "^- \\[ \\] Keep me$" text))))
        (kill-buffer list)))))

(ert-deftest syzygy-park-list-shows-context-dimmed ()
  "The list buffer shows a question's context indented under it."
  (syzygy-park-test--with-chat "sess-1"
    (syzygy-park "Why this?" "quoted line\n")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (syzygy-park-list))
    (let ((text (syzygy-park-test--list-text)))
      (should (string-match-p "^1\\. Why this\\?\n   quoted line\n" text)))))

(ert-deftest syzygy-park-outside-a-chat-errors ()
  "Parking needs a chat to attach the question to."
  (with-temp-buffer
    (should-error (syzygy-park "Why?") :type 'user-error)))

(provide 'syzygy-park-test)
;;; syzygy-park-test.el ends here
