;;; casa-agenda.el --- Post an Org task file to Casa as a tree -*- lexical-binding: t; -*-

;;; Commentary:

;; Casa (the family web front door) shows one person's open tasks.  Org is
;; the authority on what those are, so this package works the tree out with
;; Org's own functions and posts it as JSON; Casa only draws it.
;;
;; `casa-agenda-mode' posts after the task file is saved and after each
;; `org-caldav-sync'.  The post is a background `curl': saving never waits
;; on the network.  Nothing is posted when the tree is unchanged since the
;; last accepted post.
;;
;; Nothing about the server lives in this file.  The endpoint is the one
;; line in `casa-agenda-url-file' (no file, no posting), and the bearer
;; token is read by `casa-agenda-token-command' inside the child shell, so
;; it never reaches a command line or an Emacs variable.
;;
;; Payload, version 1:
;;
;;   {"version": 1, "file": "tasks.org", "exported_at": ISO-8601,
;;    "known_ids": [every heading ID in the file, open or done],
;;    "nodes": [{"id", "title", "todo", "priority", "category", "tags",
;;               "deadline", "scheduled", "children": [...]}]}
;;
;; A heading is in `nodes' when it is an open TODO or has one beneath it.
;; `todo' is null for a heading that is only a container.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-element)

(defgroup casa-agenda nil
  "Post an Org task file to Casa."
  :group 'org)

(defcustom casa-agenda-file "~/roaming/notes/arca-tasks.org"
  "The Org file whose task tree is posted."
  :type 'file)

(defcustom casa-agenda-url-file "~/.config/casa-agenda/url"
  "File holding the endpoint URL on one line.
Kept outside the configuration on purpose.  Missing or empty: no posting."
  :type 'file)

(defcustom casa-agenda-token-command "secret casa-agenda-token"
  "Shell command that prints the bearer token on stdout.
Run inside the posting child process, never in Emacs."
  :type 'string)

(defcustom casa-agenda-enabled-function #'always
  "Called with no arguments; posting happens only when it returns non-nil."
  :type 'function)

(defvar casa-agenda--last-sent nil
  "The body, minus its timestamp, of the last post the server accepted.")
(defvar casa-agenda--last-error nil
  "The last failure reported, so a repeating one is said once.")
(defvar casa-agenda--process nil
  "The post in flight, if any.")
(defvar casa-agenda--again nil
  "Non-nil when a post was asked for while another was in flight.")

(defun casa-agenda-url ()
  "The endpoint URL from `casa-agenda-url-file', or nil."
  (let ((f (expand-file-name casa-agenda-url-file)))
    (when (file-readable-p f)
      (let ((s (string-trim (with-temp-buffer
                              (insert-file-contents f)
                              (buffer-string)))))
        (unless (string-empty-p s) s)))))

(defun casa-agenda--date (value)
  "Org timestamp string VALUE as YYYY-MM-DD, or ISO-8601 when it has a time."
  (when (and value (not (string-empty-p value)))
    (let ((ts (ignore-errors (org-timestamp-from-string value))))
      (when ts
        (let ((time (org-timestamp-to-time ts)))
          (if (org-element-property :hour-start ts)
              (format-time-string "%Y-%m-%dT%H:%M:%S%:z" time)
            (format-time-string "%Y-%m-%d" time)))))))

(defun casa-agenda--entry ()
  "The heading at point as a plist, with its outline :level."
  (let* ((todo (org-get-todo-state))
         (priority (org-element-property :priority (org-element-at-point))))
    (list :level (org-outline-level)
          :id (org-entry-get nil "ID")
          :title (string-trim (org-link-display-format
                               (or (org-get-heading t t t t) "")))
          :todo (and todo (substring-no-properties todo))
          :open (and todo (not (member todo org-done-keywords)) t)
          :priority (and priority (char-to-string priority))
          :category (let ((c (org-get-category)))
                      (and c (substring-no-properties c)))
          :tags (mapcar #'substring-no-properties (org-get-tags nil t))
          :deadline (casa-agenda--date (org-entry-get nil "DEADLINE"))
          :scheduled (casa-agenda--date (org-entry-get nil "SCHEDULED")))))

(defun casa-agenda--nest (entries)
  "Turn flat ENTRIES (document order, with :level) into a forest.
Each node gains :children, in document order."
  (let ((root (list :level 0 :children nil))
        stack)
    (setq stack (list root))
    (dolist (e entries)
      (let ((node (append e (list :children nil))))
        (while (>= (plist-get (car stack) :level) (plist-get node :level))
          (pop stack))
        (let ((parent (car stack)))
          (plist-put parent :children
                     (nconc (plist-get parent :children) (list node))))
        (push node stack)))
    (plist-get root :children)))

(defun casa-agenda--prune (nodes)
  "NODES as JSON-ready alists, keeping open tasks and what leads to them."
  (let (kept)
    (dolist (n nodes)
      (let ((children (casa-agenda--prune (plist-get n :children)))
            (open (plist-get n :open)))
        (when (and (or open children)
                   (not (string-empty-p (plist-get n :title))))
          (push `((id . ,(or (plist-get n :id) :null))
                  (title . ,(plist-get n :title))
                  ;; A finished heading with open work beneath it is only
                  ;; a container now.
                  (todo . ,(if open (plist-get n :todo) :null))
                  (priority . ,(or (and open (plist-get n :priority)) :null))
                  (category . ,(or (plist-get n :category) :null))
                  (tags . ,(vconcat (plist-get n :tags)))
                  (deadline . ,(or (and open (plist-get n :deadline)) :null))
                  (scheduled . ,(or (and open (plist-get n :scheduled)) :null))
                  (children . ,(vconcat children)))
                kept))))
    (nreverse kept)))

(defun casa-agenda-export-buffer ()
  "The current Org buffer as the payload alist, without `exported_at'."
  (org-with-wide-buffer
   (let ((entries (org-map-entries #'casa-agenda--entry nil nil)))
     `((version . 1)
       (file . ,(if buffer-file-name
                    (file-name-nondirectory buffer-file-name)
                  ""))
       (known_ids . ,(vconcat (delq nil (mapcar (lambda (e) (plist-get e :id))
                                                entries))))
       (nodes . ,(vconcat (casa-agenda--prune (casa-agenda--nest entries))))))))

(defun casa-agenda-export (&optional file)
  "The payload alist for FILE (default `casa-agenda-file')."
  (with-current-buffer (find-file-noselect
                        (expand-file-name (or file casa-agenda-file)))
    (casa-agenda-export-buffer)))

(defun casa-agenda--ready-p ()
  "Non-nil when posting is allowed and configured here."
  (and (funcall casa-agenda-enabled-function)
       (casa-agenda-url)
       (file-exists-p (expand-file-name casa-agenda-file))))

(defconst casa-agenda--script
  "tok=$(eval \"$CASA_AGENDA_TOKEN_COMMAND\") || exit 3
[ -n \"$tok\" ] || exit 3
printf 'url = \"%s\"\\nrequest = \"POST\"\\nheader = \"Content-Type: application/json\"\\nheader = \"Authorization: Bearer %s\"\\ndata-binary = \"@%s\"\\nsilent\\nshow-error\\nmax-time = 20\\noutput = \"/dev/null\"\\nwrite-out = \"%%{http_code}\"\\n' \"$CASA_AGENDA_URL\" \"$tok\" \"$CASA_AGENDA_BODY\" | curl --config -"
  "Child shell: read the token, hand curl its whole request on stdin.
`printf' is a shell builtin, so the token is never an argument of any
process.")

(defun casa-agenda--report (text)
  "Say TEXT in the echo area unless it was the last thing reported."
  (unless (equal text casa-agenda--last-error)
    (setq casa-agenda--last-error text)
    (message "casa-agenda: %s" text)))

(defun casa-agenda--sentinel (process _event)
  "Finish PROCESS: record an accepted post, report a refused one."
  (unless (process-live-p process)
    (let* ((buffer (process-buffer process))
           (output (if (buffer-live-p buffer)
                       (with-current-buffer buffer (string-trim (buffer-string)))
                     ""))
           (body-file (process-get process 'body-file))
           (ok (and (zerop (process-exit-status process))
                    (string-suffix-p "200" output))))
      (when (and body-file (file-exists-p body-file))
        (delete-file body-file))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (setq casa-agenda--process nil)
      (cond
       (ok
        (setq casa-agenda--last-sent (process-get process 'core)
              casa-agenda--last-error nil)
        (when (process-get process 'announce)
          (message "casa-agenda: posted")))
       ((= (process-exit-status process) 3)
        (casa-agenda--report "no token (token command failed)"))
       (t
        (casa-agenda--report
         (format "post failed (%s)"
                 (if (string-empty-p output)
                     (format "exit %d" (process-exit-status process))
                   (truncate-string-to-width output 120))))))
      (when casa-agenda--again
        (setq casa-agenda--again nil)
        (casa-agenda-post)))))

(defun casa-agenda-post (&optional force)
  "Post the task tree to Casa in the background.
Does nothing when posting is not configured here, or when the tree is
the one the server already has, unless FORCE (the prefix argument).
Returns the process, or nil when nothing was sent."
  (interactive "P")
  (cond
   ((not (casa-agenda--ready-p))
    (when (called-interactively-p 'interactive)
      (message "casa-agenda: not configured on this machine"))
    nil)
   ((process-live-p casa-agenda--process)
    (setq casa-agenda--again t)
    nil)
   (t
    (let* ((payload (casa-agenda-export))
           (core (json-serialize payload)))
      (if (and (not force) (equal core casa-agenda--last-sent))
          nil
        (let* ((body-file (make-temp-file "casa-agenda-" nil ".json"))
               (process-environment
                (append (list (concat "CASA_AGENDA_URL=" (casa-agenda-url))
                              (concat "CASA_AGENDA_BODY=" body-file)
                              (concat "CASA_AGENDA_TOKEN_COMMAND="
                                      casa-agenda-token-command))
                        process-environment))
               (coding-system-for-write 'utf-8))
          (with-temp-file body-file
            (set-buffer-multibyte nil)
            (insert (json-serialize
                     (append payload
                             `((exported_at
                                . ,(format-time-string "%Y-%m-%dT%H:%M:%S%:z")))))))
          (setq casa-agenda--process
                (make-process
                 :name "casa-agenda"
                 :buffer (generate-new-buffer " *casa-agenda*")
                 :command (list "sh" "-c" casa-agenda--script)
                 :connection-type 'pipe
                 :noquery t
                 :sentinel #'casa-agenda--sentinel))
          (process-put casa-agenda--process 'core core)
          (process-put casa-agenda--process 'body-file body-file)
          (process-put casa-agenda--process 'announce (and force t))
          casa-agenda--process))))))

(defun casa-agenda--safely ()
  "Post, turning any error into one line: a save must never fail on this."
  (condition-case err
      (casa-agenda-post)
    (error (casa-agenda--report (format "export failed: %s"
                                        (error-message-string err))))))

(defun casa-agenda--after-save ()
  "Post when the buffer just saved is the task file."
  (when (and buffer-file-name
             (file-equal-p buffer-file-name
                           (expand-file-name casa-agenda-file)))
    (casa-agenda--safely)))

(defun casa-agenda--after-sync (&rest _)
  "Post after an `org-caldav-sync', which may have changed the task file."
  (casa-agenda--safely))

;;;###autoload
(define-minor-mode casa-agenda-mode
  "Post the Org task file to Casa on save and after each CalDAV sync."
  :global t
  :group 'casa-agenda
  (if casa-agenda-mode
      (progn
        (add-hook 'after-save-hook #'casa-agenda--after-save)
        (advice-add 'org-caldav-sync :after #'casa-agenda--after-sync))
    (remove-hook 'after-save-hook #'casa-agenda--after-save)
    (advice-remove 'org-caldav-sync #'casa-agenda--after-sync)))

(provide 'casa-agenda)
;;; casa-agenda.el ends here
