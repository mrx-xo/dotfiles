;;; syzygy-park.el --- Park a question anywhere, ask it later in one fork -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Reading a long agent reply, a PR, or a file, a side question comes
;; up.  Asking it now muddies the thread; forking now leaves a stray
;; chat to track.  So: park it.  `syzygy-park' (SPC c u p) takes one
;; line from the minibuffer and keeps it with two things:
;;
;; - its context: the active region, if any, quoted verbatim;
;; - its origin: where you were.  A file and line range, a Forgejo
;;   PR, or whatever `org-store-link' knows about the buffer.
;;
;; Every parked question belongs to a scope.  In an agent-shell chat
;; the scope is that chat; anywhere else it is the project (the
;; projectile or project.el root, else `default-directory').  A chat
;; sees its own questions plus its project's, so questions parked while
;; reviewing a PR in ~/home-lab show up in any home-lab chat.
;;
;; `syzygy-park-file' is the durable copy: one org heading per scope
;; (keyed by session id or project root), one checkbox item per
;; question with the origin as an org link and the context as a quote
;; block.  Project questions are re-read from it after a restart, so
;; they outlive the Emacs session that parked them.  The mode line
;; shows a parking sign and the count for the current scope.
;;
;; `syzygy-park-list' (SPC c u l) pops the visible questions in a
;; popper buffer.  Its keys sit under C-c so no evil normal-state letter
;; changes meaning there: on the question at point, `C-c h' asks it
;; here, `C-c f' in a fork, `C-c d' drops it; for all of them, `C-c H'
;; here and `C-c F' in one fork.  `syzygy-park-ask' (SPC c u a) asks
;; every visible question in one fork of the current chat, or here with
;; a prefix argument.
;;
;; "Here" and "fork" need a chat.  From a chat it is that chat.  From
;; a file or PR it is picked through `major-pane-pick-buffer', the same
;; picker send-region uses.  The fork goes through `syzygy-fork--run'.
;; Asked questions are ticked in the org file and forgotten in memory.
;;
;; NOTE: loaded from agent-shell-config.el; must not hard-require
;; agent-shell (see syzygy.el).

;;; Code:

(require 'map)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'syzygy-recall)

(declare-function agent-shell--current-shell "agent-shell")
(declare-function agent-shell-insert "agent-shell" t)
(declare-function shell-maker-busy "shell-maker")
(declare-function mr-x/agent-shell--display-new "agent-shell-config" (shell-buffer))
(declare-function mr-x/agent-spawn--send-when-ready "agent-shell-config"
                  (buf task tries))
(declare-function major-pane-pick-buffer "major-pane" (callback &optional action))
(declare-function projectile-project-root "projectile" (&optional dir))
(declare-function project-root "project" (project))
(declare-function nerd-icons-mdicon "nerd-icons" (icon-name &rest args))
(declare-function evil-define-key "evil-core" (state keymap key def &rest bindings))

(defgroup syzygy-park nil
  "Park questions anywhere and ask them later in one fork."
  :group 'syzygy)

(defcustom syzygy-park-file
  (locate-user-emacs-file "var/syzygy/parked-questions.org")
  "Org file that keeps every parked question.
One heading per scope: a chat (SESSION_ID property) or a project
\(PROJECT property).  One checkbox item per question, its origin as an
org link and its highlighted context as a quote block under it.
Per-machine on purpose: session ids and project paths are."
  :type 'file)

(defcustom syzygy-park-prompt-preamble
  "Parked questions from earlier. Answer each in order, briefly, using \
the conversation so far for context. A line in parentheses under a \
question is where it came from; a quoted block is the passage it is \
about."
  "Text that opens the flushed prompt, before the numbered questions."
  :type 'string)

;;; Items and scopes

;; An item is a plist: (:question Q :context CTX :origin ORIGIN).
;; CTX is the highlighted text or nil.  ORIGIN is nil or a plist
;; (:label L :link LINK :url URL): LABEL is short and human
;; ("home-lab/x.py:12-20", "mr-x/home-lab#32"), LINK is an org link
;; target without brackets or nil, URL is a browsable address or nil.
;;
;; A scope is (:chat BUFFER) or (:project ROOT).

(defvar-local syzygy-park--questions nil
  "Items parked on this chat, oldest first.")

(defvar syzygy-park--project-items (make-hash-table :test #'equal)
  "Project root -> parked items, oldest first.
A key that is present with a nil value means the project's items were
already read from `syzygy-park-file' and there are none.")

(defvar-local syzygy-park--root-cache nil
  "This buffer's project root, computed once for the mode line.")

(defun syzygy-park--project-root (&optional dir)
  "Return the project root for DIR (default `default-directory'), as a directory.
Projectile first, then project.el, then DIR itself."
  (let ((default-directory (or dir default-directory)))
    (file-name-as-directory
     (expand-file-name
      (or (and (fboundp 'projectile-project-root)
               (ignore-errors (projectile-project-root)))
          (when-let ((project (ignore-errors (project-current))))
            (project-root project))
          default-directory)))))

(defun syzygy-park--root-here ()
  "Return the current buffer's project root, cached."
  (or syzygy-park--root-cache
      (setq syzygy-park--root-cache (syzygy-park--project-root))))

(defun syzygy-park--chat-here ()
  "Return the chat buffer the current buffer stands for, or nil."
  (let ((buffer (or (and (fboundp 'agent-shell--current-shell)
                         (ignore-errors (agent-shell--current-shell)))
                    (current-buffer))))
    (and (buffer-live-p buffer)
         (eq (buffer-local-value 'major-mode buffer) 'agent-shell-mode)
         buffer)))

(defun syzygy-park--scope-here ()
  "Return the scope a question parked here belongs to."
  (if-let ((chat (syzygy-park--chat-here)))
      (list :chat chat)
    (list :project (syzygy-park--root-here))))

(defun syzygy-park--scopes-visible (&optional chat)
  "Return the scopes shown from here.
CHAT's own and its project's, or just the project's when there is no
chat.  CHAT defaults to the chat the current buffer stands for."
  (let ((chat (or chat (syzygy-park--chat-here))))
    (if chat
        (list (list :chat chat)
              (list :project (with-current-buffer chat (syzygy-park--root-here))))
      (list (list :project (syzygy-park--root-here))))))

(defun syzygy-park--items (scope)
  "Return SCOPE's parked items, reading a project's from the org file once."
  (pcase scope
    (`(:chat ,chat) (buffer-local-value 'syzygy-park--questions chat))
    (`(:project ,root)
     (let ((cached (gethash root syzygy-park--project-items 'unread)))
       (if (eq cached 'unread)
           (puthash root (syzygy-park--hydrate syzygy-park-file "PROJECT" root)
                    syzygy-park--project-items)
         cached)))))

(defun syzygy-park--set-items (scope items)
  "Replace SCOPE's parked items with ITEMS."
  (pcase scope
    (`(:chat ,chat)
     (with-current-buffer chat (setq syzygy-park--questions items)))
    (`(:project ,root)
     (puthash root items syzygy-park--project-items))))

(defun syzygy-park--entries (scopes)
  "Return (SCOPE . ITEM) for every item in SCOPES, in order."
  (mapcan (lambda (scope)
            (mapcar (lambda (item) (cons scope item))
                    (syzygy-park--items scope)))
          scopes))

(defun syzygy-park--scope-key (scope)
  "Return (PROPERTY . VALUE) that keys SCOPE's org heading, or nil."
  (pcase scope
    (`(:chat ,chat)
     (when-let ((id (syzygy-fork--session-id chat)))
       (cons "SESSION_ID" id)))
    (`(:project ,root) (cons "PROJECT" root))))

(defun syzygy-park--label (buffer)
  "Return BUFFER's pane label when it has one, else its name."
  (or (and (boundp 'major-pane--labels)
           (gethash buffer major-pane--labels))
      (buffer-name buffer)))

(defun syzygy-park--scope-title (scope)
  "Return the heading title for SCOPE."
  (pcase scope
    (`(:chat ,chat) (syzygy-park--label chat))
    (`(:project ,root)
     (file-name-nondirectory (directory-file-name root)))))

;;; Origin

(defun syzygy-park--region-context ()
  "Return the active region's text and deactivate it, or nil."
  (when (use-region-p)
    (prog1 (buffer-substring-no-properties (region-beginning) (region-end))
      (deactivate-mark))))

(defun syzygy-park--file-origin ()
  "Return the origin for a file buffer: path relative to the project, with lines."
  (let* ((file (buffer-file-name))
         (root (syzygy-park--root-here))
         (start (line-number-at-pos (if (use-region-p) (region-beginning) (point))))
         (end (if (use-region-p)
                  (save-excursion
                    (goto-char (region-end))
                    ;; A region ending at a line start does not include that line.
                    (when (and (bolp) (> (point) (region-beginning))) (forward-char -1))
                    (line-number-at-pos))
                start))
         (rel (if (file-in-directory-p file root)
                  (file-relative-name file root)
                (abbreviate-file-name file))))
    (list :label (if (= start end)
                     (format "%s:%d" rel start)
                   (format "%s:%d-%d" rel start end))
          :link (format "file:%s::%d" (abbreviate-file-name file) start)
          :url nil)))

(defun syzygy-park--stored-link-origin ()
  "Return an origin from the org link store function that claims this
buffer, or nil."
  (let ((org-store-link-plist nil))
    (when (run-hook-with-args-until-success 'org-store-link-functions)
      (let ((link (plist-get org-store-link-plist :link))
            (desc (plist-get org-store-link-plist :description)))
        (when link
          (list :label (or desc link) :link link :url nil))))))

(defun syzygy-park--forgejo-origin ()
  "Return the origin for a Forgejo issue or PR buffer, or nil elsewhere."
  (when (and (derived-mode-p 'forgejo-pull-view-mode 'forgejo-issue-view-mode)
             (boundp 'forgejo-view--data) (boundp 'forgejo-repo--owner))
    (let* ((owner (bound-and-true-p forgejo-repo--owner))
           (repo (bound-and-true-p forgejo-repo--name))
           (host (bound-and-true-p forgejo-repo--host))
           (number (alist-get 'number forgejo-view--data))
           (kind (if (derived-mode-p 'forgejo-pull-view-mode) "pulls" "issues")))
      (when (and owner repo number)
        (list :label (format "%s/%s#%s" owner repo number)
              :link (format "forgejo:%s/%s#%s" owner repo number)
              :url (and host (format "%s/%s/%s/%s/%s" host owner repo kind number)))))))

(defun syzygy-park--origin ()
  "Return where the current buffer is, as an origin plist, or nil in a chat."
  (cond
   ((syzygy-park--chat-here) nil)
   ((buffer-file-name) (syzygy-park--file-origin))
   ((syzygy-park--forgejo-origin))
   ((syzygy-park--stored-link-origin))
   (t (list :label (buffer-name) :link nil :url nil))))

(defun syzygy-park--origin-org (origin)
  "Return ORIGIN as org text for the item body, without the trailing newline."
  (let ((label (plist-get origin :label))
        (link (plist-get origin :link)))
    (if link
        (format "from: [[%s][%s]]" link label)
      (format "from: %s" label))))

(defun syzygy-park--parse-origin (text)
  "Return the origin plist encoded by TEXT, the part after \"from: \"."
  (if (string-match "\\`\\[\\[\\(.*?\\)\\]\\[\\(.*\\)\\]\\]\\'" text)
      (let ((link (match-string 1 text)) (label (match-string 2 text)))
        (list :label label :link link
              :url (and (string-match "\\`https?:" link) link)))
    (list :label text :link nil :url nil)))

;;; Mode line

(defface syzygy-park-modeline
  '((t :inherit warning))
  "Face for the parked-questions indicator in the mode line."
  :group 'syzygy-park)

(defun syzygy-park--icon ()
  "Return the parking sign glyph, or a plain P when nerd-icons is absent."
  (if (fboundp 'nerd-icons-mdicon)
      (nerd-icons-mdicon "nf-md-parking" :face 'syzygy-park-modeline)
    (propertize "P" 'face 'syzygy-park-modeline)))

(defun syzygy-park--count-here ()
  "Return how many parked questions are visible from the current buffer."
  (length (syzygy-park--entries (syzygy-park--scopes-visible))))

(defun syzygy-park--modeline-indicator ()
  "Mode-line indicator: the parking sign and the count visible from here.
Nil when nothing is parked.  Click asks them in a fork."
  (let ((n (syzygy-park--count-here)))
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

(defun syzygy-park--refresh (scopes)
  "Redraw mode lines and any open list showing one of SCOPES."
  (force-mode-line-update t)
  (syzygy-park-list--refresh scopes))

;;; Org persistence

(defun syzygy-park--with-file (file fn)
  "Visit FILE as org, call FN there, save, return FN's value.
Creates the file's directory when missing."
  (make-directory (file-name-directory (expand-file-name file)) t)
  (with-current-buffer (find-file-noselect file)
    (unless (derived-mode-p 'org-mode) (org-mode))
    (prog1 (save-excursion (funcall fn))
      (when (buffer-modified-p)
        (let ((inhibit-message t)) (save-buffer))))))

(defun syzygy-park--goto-heading (property value)
  "Move to the heading whose PROPERTY is VALUE and return point, or nil."
  (when-let ((pos (org-find-property property value)))
    (goto-char pos)))

(defun syzygy-park--subtree-end ()
  "Return the end of the subtree at point, without moving."
  (save-excursion (org-end-of-subtree t t) (point)))

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

(defun syzygy-park--item-org (item)
  "Return the org list item for ITEM."
  (let ((context (plist-get item :context))
        (origin (plist-get item :origin)))
    (concat (format "- [ ] %s\n" (plist-get item :question))
            (when origin
              (concat "  " (syzygy-park--origin-org origin) "\n"))
            (when context
              (concat "  #+begin_quote\n"
                      (syzygy-park--indent
                       (string-join (syzygy-park--context-lines context) "\n") 2)
                      "\n  #+end_quote\n")))))

(defun syzygy-park--record (file scope-key title item)
  "Append ITEM under the heading keyed by SCOPE-KEY in FILE, titled TITLE when new."
  (syzygy-park--with-file
   file
   (lambda ()
     (if (syzygy-park--goto-heading (car scope-key) (cdr scope-key))
         (progn (org-end-of-subtree t t)
                (unless (bolp) (insert "\n")))
       (goto-char (point-max))
       (unless (or (bobp) (bolp)) (insert "\n"))
       (insert (format "* %s\n:PROPERTIES:\n:%s: %s\n:END:\n"
                       title (car scope-key) (cdr scope-key))))
     (insert (syzygy-park--item-org item)))))

(defun syzygy-park--mark-asked (file scope-key questions)
  "Tick the open checkboxes for QUESTIONS under SCOPE-KEY's heading in FILE."
  (syzygy-park--with-file
   file
   (lambda ()
     (when (syzygy-park--goto-heading (car scope-key) (cdr scope-key))
       (let ((end (syzygy-park--subtree-end)))
         (while (re-search-forward "^- \\[ \\] \\(.*\\)$" end t)
           (when (member (match-string 1) questions)
             (replace-match "- [X] \\1" t))))))))

(defun syzygy-park--unrecord (file scope-key question)
  "Delete the open item for QUESTION under SCOPE-KEY's heading in FILE.
Takes the item's indented body (origin and context) with it."
  (syzygy-park--with-file
   file
   (lambda ()
     (when (syzygy-park--goto-heading (car scope-key) (cdr scope-key))
       (let ((end (syzygy-park--subtree-end))
             (item (concat "^- \\[ \\] " (regexp-quote question) "$")))
         (when (re-search-forward item end t)
           (let ((start (line-beginning-position)))
             (forward-line 1)
             (while (and (< (point) end) (looking-at "^  "))
               (forward-line 1))
             (delete-region start (point)))))))))

(defun syzygy-park--hydrate (file property value)
  "Return the open items under the heading keyed by PROPERTY VALUE in FILE.
Nil when the file or heading does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (when (syzygy-park--goto-heading property value)
        (let ((end (syzygy-park--subtree-end))
              (items nil))
          (while (re-search-forward "^- \\[ \\] \\(.*\\)$" end t)
            (let ((question (match-string 1))
                  (origin nil)
                  (context nil))
              (forward-line 1)
              (when (looking-at "^  from: \\(.*\\)$")
                (setq origin (syzygy-park--parse-origin (match-string 1)))
                (forward-line 1))
              (when (looking-at "^  #\\+begin_quote$")
                (forward-line 1)
                (let ((lines nil))
                  (while (and (< (point) end) (not (looking-at "^  #\\+end_quote$")))
                    (push (string-remove-prefix "  " (buffer-substring-no-properties
                                                     (line-beginning-position)
                                                     (line-end-position)))
                          lines)
                    (forward-line 1))
                  (setq context (concat (string-join (nreverse lines) "\n") "\n"))))
              (push (list :question question :context context :origin origin) items)))
          (nreverse items))))))

;;; Commands

;;;###autoload
(defun syzygy-park (question &optional context origin)
  "Park QUESTION here to ask later.
Interactively, an active region becomes CONTEXT: the passage the
question is about.  ORIGIN is where you are, computed here when not
given (interactively it is taken before the region is released, so
the line range is the highlighted one).  In a chat the question
belongs to that chat; elsewhere to the project.  Nothing is sent to
an agent."
  (interactive
   (let* ((origin (syzygy-park--origin))
          (context (syzygy-park--region-context)))
     (list (read-string (if context "Park question about region: " "Park question: "))
           context origin)))
  (let* ((scope (syzygy-park--scope-here))
         (question (string-trim question))
         (context (and context (not (string-blank-p context)) context))
         (item (list :question question :context context
                     :origin (or origin (syzygy-park--origin)))))
    (when (string-empty-p question)
      (user-error "Nothing to park"))
    (syzygy-park--set-items scope (append (syzygy-park--items scope) (list item)))
    (when-let ((key (syzygy-park--scope-key scope)))
      (syzygy-park--record syzygy-park-file key (syzygy-park--scope-title scope) item))
    (syzygy-park--refresh (list scope))
    (message "Parked (%d)%s%s"
             (length (syzygy-park--items scope))
             (if (eq (car scope) :project)
                 (format " for %s" (syzygy-park--scope-title scope))
               "")
             (if context " with the highlighted text" ""))))

(defun syzygy-park--prompt (items)
  "Return the prompt that asks ITEMS as one numbered list.
An origin becomes a parenthesised line, a context a blockquote."
  (concat syzygy-park-prompt-preamble "\n\n"
          (mapconcat
           (lambda (pair)
             (let* ((n (car pair)) (item (cdr pair))
                    (origin (plist-get item :origin))
                    (ctx (plist-get item :context)))
               (concat (format "%d. %s" n (plist-get item :question))
                       (when origin
                         (format "\n   (%s%s)"
                                 (plist-get origin :label)
                                 (if-let ((url (plist-get origin :url)))
                                     (concat " " url)
                                   "")))
                       (when ctx
                         (concat "\n"
                                 (mapconcat (lambda (line) (concat "   > " line))
                                            (syzygy-park--context-lines ctx)
                                            "\n"))))))
           (seq-map-indexed (lambda (item i) (cons (1+ i) item)) items)
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

(defun syzygy-park--with-target (chat fn)
  "Call FN with the chat to ask in: CHAT when live, else one picked by the user."
  (cond
   ((buffer-live-p chat) (funcall fn chat))
   ((fboundp 'major-pane-pick-buffer)
    (major-pane-pick-buffer fn 'send-region))
   (t (user-error "No chat to ask in: open one first"))))

(defun syzygy-park--flush (target entries here)
  "Ask ENTRIES, a list of (SCOPE . ITEM), in TARGET's chat, then forget them.
HERE sends the prompt into TARGET; otherwise into one fresh fork of it.
The org items get ticked, the mode line and any open list redraw."
  (unless entries
    (user-error "Nothing parked here"))
  (let ((prompt (syzygy-park--prompt (mapcar #'cdr entries)))
        (scopes (seq-uniq (mapcar #'car entries))))
    (if here
        (syzygy-park--send-here target prompt)
      (let ((child (syzygy-fork--run target)))
        (syzygy-park--send-when-ready child prompt)
        (syzygy-park--display target child)))
    (dolist (scope scopes)
      (let ((asked (mapcar #'cdr (seq-filter (lambda (e) (equal (car e) scope)) entries))))
        (syzygy-park--set-items scope
                                (seq-remove (lambda (item) (member item asked))
                                            (syzygy-park--items scope)))
        (when-let ((key (syzygy-park--scope-key scope)))
          (syzygy-park--mark-asked syzygy-park-file key
                                   (mapcar (lambda (item) (plist-get item :question))
                                           asked)))))
    (syzygy-park--refresh scopes)
    (message "Asked %d parked question%s%s"
             (length entries)
             (if (= 1 (length entries)) "" "s")
             (if here "" " in a fork"))))

;;;###autoload
(defun syzygy-park-ask (&optional here)
  "Ask every parked question visible from here in one fork of a chat.
With HERE (prefix argument) send them into the chat itself.  In a chat
that chat is the target; elsewhere you pick one."
  (interactive "P")
  (let ((entries (syzygy-park--entries (syzygy-park--scopes-visible))))
    (unless entries
      (user-error "Nothing parked here"))
    (syzygy-park--with-target
     (syzygy-park--chat-here)
     (lambda (chat) (syzygy-park--flush chat entries here)))))

;;; List buffer

(defvar-local syzygy-park-list--scopes nil
  "The scopes this list shows.")

(defvar-local syzygy-park-list--target nil
  "The chat this list asks in, or nil to pick one.")

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
  "Read-only list of the parked questions visible from somewhere.
On the question at point: `C-c h' asks it here, `C-c f' asks it in a
fork, `C-c d' drops it.  For all of them: `C-c H' here, `C-c F' in one
fork.  `C-c g' redraws, `q' closes."
  (setq truncate-lines nil))

(with-eval-after-load 'evil
  (evil-define-key 'normal syzygy-park-list-mode-map
    (kbd "q") #'quit-window
    (kbd "<escape>") #'quit-window))

(defun syzygy-park-list--name (scopes)
  "Return the list buffer name for SCOPES: the first scope's title."
  (format "*Parked: %s*" (syzygy-park--scope-title (car scopes))))

(defun syzygy-park-list--buffer (scopes)
  "Return the live list buffer showing exactly SCOPES, or nil."
  (seq-find (lambda (b)
              (and (eq (buffer-local-value 'major-mode b) 'syzygy-park-list-mode)
                   (equal (buffer-local-value 'syzygy-park-list--scopes b) scopes)))
            (buffer-list)))

(defun syzygy-park-list--render (list)
  "Fill LIST with its scopes' parked questions, one numbered entry each.
An entry's origin and context follow it, indented and dimmed."
  (with-current-buffer list
    (let ((inhibit-read-only t)
          (entries (syzygy-park--entries syzygy-park-list--scopes))
          (line (line-number-at-pos)))
      (erase-buffer)
      (insert (propertize (mapconcat #'syzygy-park--scope-title
                                     syzygy-park-list--scopes " + ")
                          'face 'bold)
              "\n\n")
      (if (null entries)
          (insert (propertize "Nothing parked." 'face 'shadow) "\n")
        (seq-map-indexed
         (lambda (entry i)
           (let* ((item (cdr entry))
                  (origin (plist-get item :origin))
                  (ctx (plist-get item :context)))
             (insert (propertize (format "%d. %s\n" (1+ i) (plist-get item :question))
                                 'syzygy-park-entry entry))
             (when origin
               (insert (propertize (format "   from: %s\n" (plist-get origin :label))
                                   'face 'shadow 'syzygy-park-entry entry)))
             (when ctx
               (insert (propertize
                        (concat (syzygy-park--indent
                                 (string-join (syzygy-park--context-lines ctx) "\n") 3)
                                "\n")
                        'face 'shadow 'syzygy-park-entry entry)))))
         entries)
        (insert "\n"
                (propertize "this one:  C-c h ask here   C-c f ask in fork   C-c d drop"
                            'face 'shadow)
                "\n"
                (propertize "all:       C-c H ask here   C-c F ask in fork   q close"
                            'face 'shadow)
                "\n"))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun syzygy-park-list--refresh (scopes)
  "Redraw every open list that shows any of SCOPES."
  (dolist (b (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode b) 'syzygy-park-list-mode)
               (seq-intersection (buffer-local-value 'syzygy-park-list--scopes b)
                                 scopes))
      (syzygy-park-list--render b))))

;;;###autoload
(defun syzygy-park-list ()
  "Show the parked questions visible from here in a popup buffer."
  (interactive)
  (let* ((chat (syzygy-park--chat-here))
         (scopes (syzygy-park--scopes-visible chat))
         (list (or (syzygy-park-list--buffer scopes)
                   (get-buffer-create (syzygy-park-list--name scopes)))))
    (with-current-buffer list
      (unless (derived-mode-p 'syzygy-park-list-mode)
        (syzygy-park-list-mode))
      (setq syzygy-park-list--scopes scopes
            syzygy-park-list--target chat))
    (syzygy-park-list--render list)
    (with-current-buffer list
      (goto-char (point-min))
      (forward-line 2))
    (pop-to-buffer list)))

(defun syzygy-park-list--entry-at-point ()
  "Return the (SCOPE . ITEM) shown on the current line, or signal."
  (or (get-text-property (line-beginning-position) 'syzygy-park-entry)
      (user-error "No parked question on this line")))

(defun syzygy-park-list--ask (entries here)
  "Ask ENTRIES from this list, HERE or in a fork.
The target is the list's chat, or one the user picks."
  (syzygy-park--with-target
   syzygy-park-list--target
   (lambda (chat) (syzygy-park--flush chat entries here))))

(defun syzygy-park-list-drop ()
  "Forget the parked question at point, in memory and in the org file."
  (interactive)
  (pcase-let* ((`(,scope . ,item) (syzygy-park-list--entry-at-point))
               (question (plist-get item :question)))
    (syzygy-park--set-items scope
                            (seq-remove (lambda (i) (equal (plist-get i :question) question))
                                        (syzygy-park--items scope)))
    (when-let ((key (syzygy-park--scope-key scope)))
      (syzygy-park--unrecord syzygy-park-file key question))
    (syzygy-park--refresh (list scope))
    (message "Dropped: %s" question)))

(defun syzygy-park-list-ask-here ()
  "Ask the parked question at point in the chat."
  (interactive)
  (syzygy-park-list--ask (list (syzygy-park-list--entry-at-point)) t))

(defun syzygy-park-list-ask-fork ()
  "Ask the parked question at point in a fresh fork of the chat."
  (interactive)
  (syzygy-park-list--ask (list (syzygy-park-list--entry-at-point)) nil))

(defun syzygy-park-list-ask-all-here ()
  "Ask every listed question in the chat."
  (interactive)
  (syzygy-park-list--ask (syzygy-park--entries syzygy-park-list--scopes) t))

(defun syzygy-park-list-ask-all-fork ()
  "Ask every listed question in one fork of the chat."
  (interactive)
  (syzygy-park-list--ask (syzygy-park--entries syzygy-park-list--scopes) nil))

(defun syzygy-park-list-revert ()
  "Redraw the list from the current parked questions."
  (interactive)
  (syzygy-park-list--render (current-buffer)))

(provide 'syzygy-park)
;;; syzygy-park.el ends here
