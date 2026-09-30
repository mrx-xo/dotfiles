;;; quick-ask-permission.el --- Quick Ask answers its agent's permission requests  -*- lexical-binding: t -*-

;; The hidden agent behind Quick Ask used to stall on any tool call that
;; needed permission: agent-shell drew the prompt in a buffer nobody sees,
;; and the Quick Ask box kept saying "thinking".  Now a Quick Ask agent
;; may read and search on its own, and anything else asks in the box,
;; answered with 1 allow, 2 deny, 3 always.  Other agents are untouched.

;; Loaded from the Quick Ask block of emacs.org, after its waiting keymap.
;; It does not require agent-shell (see AGENTS.md): the advice waits for
;; `agent-shell--on-request' to be defined.

(require 'cl-lib)
(require 'map)
(require 'subr-x)

(defvar agent-shell-permission-responder-function)
(defvar mr-x/quick-ask--shell-buffer)
(declare-function review-panel-ask-permission "review-panel" (title detail &optional queued))
(declare-function mr-x/quick-ask--refit "agent-shell-config" (buf))

(defgroup quick-ask-permission nil
  "Permission requests from the hidden Quick Ask agent."
  :group 'tools)

(defvar quick-ask-permission-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c 1") #'quick-ask-permission-allow)
    (define-key map (kbd "C-c 2") #'quick-ask-permission-deny)
    (define-key map (kbd "C-c 3") #'quick-ask-permission-always)
    map)
  "Keys that answer a permission request shown in the Quick Ask box.
Make it the parent of the box's waiting keymap, or copy its bindings.
Rebind here; the box's prompt labels its keys from this map.")

(defvar quick-ask-permission-queued-functions nil
  "Called with a permission request when the Quick Ask box starts showing it.
A function may offer other ways to answer it; see `quick-ask-permission-drop'.")

(defcustom quick-ask-permission-auto-allow-kinds '("read" "search" "think")
  "Tool kinds a Quick Ask agent runs without asking.
Kinds come from the Agent Client Protocol: read, edit, delete, move,
search, execute, think, fetch and other."
  :type '(repeat string) :group 'quick-ask-permission)

(defvar quick-ask-permission--shell-buffer nil
  "The agent-shell buffer whose request is being handled, while it is.")

(defvar-local quick-ask-permission--pending nil
  "Permission requests waiting in this Quick Ask box, oldest first.")

(defun quick-ask-permission--session-p (buffer)
  "Non-nil when BUFFER is a hidden Quick Ask session."
  (and (buffer-live-p buffer)
       (local-variable-p 'mr-x/quick-ask--session-root buffer)
       (buffer-local-value 'mr-x/quick-ask--session-root buffer)))

(defun quick-ask-permission--popup (shell)
  "The Quick Ask box waiting on SHELL's answer, or nil."
  (let ((popup (get-buffer "*quick-ask*")))
    (and popup
         (eq shell (bound-and-true-p mr-x/quick-ask--shell-buffer))
         (local-variable-p 'mr-x/quick-ask--phase popup)
         (eq (buffer-local-value 'mr-x/quick-ask--phase popup) 'waiting)
         popup)))

(defun quick-ask-permission--answer (permission kind)
  "Answer PERMISSION with its option of KIND; nil when it has none."
  (when-let ((option (seq-find (lambda (o) (equal (map-elt o :kind) kind))
                               (map-elt permission :options))))
    (funcall (map-elt permission :respond) (map-elt option :option-id))
    t))

(defun quick-ask-permission--detail (permission)
  "What PERMISSION's tool call would touch: its command or file, short."
  (let* ((input (map-elt (map-elt permission :tool-call) :raw-input))
         (text (and (listp input)
                    (seq-find #'stringp (list (map-elt input 'command) (map-elt input 'file_path)
                                              (map-elt input 'path) (map-elt input 'url))))))
    (when text
      (let ((lines (split-string (string-trim text) "\n")))
        (truncate-string-to-width
         (concat (string-join (seq-take lines 4) "\n") (if (> (length lines) 4) "\n…" ""))
         400 nil nil "…")))))

(defun quick-ask-permission--keys ()
  "The prompt's keycaps, (KEY LABEL TOKEN) each, from `quick-ask-permission-map'."
  (mapcar (lambda (entry)
            (let ((key (where-is-internal (car entry) quick-ask-permission-map t)))
              (list (if key (key-description key) "") (cadr entry) (caddr entry))))
          '((quick-ask-permission-allow "allow" fg) (quick-ask-permission-deny "deny" dim)
            (quick-ask-permission-always "always" dim))))

(defun quick-ask-permission--draw ()
  "Show the oldest waiting request in this Quick Ask box, below its status line."
  (let ((inhibit-read-only t))
    (save-excursion
      (when-let ((start (text-property-any (point-min) (point-max) 'quick-ask-permission t)))
        (delete-region start (or (next-single-property-change start 'quick-ask-permission)
                                 (point-max))))
      (when-let ((permission (car quick-ask-permission--pending)))
        (goto-char (if-let ((anim (text-property-any (point-min) (point-max) 'review-ask-anim t)))
                       (progn (goto-char anim) (line-beginning-position 2))
                     (point-max)))
        (let ((start (point)))
          (review-panel-ask-permission (or (map-elt (map-elt permission :tool-call) :title) "a tool")
                                       (quick-ask-permission--detail permission)
                                       (length (cdr quick-ask-permission--pending))
                                       (quick-ask-permission--keys))
          (put-text-property start (point) 'quick-ask-permission t)))))
  (when (fboundp 'mr-x/quick-ask--refit)
    (ignore-errors (mr-x/quick-ask--refit (current-buffer)))))

(defun quick-ask-permission-respond (permission)
  "Answer PERMISSION when it comes from a Quick Ask agent; nil otherwise.
Reads of `quick-ask-permission-auto-allow-kinds' are allowed at once.
Anything else waits in the Quick Ask box, when one is waiting on this
agent; with no box, the request goes to agent-shell's usual prompt."
  (let ((shell quick-ask-permission--shell-buffer))
    (when (quick-ask-permission--session-p shell)
      (let ((kind (map-elt (map-elt permission :tool-call) :kind)))
        (or (and (member kind quick-ask-permission-auto-allow-kinds)
                 (quick-ask-permission--answer permission "allow_once"))
            (when-let ((popup (quick-ask-permission--popup shell)))
              (with-current-buffer popup
                (setq quick-ask-permission--pending
                      (append quick-ask-permission--pending (list permission)))
                (quick-ask-permission--draw))
              (run-hook-with-args 'quick-ask-permission-queued-functions permission)
              (unless (get-buffer-window popup t)
                (message "Quick Ask wants to run a tool: SPC Q to answer it"))
              t))))))

(defun quick-ask-permission--wrap (responder)
  "RESPONDER, asked only about requests Quick Ask leaves unanswered."
  (lambda (permission)
    (or (quick-ask-permission-respond permission)
        (and (functionp responder) (funcall responder permission)))))

(defun quick-ask-permission--around-request (orig &rest args)
  "Call ORIG with ARGS, Quick Ask answering first for its own agents.
The responder is wrapped for this one request, so a later `setq' of
`agent-shell-permission-responder-function' cannot drop Quick Ask."
  (let ((quick-ask-permission--shell-buffer (map-elt (plist-get args :state) :buffer))
        (agent-shell-permission-responder-function
         (quick-ask-permission--wrap (bound-and-true-p agent-shell-permission-responder-function))))
    (apply orig args)))

(defun quick-ask-permission-drop (permission)
  "Stop showing PERMISSION in the Quick Ask box: it was answered elsewhere."
  (when-let ((popup (get-buffer "*quick-ask*")))
    (with-current-buffer popup
      (when (memq permission quick-ask-permission--pending)
        (setq quick-ask-permission--pending (delq permission quick-ask-permission--pending))
        (quick-ask-permission--draw)))))

(defun quick-ask-permission--choose (kind)
  "Answer the oldest waiting request in this box with its option of KIND."
  (let ((buffer (or (and (local-variable-p 'quick-ask-permission--pending) (current-buffer))
                    (get-buffer "*quick-ask*"))))
    (with-current-buffer (or buffer (user-error "No Quick Ask box"))
      (let ((permission (or (car quick-ask-permission--pending)
                            (user-error "Nothing is waiting for permission"))))
        (setq quick-ask-permission--pending (cdr quick-ask-permission--pending))
        (unless (quick-ask-permission--answer permission kind)
          (message "Quick Ask: this request has no %s option" kind))
        (quick-ask-permission--draw)))))

(defun quick-ask-permission-allow ()
  "Allow the Quick Ask agent's waiting tool call once."
  (interactive)
  (quick-ask-permission--choose "allow_once"))

(defun quick-ask-permission-deny ()
  "Deny the Quick Ask agent's waiting tool call."
  (interactive)
  (quick-ask-permission--choose "reject_once"))

(defun quick-ask-permission-always ()
  "Always allow this kind of tool call for the Quick Ask agent."
  (interactive)
  (quick-ask-permission--choose "allow_always"))

(advice-add 'agent-shell--on-request :around #'quick-ask-permission--around-request)



(provide 'quick-ask-permission)
;;; quick-ask-permission.el ends here
