;;; syzygy-park.el --- Park a question, ask it later in one fork -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Reading a long agent reply, a side question comes up.  Asking it
;; now muddies the thread; forking now leaves a stray chat to track.
;; So: park it.  `syzygy-park' (SPC c u p) takes one line from the
;; minibuffer, keeps it on the chat, and writes it to
;; `syzygy-park-file' under a heading keyed by the chat's session id.
;; With a region active, the highlighted text rides along as the
;; question's context: an org quote block under the checkbox, a
;; markdown blockquote in the flushed prompt.  The mode line shows a
;; parking sign and the count, so it lives on screen instead of in
;; working memory.  `syzygy-park-list' (SPC c u l) pops the chat's
;; parked questions in a popper buffer.  Its keys sit under C-c so no
;; evil normal-state letter changes meaning there: on the question at
;; point, `C-c h' asks it here, `C-c f' in a fork, `C-c d' drops it;
;; for all of them, `C-c H' here and `C-c F' in one fork.
;;
;; When the main task lands, `syzygy-park-ask' (SPC c u a) forks the
;; chat once through `syzygy-fork--run' and sends every parked
;; question as one numbered prompt into the child, which has the full
;; history.  With a prefix argument the prompt goes into the current
;; chat instead.  Either way the list clears and the org items are
;; ticked.  The org file is the durable copy: a chat that dies
;; unflushed still leaves its questions next to a session id that
;; agent-recall can resume.
;;
;; NOTE: loaded from agent-shell-config.el; must not hard-require
;; agent-shell (see syzygy.el).

;;; Code:

(require 'map)
(require 'org)
(require 'syzygy-recall)

(declare-function agent-shell--current-shell "agent-shell")
(declare-function agent-shell-insert "agent-shell" t)
(declare-function shell-maker-busy "shell-maker")
(declare-function mr-x/agent-shell--display-new "agent-shell-config" (shell-buffer))
(declare-function mr-x/agent-spawn--send-when-ready "agent-shell-config"
                  (buf task tries))

(defgroup syzygy-park nil
  "Park questions on a chat and ask them later in one fork."
  :group 'syzygy)

(defcustom syzygy-park-file
  (locate-user-emacs-file "var/syzygy/parked-questions.org")
  "Org file that keeps every parked question.
One heading per chat, carrying the ACP session id as a property; one
checkbox item per question, with the highlighted context, if any, as a
quote block under it.  Per-machine on purpose: session ids are."
  :type 'file)

(defcustom syzygy-park-prompt-preamble
  "Parked questions from the main thread. Answer each in order, briefly, \
using the conversation so far for context. A quoted block under a \
question is the passage it is about."
  "Text that opens the flushed prompt, before the numbered questions."
  :type 'string)

(defvar-local syzygy-park--questions nil
  "Questions parked on this chat, oldest first.
Each is (QUESTION . CONTEXT): CONTEXT is the text that was highlighted
when the question was parked, or nil.")

(defun syzygy-park--chat ()
  "Return the chat buffer the current buffer stands for, or signal."
  (let ((buffer (or (and (fboundp 'agent-shell--current-shell)
                         (agent-shell--current-shell))
                    (current-buffer))))
    (unless (and (buffer-live-p buffer)
                 (eq (buffer-local-value 'major-mode buffer) 'agent-shell-mode))
      (user-error "Not in an agent-shell chat"))
    buffer))

(defun syzygy-park--label (buffer)
  "Return BUFFER's pane label when it has one, else its name."
  (or (and (boundp 'major-pane--labels)
           (gethash buffer major-pane--labels))
      (buffer-name buffer)))

(defface syzygy-park-modeline
  '((t :inherit warning))
  "Face for the parked-questions indicator in the mode line."
  :group 'syzygy-park)

(declare-function nerd-icons-mdicon "nerd-icons" (icon-name &rest args))
(declare-function evil-define-key "evil-core" (state keymap key def &rest bindings))

(defun syzygy-park--icon ()
  "Return the parking sign glyph, or a plain P when nerd-icons is absent."
  (if (fboundp 'nerd-icons-mdicon)
      (nerd-icons-mdicon "nf-md-parking" :face 'syzygy-park-modeline)
    (propertize "P" 'face 'syzygy-park-modeline)))

(defun syzygy-park--modeline-indicator ()
  "Mode-line indicator for the current chat: the parking sign and a count.
Nil when nothing is parked.  Click asks the parked questions in a fork."
  (let ((n (length syzygy-park--questions)))
    (when (> n 0)
      (concat " " (syzygy-park--icon)
              (propertize (format " %d" n)
                          'face 'syzygy-park-modeline
                          'help-echo (format "%d parked question%s: click to ask in a fork (SPC c u a)"
                                             n (if (= n 1) "" "s"))
                          'mouse-face 'mode-line-highlight
                          'local-map (let ((map (make-sparse-keymap)))
                                       (define-key map [mode-line mouse-1]
                                                   #'syzygy-park-ask)
                                       map))))))

(defun syzygy-park--refresh (buffer)
  "Redraw the mode line and BUFFER's open list, if any, after a change."
  (force-mode-line-update t)
  (syzygy-park-list--refresh buffer))

;;; Org persistence

(defun syzygy-park--with-file (file fn)
  "Visit FILE as org, call FN there, save, return FN's value.
Creates the file's directory when missing."
  (make-directory (file-name-directory (expand-file-name file)) t)
  (with-current-buffer (find-file-noselect file)
    (unless (derived-mode-p 'org-mode) (org-mode))
    (prog1 (save-excursion (funcall fn))
      (let ((inhibit-message t)) (save-buffer)))))

(defun syzygy-park--goto-heading (session-id)
  "Move to the heading for SESSION-ID and return point, or nil."
  (when-let ((pos (org-find-property "SESSION_ID" session-id)))
    (goto-char pos)))

(defun syzygy-park--indent (text n)
  "Return TEXT with every line indented by N spaces."
  (let ((pad (make-string n ?\s)))
    (mapconcat (lambda (line) (concat pad line))
               (split-string text "\n")
               "\n")))

(defun syzygy-park--context-lines (context)
  "Return CONTEXT as a list of lines, blank lines at either end dropped.
Indentation inside is kept: highlighted code should quote as written."
  (split-string (string-trim context "\n+" "[ \t\n]+") "\n"))

(defun syzygy-park--item (question context)
  "Return the org list item for QUESTION, with CONTEXT quoted under it."
  (concat (format "- [ ] %s\n" question)
          (when context
            (concat "  #+begin_quote\n"
                    (syzygy-park--indent
                     (string-join (syzygy-park--context-lines context) "\n") 2)
                    "\n  #+end_quote\n"))))

(defun syzygy-park--record (file session-id label question &optional context)
  "Append QUESTION under SESSION-ID's heading in FILE, titled LABEL when new.
CONTEXT, when given, follows the item as an org quote block."
  (syzygy-park--with-file
   file
   (lambda ()
     (if (syzygy-park--goto-heading session-id)
         (progn (org-end-of-subtree t t)
                (unless (bolp) (insert "\n")))
       (goto-char (point-max))
       (unless (or (bobp) (bolp)) (insert "\n"))
       (insert (format "* %s\n:PROPERTIES:\n:SESSION_ID: %s\n:END:\n"
                       label session-id)))
     (insert (syzygy-park--item question context)))))

(defun syzygy-park--mark-asked (file session-id &optional questions)
  "Tick open checkboxes under SESSION-ID's heading in FILE.
All of them, or only those whose text is in QUESTIONS when given."
  (syzygy-park--with-file
   file
   (lambda ()
     (when (syzygy-park--goto-heading session-id)
       (let ((end (save-excursion (org-end-of-subtree t t) (point))))
         (while (re-search-forward "^- \\[ \\] \\(.*\\)$" end t)
           (when (or (null questions) (member (match-string 1) questions))
             (replace-match "- [X] \\1" t))))))))

(defun syzygy-park--unrecord (file session-id question)
  "Delete the open item for QUESTION under SESSION-ID's heading in FILE.
Takes the item's indented body (the quoted context) with it."
  (syzygy-park--with-file
   file
   (lambda ()
     (when (syzygy-park--goto-heading session-id)
       (let ((end (save-excursion (org-end-of-subtree t t) (point)))
             (item (concat "^- \\[ \\] " (regexp-quote question) "$")))
         (when (re-search-forward item end t)
           (let ((start (line-beginning-position)))
             (forward-line 1)
             ;; The item's body is every following line indented under
             ;; it; `syzygy-park--item' pads blank lines too.
             (while (and (< (point) end) (looking-at "^  "))
               (forward-line 1))
             (delete-region start (point)))))))))

;;; Commands

(defun syzygy-park--region-context ()
  "Return the active region's text and deactivate it, or nil."
  (when (use-region-p)
    (prog1 (buffer-substring-no-properties (region-beginning) (region-end))
      (deactivate-mark))))

;;;###autoload
(defun syzygy-park (question &optional context)
  "Park QUESTION on the current chat to ask later.
Interactively, an active region becomes CONTEXT: the passage the
question is about.  Nothing is sent to the agent.  The mode line shows
the parked count and `syzygy-park-file' keeps the durable copy."
  (interactive
   (let ((context (syzygy-park--region-context)))
     (list (read-string (if context "Park question about region: " "Park question: "))
           context)))
  (let ((buffer (syzygy-park--chat))
        (question (string-trim question))
        (context (and context (not (string-blank-p context)) context)))
    (when (string-empty-p question)
      (user-error "Nothing to park"))
    (with-current-buffer buffer
      (setq syzygy-park--questions
            (append syzygy-park--questions (list (cons question context))))
      (when-let ((session-id (syzygy-fork--session-id buffer)))
        (syzygy-park--record syzygy-park-file session-id
                             (syzygy-park--label buffer) question context))
      (syzygy-park--refresh buffer)
      (message "Parked (%d)%s" (length syzygy-park--questions)
               (if context " with the highlighted text" "")))))

(defun syzygy-park--prompt (questions)
  "Return the prompt that asks QUESTIONS as one numbered list.
Each element is (QUESTION . CONTEXT); a context becomes a blockquote
under its question."
  (concat syzygy-park-prompt-preamble "\n\n"
          (mapconcat
           (lambda (pair)
             (let ((n (car pair)) (q (cadr pair)) (ctx (cddr pair)))
               (concat (format "%d. %s" n q)
                       (when ctx
                         (concat "\n"
                                 (mapconcat (lambda (line) (concat "   > " line))
                                            (syzygy-park--context-lines ctx)
                                            "\n"))))))
           (seq-map-indexed (lambda (item i) (cons (1+ i) item)) questions)
           "\n")))

(defun syzygy-park--send-when-ready (buffer prompt)
  "Submit PROMPT in BUFFER once its ACP session exists."
  (if (fboundp 'mr-x/agent-spawn--send-when-ready)
      (run-at-time 1 nil #'mr-x/agent-spawn--send-when-ready buffer prompt 60)
    (with-current-buffer buffer
      (agent-shell-insert :text prompt :submit t :no-focus t))))

(defun syzygy-park--send-here (buffer prompt)
  "Submit PROMPT in BUFFER now, or leave it in the input when BUFFER is busy."
  (with-current-buffer buffer
    (let ((busy (and (fboundp 'shell-maker-busy) (shell-maker-busy))))
      (agent-shell-insert :text prompt :submit (not busy) :no-focus t)
      (when busy
        (message "Chat is busy: parked questions inserted, submit when it is done")))))

(defun syzygy-park--display (source buffer)
  "Show BUFFER the way a fork from SOURCE is shown."
  (if (fboundp 'mr-x/agent-shell--display-new)
      (with-current-buffer source
        (mr-x/agent-shell--display-new buffer))
    (pop-to-buffer buffer)))

(defun syzygy-park--flush (buffer items here)
  "Ask ITEMS, a subset of BUFFER's parked questions, then forget them.
HERE sends the prompt into BUFFER; otherwise into one fresh fork of it.
The org items get ticked, the mode line and any open list redraw."
  (unless items
    (user-error "Nothing parked on this chat"))
  (let ((prompt (syzygy-park--prompt items))
        (session-id (syzygy-fork--session-id buffer)))
    (if here
        (syzygy-park--send-here buffer prompt)
      (let ((child (syzygy-fork--run buffer)))
        (syzygy-park--send-when-ready child prompt)
        (syzygy-park--display buffer child)))
    (with-current-buffer buffer
      (setq syzygy-park--questions
            (seq-remove (lambda (item) (member item items))
                        syzygy-park--questions)))
    (when session-id
      (syzygy-park--mark-asked syzygy-park-file session-id (mapcar #'car items)))
    (syzygy-park--refresh buffer)
    (message "Asked %d parked question%s%s"
             (length items)
             (if (= 1 (length items)) "" "s")
             (if here "" " in a fork"))))

;;;###autoload
(defun syzygy-park-ask (&optional here)
  "Ask every parked question in one fork of the current chat.
With HERE (prefix argument) send them into the current chat instead.
Clears the parked list and ticks the org items either way."
  (interactive "P")
  (let ((buffer (syzygy-park--chat)))
    (syzygy-park--flush buffer
                        (buffer-local-value 'syzygy-park--questions buffer)
                        here)))

;;; List buffer

(defvar-local syzygy-park-list--chat nil
  "The chat buffer this list shows.")

(defvar syzygy-park-list-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Everything under C-c: no single letters, so evil's normal-state
    ;; keys (d, a, g, ...) keep meaning what they mean everywhere else.
    (define-key map (kbd "C-c h") #'syzygy-park-list-ask-here)
    (define-key map (kbd "C-c f") #'syzygy-park-list-ask-fork)
    (define-key map (kbd "C-c H") #'syzygy-park-list-ask-all-here)
    (define-key map (kbd "C-c F") #'syzygy-park-list-ask-all-fork)
    (define-key map (kbd "C-c d") #'syzygy-park-list-drop)
    (define-key map (kbd "C-c g") #'syzygy-park-list-revert)
    map)
  "Keymap for `syzygy-park-list-mode'.")

(define-derived-mode syzygy-park-list-mode special-mode "Parked"
  "Read-only list of one chat's parked questions.
On the question at point: `C-c h' asks it here, `C-c f' asks it in a
fork, `C-c d' drops it.  For all of them: `C-c H' here, `C-c F' in one
fork.  `C-c g' redraws, `q' closes."
  (setq truncate-lines nil))

(with-eval-after-load 'evil
  (evil-define-key 'normal syzygy-park-list-mode-map
    (kbd "q") #'quit-window
    (kbd "<escape>") #'quit-window))

(defun syzygy-park-list--name (chat)
  "Return the list buffer name for CHAT."
  (format "*Parked: %s*" (syzygy-park--label chat)))

(defun syzygy-park-list--buffer (chat)
  "Return CHAT's live list buffer, or nil."
  (seq-find (lambda (b)
              (and (eq (buffer-local-value 'major-mode b) 'syzygy-park-list-mode)
                   (eq (buffer-local-value 'syzygy-park-list--chat b) chat)))
            (buffer-list)))

(defun syzygy-park-list--render (list chat)
  "Fill LIST with CHAT's parked questions, one numbered entry each.
A question's context follows it, indented and dimmed."
  (with-current-buffer list
    (let ((inhibit-read-only t)
          (questions (buffer-local-value 'syzygy-park--questions chat))
          (line (line-number-at-pos)))
      (erase-buffer)
      (insert (propertize (syzygy-park--label chat) 'face 'bold) "\n\n")
      (if (null questions)
          (insert (propertize "Nothing parked." 'face 'shadow) "\n")
        (seq-map-indexed
         (lambda (item i)
           (let ((q (car item)) (ctx (cdr item)))
             (insert (propertize (format "%d. %s\n" (1+ i) q)
                                 'syzygy-park-question q))
             (when ctx
               (insert (propertize
                        (concat (syzygy-park--indent
                                 (string-join (syzygy-park--context-lines ctx) "\n") 3)
                                "\n")
                        'face 'shadow
                        'syzygy-park-question q)))))
         questions)
        (insert "\n"
                (propertize "this one:  C-c h ask here   C-c f ask in fork   C-c d drop"
                            'face 'shadow)
                "\n"
                (propertize "all:       C-c H ask here   C-c F ask in fork   q close"
                            'face 'shadow)
                "\n"))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun syzygy-park-list--refresh (chat)
  "Redraw CHAT's list buffer when one is open."
  (when-let ((list (syzygy-park-list--buffer chat)))
    (syzygy-park-list--render list chat)))

;;;###autoload
(defun syzygy-park-list ()
  "Show the current chat's parked questions in a popup buffer."
  (interactive)
  (let* ((chat (syzygy-park--chat))
         (list (or (syzygy-park-list--buffer chat)
                   (get-buffer-create (syzygy-park-list--name chat)))))
    (with-current-buffer list
      (unless (derived-mode-p 'syzygy-park-list-mode)
        (syzygy-park-list-mode))
      (setq syzygy-park-list--chat chat))
    (syzygy-park-list--render list chat)
    (with-current-buffer list
      (goto-char (point-min))
      (forward-line 2))
    (pop-to-buffer list)))

(defun syzygy-park-list--chat-or-error ()
  "Return the live chat behind the current list buffer, or signal."
  (let ((chat syzygy-park-list--chat))
    (unless (buffer-live-p chat)
      (user-error "That chat is gone"))
    chat))

(defun syzygy-park-list--item-at-point (chat)
  "Return CHAT's parked (QUESTION . CONTEXT) shown on the current line, or signal.
Context lines carry the same property as their question line."
  (let ((question (get-text-property (line-beginning-position) 'syzygy-park-question)))
    (unless question
      (user-error "No parked question on this line"))
    (or (assoc question (buffer-local-value 'syzygy-park--questions chat))
        (user-error "That question is no longer parked"))))

(defun syzygy-park-list-drop ()
  "Forget the parked question at point, in the chat and the org file."
  (interactive)
  (let* ((chat (syzygy-park-list--chat-or-error))
         (question (car (syzygy-park-list--item-at-point chat))))
    (with-current-buffer chat
      (setq syzygy-park--questions
            (seq-remove (lambda (item) (equal (car item) question))
                        syzygy-park--questions))
      (when-let ((session-id (syzygy-fork--session-id chat)))
        (syzygy-park--unrecord syzygy-park-file session-id question)))
    (syzygy-park--refresh chat)
    (message "Dropped: %s" question)))

(defun syzygy-park-list-ask-here ()
  "Ask the parked question at point in the chat it belongs to."
  (interactive)
  (let ((chat (syzygy-park-list--chat-or-error)))
    (syzygy-park--flush chat (list (syzygy-park-list--item-at-point chat)) t)))

(defun syzygy-park-list-ask-fork ()
  "Ask the parked question at point in a fresh fork of its chat."
  (interactive)
  (let ((chat (syzygy-park-list--chat-or-error)))
    (syzygy-park--flush chat (list (syzygy-park-list--item-at-point chat)) nil)))

(defun syzygy-park-list-ask-all-here ()
  "Ask every parked question of the listed chat in that chat."
  (interactive)
  (let ((chat (syzygy-park-list--chat-or-error)))
    (syzygy-park--flush chat (buffer-local-value 'syzygy-park--questions chat) t)))

(defun syzygy-park-list-ask-all-fork ()
  "Ask every parked question of the listed chat in one fork of it."
  (interactive)
  (let ((chat (syzygy-park-list--chat-or-error)))
    (syzygy-park--flush chat (buffer-local-value 'syzygy-park--questions chat) nil)))

(defun syzygy-park-list-revert ()
  "Redraw the list from the chat's current parked questions."
  (interactive)
  (syzygy-park-list--render (current-buffer) (syzygy-park-list--chat-or-error)))

(provide 'syzygy-park)
;;; syzygy-park.el ends here
