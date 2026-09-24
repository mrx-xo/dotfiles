;;; project-dashboard.el --- Project dashboard for Emacs -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1") (projectile "2.0"))
;; Keywords: project, dashboard, tasks

;;; Commentary:

;; A project dashboard that opens when switching projects via Projectile,
;; showing org task files and TODO items with quick-action keybindings.

;;; Code:

(require 'projectile)
(require 'project-dashboard-art)

;; Soft dependency: the Recent Conversations section reads agent-recall's
;; transcript index when the package is available, and hides otherwise.
(declare-function agent-recall--index-ensure "agent-recall")
(declare-function agent-recall--open-transcript "agent-recall")
(declare-function agent-recall-session-label "agent-recall")
(declare-function agent-recall-catalogue-get "agent-recall")
(declare-function agent-recall--candidate-description "agent-recall")
(declare-function agent-recall--provider-icon "agent-recall")
(declare-function major-pane-workspace--live-buffer "major-pane-workspace")
(defvar agent-recall--index)
(defvar major-pane--labels)

;;; Customization

(defgroup project-dashboard nil
  "Project dashboard settings."
  :group 'projectile
  :prefix "project-dashboard-")

(defcustom project-dashboard-show-todo-files t
  "Whether to show TODO items from project files."
  :type 'boolean
  :group 'project-dashboard)

(defcustom project-dashboard-show-recent-conversations t
  "Whether to show recent agent-shell conversations from agent-recall.
The section only appears when agent-recall is installed and has
indexed transcripts for the project."
  :type 'boolean
  :group 'project-dashboard)

(defcustom project-dashboard-recent-conversations-count 5
  "Maximum number of recent conversations to display."
  :type 'integer
  :group 'project-dashboard)

(defcustom project-dashboard-agent-shell-function #'agent-shell-new-shell
  "Command that starts a new agent shell for a project.
Called with no arguments and `default-directory' bound to the project
root, both by the `a' key in a dashboard and by the Embark `a' action on
a project candidate.  Point it at a preset picker to be asked which
model and permission mode to launch with."
  :type 'function
  :group 'project-dashboard)

(defcustom project-dashboard-org-task-files nil
  "Alist mapping project roots to lists of org task files.
Each entry is (PROJECT-ROOT . (ORG-FILE ...)).  Each file gets a
stats row in the Files section and number keys switch which file
feeds Next Task / Recently Completed.

Example:
  \\='((\"~/.dotfiles\" . (\"~/roaming/notes/mr-x-rig-mdox.org\")))"
  :type '(alist :key-type string :value-type (repeat string))
  :group 'project-dashboard)

(defcustom project-dashboard-org-in-progress-states '("NEXT")
  "Org TODO keywords treated as in-progress (vs plain pending)."
  :type '(repeat string)
  :group 'project-dashboard)

(defcustom project-dashboard-max-tasks 10
  "Maximum number of tasks to display per section."
  :type 'integer
  :group 'project-dashboard)

(defcustom project-dashboard-todo-files '("TODO.org" "TODO.md")
  "List of TODO file names to search for in project root."
  :type '(repeat string)
  :group 'project-dashboard)

(defcustom project-dashboard-auto-refresh t
  "Whether to automatically refresh the dashboard."
  :type 'boolean
  :group 'project-dashboard)

(defcustom project-dashboard-project-styles
  '(("rec" . (:title-color "#fb4934" :art-color "#F1BE49" :separator-color "#FFFBEB")))
  "Alist mapping project names to style overrides.
Each entry is (PROJECT-NAME . PLIST) where PLIST can contain:
  :title-color    - color for the project title
  :art-color      - color for the ASCII art
  :art-index      - specific ASCII art index (0-based)
  :separator-char - character for separator lines
  :separator-color - color for separator lines"
  :type '(alist :key-type string
                :value-type (plist :options ((:title-color string)
                                             (:art-color string)
                                             (:art-index integer)
                                             (:separator-char character))))
  :group 'project-dashboard)

(defcustom project-dashboard-project-links
  '(("futura-renaissance" . "https://drive.google.com/drive/u/1/folders/1_CyP1Jv4LpaeN0dyVRCYj8qdMzTpvJmD"))
  "Alist mapping project names to external URLs.
Press \\`D' in the dashboard to open the link for the current project."
  :type '(alist :key-type string :value-type string)
  :group 'project-dashboard)

(defcustom project-dashboard-refresh-interval 5
  "Seconds between auto-refresh when `project-dashboard-auto-refresh' is enabled."
  :type 'integer
  :group 'project-dashboard)

;;; Faces (Gruvbox-compatible)

(defface project-dashboard-header-face
  '((t :foreground "#fabd2f" :weight bold :height 1.4))
  "Face for the project name header."
  :group 'project-dashboard)

(defface project-dashboard-section-face
  '((t :foreground "#83a598" :weight bold :height 1.1))
  "Face for section headers."
  :group 'project-dashboard)

(defface project-dashboard-task-title-face
  '((t :foreground "#ebdbb2"))
  "Face for task titles."
  :group 'project-dashboard)

(defface project-dashboard-status-pending-face
  '((t :foreground "#928374"))
  "Face for pending status."
  :group 'project-dashboard)

(defface project-dashboard-status-in-progress-face
  '((t :foreground "#fabd2f"))
  "Face for in-progress status."
  :group 'project-dashboard)

(defface project-dashboard-status-done-face
  '((t :foreground "#b8bb26"))
  "Face for done status."
  :group 'project-dashboard)

(defface project-dashboard-priority-high-face
  '((t :foreground "#fb4934"))
  "Face for high priority indicator."
  :group 'project-dashboard)

(defface project-dashboard-key-face
  '((t :foreground "#fabd2f" :weight bold))
  "Face for keybinding hints."
  :group 'project-dashboard)

(defface project-dashboard-separator-face
  '((t :foreground "#665c54"))
  "Face for separator lines."
  :group 'project-dashboard)

;;; Buffer-local Variables

(defvar-local project-dashboard--project-root nil
  "The project root directory for this dashboard buffer.")

(defvar-local project-dashboard--todo-data nil
  "Cached TODO file data for this dashboard.")

(defvar-local project-dashboard--refresh-timer nil
  "Timer for auto-refreshing this dashboard buffer.")

(defvar-local project-dashboard--tags-list nil
  "Ordered list of org file names for number-based switching.")

(defvar-local project-dashboard--active-org-file nil
  "The org task file currently feeding the task sections.")

(defvar-local project-dashboard--org-files-list nil
  "Org task files for this project, same order as the rendered rows.")

(defvar project-dashboard--org-cache (make-hash-table :test 'equal)
  "Cache of parsed org task files: file -> (MTIME . TASKS).
Avoids re-running `org-mode' over every file on each auto-refresh.")

;;; Data Layer - TODO Files

(defun project-dashboard--read-todo-org (file-path)
  "Read TODO items from an Org file at FILE-PATH.
Returns a list of plists with :title, :state, :priority."
  (when (file-exists-p file-path)
    (require 'org)
    (with-temp-buffer
      (insert-file-contents file-path)
      (org-mode)
      (let (todos)
        (org-map-entries
         (lambda ()
           (let* ((heading (org-get-heading t t t t))
                  (todo-state (org-get-todo-state))
                  (priority (org-entry-get nil "PRIORITY")))
             (when todo-state
               (push (list :title heading
                           :state todo-state
                           :priority priority)
                     todos)))))
        (nreverse todos)))))

(defun project-dashboard--read-todo-md (file-path)
  "Read TODO items from a Markdown file at FILE-PATH.
Looks for lines starting with '- [ ]' or '- [x]'.
Returns a list of plists with :title, :state."
  (when (file-exists-p file-path)
    (with-temp-buffer
      (insert-file-contents file-path)
      (let (todos)
        (goto-char (point-min))
        (while (re-search-forward "^\\s-*- \\[\\([ xX]\\)\\]\\s-*\\(.+\\)$" nil t)
          (let ((checked (not (string= (match-string 1) " ")))
                (title (string-trim (match-string 2))))
            (push (list :title title
                        :state (if checked "DONE" "TODO")
                        :priority nil)
                  todos)))
        (nreverse todos)))))

(defun project-dashboard--find-todo-file (project-root)
  "Find the first existing TODO file in PROJECT-ROOT.
Returns (FILE-PATH . TYPE) where TYPE is `org' or `md', or nil."
  (catch 'found
    (dolist (filename project-dashboard-todo-files)
      (let ((file-path (expand-file-name filename project-root)))
        (when (file-exists-p file-path)
          (throw 'found
                 (cons file-path
                       (if (string-suffix-p ".org" filename) 'org 'md))))))))

;;; Data Layer - Git

;;; Org task source

(defvar org-done-keywords)

(defun project-dashboard--org-files (project-root)
  "Return declared org task files for PROJECT-ROOT that exist.
Looks up PROJECT-ROOT in `project-dashboard-org-task-files' by
truename so symlinked roots still match."
  (let* ((root (directory-file-name (file-truename (expand-file-name project-root))))
         (cell (seq-find (lambda (c)
                           (equal (directory-file-name
                                   (file-truename (expand-file-name (car c))))
                                  root))
                         project-dashboard-org-task-files)))
    (seq-filter #'file-exists-p
                (mapcar #'expand-file-name (cdr cell)))))

(defun project-dashboard--read-org-tasks (file)
  "Return task plists from org FILE, cached by modification time.
Each plist has :title :state :category :priority :closed :file :pos.
:category is `done' (any done keyword), `in-progress' (states in
`project-dashboard-org-in-progress-states'), or `pending'."
  (when (file-exists-p file)
    (let* ((mtime (file-attribute-modification-time (file-attributes file)))
           (cached (gethash file project-dashboard--org-cache)))
      (if (and cached (equal (car cached) mtime))
          (cdr cached)
        (require 'org)
        (let ((tasks '()))
          (with-temp-buffer
            (insert-file-contents file)
            (delay-mode-hooks (org-mode))
            (org-map-entries
             (lambda ()
               (let ((state (org-get-todo-state)))
                 (when state
                   (setq state (substring-no-properties state))
                   (push (list :title (org-link-display-format
                                       (substring-no-properties
                                        (org-get-heading t t t t)))
                               :state state
                               ;; Captured here while the buffer still has
                               ;; org's keyword setup, so the dashboard can
                               ;; render keywords exactly like org does.
                               :face (org-get-todo-face state)
                               :category (cond
                                          ((member state org-done-keywords) 'done)
                                          ((member state project-dashboard-org-in-progress-states)
                                           'in-progress)
                                          (t 'pending))
                               :priority (org-entry-get nil "PRIORITY")
                               :closed (org-entry-get nil "CLOSED")
                               :file file
                               :pos (point))
                         tasks))))))
          (setq tasks (nreverse tasks))
          (puthash file (cons mtime tasks) project-dashboard--org-cache)
          tasks)))))

(defun project-dashboard--org-file-stats (files)
  "Return stats plists (:name :pending :in-progress :done) for org FILES."
  (mapcar (lambda (file)
            (let ((pending 0) (in-progress 0) (done 0))
              (dolist (task (project-dashboard--read-org-tasks file))
                (pcase (plist-get task :category)
                  ('done (cl-incf done))
                  ('in-progress (cl-incf in-progress))
                  (_ (cl-incf pending))))
              (list :name (file-name-base file)
                    :pending pending :in-progress in-progress :done done)))
          files))

(defun project-dashboard--org-next-task (tasks)
  "Pick the next org task from TASKS: first in-progress, else first pending."
  (or (seq-find (lambda (task) (eq (plist-get task :category) 'in-progress)) tasks)
      (seq-find (lambda (task) (eq (plist-get task :category) 'pending)) tasks)))

(defun project-dashboard--org-closed-time (task)
  "Return TASK's CLOSED timestamp as a float, 0 when absent or unparsable."
  (condition-case nil
      (if-let ((closed (plist-get task :closed)))
          (float-time (org-time-string-to-time closed))
        0)
    (error 0)))

(defun project-dashboard--org-recently-completed (tasks &optional limit)
  "Return the most recently closed done TASKS, newest first, up to LIMIT."
  (seq-take
   (sort (seq-filter (lambda (task) (eq (plist-get task :category) 'done)) tasks)
         (lambda (a b)
           (> (project-dashboard--org-closed-time a)
              (project-dashboard--org-closed-time b))))
   (or limit 5)))

(defun project-dashboard--get-git-branch (project-root)
  "Get the current git branch for PROJECT-ROOT, or nil."
  (let ((default-directory project-root))
    (condition-case nil
        (if (fboundp 'magit-get-current-branch)
            (magit-get-current-branch)
          (let ((branch (string-trim
                         (shell-command-to-string
                          "git rev-parse --abbrev-ref HEAD 2>/dev/null"))))
            (unless (string-empty-p branch) branch)))
      (error nil))))

;;; Rendering Layer

(defvar-local project-dashboard--current-art nil
  "The current ASCII art displayed in this dashboard buffer.")

(defun project-dashboard--get-project-style (project-name)
  "Get the style plist for PROJECT-NAME, or nil if none defined."
  (cdr (assoc project-name project-dashboard-project-styles)))

(defun project-dashboard--string-pixel-width (str)
  "Return the width of STR in pixels."
  (if (fboundp #'string-pixel-width)
      (string-pixel-width str)
    (require 'shr)
    (shr-string-pixel-width str)))

(defun project-dashboard--str-len (str)
  "Calculate STR length in character units from pixel width."
  (let ((width (frame-char-width))
        (len (project-dashboard--string-pixel-width str)))
    (+ (/ len width)
       (if (zerop (% len width)) 0 1))))

(defun project-dashboard--center-text (start end)
  "Center the text between START and END using display properties."
  (let* ((max-width (project-dashboard--find-max-width start end))
         (prefix (propertize " " 'display
                             `(space . (:align-to (- center ,(/ (float max-width) 2)))))))
    (add-text-properties start end
                         `(line-prefix ,prefix wrap-prefix ,prefix))))

(defun project-dashboard--find-max-width (start end)
  "Find the maximum line width between START and END."
  (let ((max-width 0))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (let* ((line-str (buffer-substring (line-beginning-position) (line-end-position)))
               (line-width (project-dashboard--str-len line-str)))
          (when (> line-width max-width)
            (setq max-width line-width)))
        (forward-line 1)))
    max-width))

(defun project-dashboard--insert-centered (&rest strings)
  "Insert STRINGS centered in the buffer."
  (let ((start (point)))
    (apply #'insert strings)
    (project-dashboard--center-text start (point))))

(defun project-dashboard--render-header (project-name)
  "Render the dashboard header with PROJECT-NAME."
  (let* ((style (project-dashboard--get-project-style project-name))
         (art-color (or (plist-get style :art-color) "#fabd2f"))
         (title-color (plist-get style :title-color))
         (separator-char (or (plist-get style :separator-char) ?─))
         (separator-color (plist-get style :separator-color))
         (art-index (plist-get style :art-index)))
    (insert "\n")
    ;; Render ASCII art without ever waiting for generation.
    (unless project-dashboard--current-art
      (if art-index
          (setq project-dashboard--current-art
                (project-dashboard-art-by-index art-index))
        (let ((cached (project-dashboard-art-cache-read project-name)))
          (setq project-dashboard--current-art
                (or cached (project-dashboard-art-random)))
          (unless cached
            (let ((dashboard-buffer (current-buffer)))
              (project-dashboard-art-generate
               project-name
               (lambda (art)
                 (when (buffer-live-p dashboard-buffer)
                   (with-current-buffer dashboard-buffer
                     (setq project-dashboard--current-art art)
                     (project-dashboard--render))))))))))
    (let ((art-start (point)))
      (dolist (line project-dashboard--current-art)
        (insert (propertize (format "%s\n" line)
                            'face `(:foreground ,art-color))))
      (project-dashboard--center-text art-start (point)))
    (insert "\n")
    ;; Project name (centered) - use custom color or default face
    (project-dashboard--insert-centered
     (propertize (format "%s\n" project-name)
                 'face (if title-color
                           `(:foreground ,title-color :weight bold :height 1.4)
                         'project-dashboard-header-face)))
    ;; Separator (centered)
    (let ((separator (make-string (min 60 (+ 2 (length project-name))) separator-char)))
      (project-dashboard--insert-centered
       (propertize (format "%s\n" separator)
                   'face (if separator-color
                             `(:foreground ,separator-color)
                           'project-dashboard-separator-face))))
    ;; Git branch (centered, gruvbox green with git icon, below separator)
    (let ((branch (project-dashboard--get-git-branch project-dashboard--project-root)))
      (when branch
        (project-dashboard--insert-centered
         (propertize (format "%c %s\n" #xe725 branch)
                     'face '(:foreground "#b8bb26")))))
    (insert "\n")))

(defun project-dashboard--recent-conversations (project-root)
  "Return the newest agent-recall index entries under PROJECT-ROOT.
Each element is (FILE . ENTRY) where ENTRY is an index plist,
newest first, at most `project-dashboard-recent-conversations-count'.
Returns nil when agent-recall (or its index) is unavailable."
  (when (and project-dashboard-show-recent-conversations
             (require 'agent-recall nil t))
    (agent-recall--index-ensure)
    (let ((root (file-name-as-directory (file-truename project-root)))
          ;; Cache the prefix test per :dir -- many entries share a
          ;; directory and file-truename isn't free on auto-refresh.
          (dir-match (make-hash-table :test 'equal))
          (matches '()))
      (maphash
       (lambda (file entry)
         (when-let ((dir (plist-get entry :dir)))
           (let ((hit (gethash dir dir-match 'unset)))
             (when (eq hit 'unset)
               (setq hit (and (file-directory-p dir)
                              (string-prefix-p root (file-name-as-directory
                                                     (file-truename dir)))))
               (puthash dir hit dir-match))
             (when hit
               (push (cons file entry) matches)))))
       agent-recall--index)
      (seq-take (sort matches
                      (lambda (a b)
                        (string> (or (plist-get (cdr a) :timestamp) "")
                                 (or (plist-get (cdr b) :timestamp) ""))))
                project-dashboard-recent-conversations-count))))

(defun project-dashboard--conversation-timestamp-time (timestamp)
  "Decode an agent-recall TIMESTAMP into an Emacs time value.
Return nil when TIMESTAMP is not in `YYYY-MM-DD-HH-MM-SS' form."
  (when (and timestamp
             (string-match
              (concat "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-"
                      "\\([0-9]\\{2\\}\\)[-T]\\([0-9]\\{2\\}\\)-"
                      "\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'")
              timestamp))
    (let* ((year (string-to-number (match-string 1 timestamp)))
           (month (string-to-number (match-string 2 timestamp)))
           (day (string-to-number (match-string 3 timestamp)))
           (hour (string-to-number (match-string 4 timestamp)))
           (minute (string-to-number (match-string 5 timestamp)))
           (second (string-to-number (match-string 6 timestamp)))
           (encoded (condition-case nil
                        (encode-time second minute hour day month year)
                      (error nil)))
           (decoded (and encoded (decode-time encoded))))
      (when (and decoded
                 (= second (nth 0 decoded))
                 (= minute (nth 1 decoded))
                 (= hour (nth 2 decoded))
                 (= day (nth 3 decoded))
                 (= month (nth 4 decoded))
                 (= year (nth 5 decoded)))
        encoded))))

(defun project-dashboard--conversation-age-label (timestamp &optional now)
  "Format agent-recall TIMESTAMP relative to NOW for the dashboard.
Use minute, hour, and day ages for the first fourteen days, then an
ordinal calendar date.  NOW defaults to `current-time'.  Return an
unparseable TIMESTAMP unchanged."
  (let ((then (project-dashboard--conversation-timestamp-time timestamp))
        (now (or now (current-time))))
    (if (not then)
        (or timestamp "")
      (let ((seconds (max 0 (float-time (time-subtract now then)))))
        (cond
         ((< seconds 60) "just now")
         ((< seconds 3600)
          (format "%d min ago" (floor (/ seconds 60))))
         ((< seconds 86400)
          (format "%d hr ago" (floor (/ seconds 3600))))
         ((< seconds (* 14 86400))
          (let ((days (floor (/ seconds 86400))))
            (format "%d day%s ago" days (if (= days 1) "" "s"))))
         (t
          (let* ((decoded (decode-time then))
                 (day (nth 3 decoded))
                 (year (nth 5 decoded))
                 (current-year (nth 5 (decode-time now)))
                 (suffix (if (<= 11 (% day 100) 13)
                             "th"
                           (pcase (% day 10)
                             (1 "st") (2 "nd") (3 "rd") (_ "th")))))
            (concat (let ((system-time-locale "C"))
                      (format-time-string "%b " then))
                    (number-to-string day) suffix
                    (unless (= year current-year)
                      (format ", %d" year))))))))))

(defun project-dashboard--conversation-buffer (session-id)
  "Return SESSION-ID's live agent-shell buffer, or nil."
  (and session-id
       (fboundp 'major-pane-workspace--live-buffer)
       (major-pane-workspace--live-buffer session-id)))

(defun project-dashboard--conversation-label (session-id buffer)
  "Return the label for SESSION-ID, preferring live BUFFER's label.
An open chat's label lives in `major-pane--labels' and only reaches
agent-recall's store when the capture hook runs, so read it first."
  (or (and buffer (boundp 'major-pane--labels)
           (gethash buffer major-pane--labels))
      (and (fboundp 'agent-recall-session-label)
           (agent-recall-session-label session-id))))

(defun project-dashboard--conversation-line (file entry)
  "Return the Recent Conversations row for transcript FILE with index ENTRY.
Carries the same metadata as agent-recall's pickers: provider icon,
age, [project] when it differs from this dashboard's, label,
catalogue tags, an open marker, then the catalogue note, summary
topic, or first user message."
  (let* ((session-id (plist-get entry :session-id))
         (project (plist-get entry :project))
         (own-project (and project-dashboard--project-root
                           (file-name-nondirectory
                            (directory-file-name project-dashboard--project-root))))
         (catalogue (and session-id (fboundp 'agent-recall-catalogue-get)
                         (agent-recall-catalogue-get session-id)))
         (tags (alist-get 'tags catalogue))
         (buffer (project-dashboard--conversation-buffer session-id))
         (label (project-dashboard--conversation-label session-id buffer))
         (description
          (string-trim
           (or (if (fboundp 'agent-recall--candidate-description)
                   (agent-recall--candidate-description
                    file (plist-get entry :preview) (alist-get 'note catalogue))
                 (plist-get entry :preview))
               ""))))
    (concat
     "    "
     ;; Keep the age column aligned when a row has no known provider.
     (let ((icon (if (fboundp 'agent-recall--provider-icon)
                     (agent-recall--provider-icon file entry)
                   "")))
       (if (and (string-empty-p icon)
                (bound-and-true-p agent-recall-show-provider-icons))
           "  "
         icon))
     (propertize (format "%-11s"
                         (project-dashboard--conversation-age-label
                          (plist-get entry :timestamp)))
                 'face 'shadow)
     "  "
     (when (and project (not (equal (downcase project)
                                    (downcase (or own-project "")))))
       (propertize (format "[%s]  " project) 'face 'shadow))
     (when label
       (concat (propertize label 'face 'agent-recall-label) "  "))
     (when tags
       (concat (mapconcat (lambda (tag)
                            (propertize (concat "#" tag) 'face 'agent-recall-tag))
                          tags " ")
               "  "))
     (when buffer
       (propertize "(open)  " 'face 'success))
     (propertize (truncate-string-to-width description 60 nil nil "...")
                 'face (if label 'shadow 'project-dashboard-task-title-face)))))

(defun project-dashboard--render-recent-conversations (convos)
  "Render the Recent Conversations section for CONVOS.
CONVOS is a list of (FILE . ENTRY) from
`project-dashboard--recent-conversations'.  Each line carries the
transcript path in a `project-dashboard-transcript' text property
so RET can open it."
  (when convos
    (insert (propertize "  Recent Conversations" 'face 'project-dashboard-section-face))
    (insert "\n\n")
    (dolist (convo convos)
      (insert (propertize (project-dashboard--conversation-line (car convo) (cdr convo))
                          'project-dashboard-transcript (car convo)
                          'mouse-face 'highlight
                          'help-echo "RET/click: open transcript"))
      (insert "\n"))
    (insert "\n")))

(defun project-dashboard--org-task-properties (task)
  "Return text properties linking a rendered line back to org TASK."
  (list 'project-dashboard-org-task (cons (plist-get task :file)
                                          (plist-get task :pos))
        'mouse-face 'highlight
        'help-echo "RET/click: open in org file"))

(defun project-dashboard--render-org-next-task (task active-name)
  "Render the focus section for org TASK from file ACTIVE-NAME."
  (let* ((in-progress (eq (plist-get task :category) 'in-progress))
         (header (if in-progress "In Progress" "Next Task"))
         (header-face (if in-progress
                          'project-dashboard-status-in-progress-face
                        'project-dashboard-section-face)))
    (insert (propertize (format "  %s" header) 'face header-face))
    (insert (propertize (format " (%s)" active-name)
                        'face 'project-dashboard-separator-face))
    (insert "\n\n")
    (if task
        (progn
          (insert "    ")
          (let ((state (plist-get task :state)))
            ;; Keyword styled exactly as in org (background pills);
            ;; pad outside the propertized text so the pill stays tight.
            (insert (propertize state
                                'face (or (plist-get task :face)
                                          (if in-progress
                                              'project-dashboard-status-in-progress-face
                                            'project-dashboard-status-pending-face)))
                    (make-string (max 1 (- 6 (length state))) ?\s)))
          (when (equal (plist-get task :priority) "A")
            (insert (propertize "[#A] " 'face 'project-dashboard-priority-high-face)))
          (insert (apply #'propertize
                         (truncate-string-to-width (plist-get task :title) 70 nil nil "...")
                         'face 'project-dashboard-task-title-face
                         (project-dashboard--org-task-properties task)))
          (insert "\n"))
      (insert (propertize "    No next task\n" 'face 'project-dashboard-status-pending-face)))
    (insert "\n")))

(defun project-dashboard--render-org-recently-completed (tasks)
  "Render the Recently Completed section for org TASKS."
  (when tasks
    (insert (propertize "  Recently Completed" 'face 'project-dashboard-section-face))
    (insert "\n\n")
    (dolist (task tasks)
      (insert "    ")
      (insert (apply #'propertize
                     (truncate-string-to-width (plist-get task :title) 70 nil nil "...")
                     'face '(:foreground "#928374" :strike-through t)
                     (project-dashboard--org-task-properties task)))
      (insert "\n"))
    (insert "\n")))

(defun project-dashboard--render-org-sections (project-root)
  "Render org-sourced task sections for PROJECT-ROOT.
Returns non-nil when the project has org task files declared."
  (let ((files (project-dashboard--org-files project-root)))
    (when files
      (unless (member project-dashboard--active-org-file files)
        (setq project-dashboard--active-org-file (car files)))
      (setq project-dashboard--org-files-list files)
      (let* ((active project-dashboard--active-org-file)
             (active-name (file-name-base active))
             (tasks (project-dashboard--read-org-tasks active)))
        (project-dashboard--render-org-next-task
         (project-dashboard--org-next-task tasks) active-name)
        (project-dashboard--render-org-recently-completed
         (project-dashboard--org-recently-completed tasks 5))
        (project-dashboard--render-tags-section
         (project-dashboard--org-file-stats files) active-name))
      t)))

(defun project-dashboard--render-tags-section (tags-stats active-tag)
  "Render the Files section with TAGS-STATS.
TAGS-STATS is a list of plists from `project-dashboard--org-file-stats'.
ACTIVE-TAG is the active org file's base name, highlighted.
Also stores the names in `project-dashboard--tags-list' for number keys."
  (when tags-stats
    ;; Store tags list for keybinding lookup
    (setq project-dashboard--tags-list
          (mapcar (lambda (tag) (plist-get tag :name)) tags-stats))
    (insert (propertize "  Files" 'face 'project-dashboard-section-face))
    (insert "\n\n")
    (let ((idx 1))
      (dolist (tag tags-stats)
        (let* ((name (plist-get tag :name))
               (pending (plist-get tag :pending))
               (in-progress (plist-get tag :in-progress))
               (done (plist-get tag :done))
               (total (+ pending in-progress done))
               (is-active (string= name active-tag)))
          (insert "    ")
          ;; Key for switching (1-9, then !@#$%^&*( for 10-18)
          (let ((key-chars "123456789!@#$%^&*("))
            (if (<= idx (length key-chars))
                (insert (propertize (format "[%c] " (aref key-chars (1- idx))) 
                                    'face 'project-dashboard-key-face))
              (insert "    ")))  ; no key for 19+
          ;; Tag name - highlight if active, truncate if too long
          (let ((display-name (truncate-string-to-width name 20 nil nil "…")))
            (insert (propertize (format "%-21s" display-name)
                                'face (if is-active
                                          'project-dashboard-status-in-progress-face
                                        'project-dashboard-task-title-face))))
          ;; Stats: pending/in-progress/done
          (insert (propertize (format "%d" pending) 'face 'project-dashboard-status-pending-face))
          (insert (propertize "/" 'face 'project-dashboard-separator-face))
          (insert (propertize (format "%d" in-progress) 'face 'project-dashboard-status-in-progress-face))
          (insert (propertize "/" 'face 'project-dashboard-separator-face))
          (insert (propertize (format "%d" done) 'face 'project-dashboard-status-done-face))
          ;; Total in parentheses
          (insert (propertize (format " (%d)" total) 'face 'project-dashboard-separator-face))
          ;; Active indicator
          (when is-active
            (insert (propertize " ◀" 'face 'project-dashboard-status-in-progress-face)))
          (insert "\n")
          (cl-incf idx))))
    (insert "\n")))

(defun project-dashboard--render-todo-section (todos todo-file-path)
  "Render the TODO section with TODOS from TODO-FILE-PATH."
  (insert (propertize "  TODOs" 'face 'project-dashboard-section-face))
  (insert "  ")
  (insert (propertize (format "(%s)" (file-name-nondirectory todo-file-path))
                      'face 'project-dashboard-separator-face))
  (insert "\n\n")
  (if (null todos)
      (insert (propertize "    No TODO items found\n" 'face 'project-dashboard-status-pending-face))
    (let ((count 0))
      (dolist (todo todos)
        (when (< count project-dashboard-max-tasks)
          (let* ((title (plist-get todo :title))
                 (state (plist-get todo :state))
                 (priority (plist-get todo :priority)))
            (insert "    ")
            (insert (propertize (format "[%-4s]" state)
                                'face (if (member state '("DONE" "done"))
                                          'project-dashboard-status-done-face
                                        'project-dashboard-status-pending-face)))
            (when (and priority (string= priority "A"))
              (insert (propertize " !" 'face 'project-dashboard-priority-high-face)))
            (insert "  ")
            (insert (propertize (truncate-string-to-width (or title "") 50 nil nil "...")
                                'face 'project-dashboard-task-title-face))
            (insert "\n"))
          (cl-incf count)))))
  (insert "\n"))

(defun project-dashboard--render-actions-legend ()
  "Render the quick actions legend horizontally at the bottom."
  (project-dashboard--insert-centered
   (propertize (format "%s\n" (make-string 60 ?─)) 'face 'project-dashboard-separator-face))
  (insert "\n")
  ;; Build horizontal legend string
  (let* ((project-name (file-name-nondirectory
                        (directory-file-name project-dashboard--project-root)))
         (has-link (assoc project-name project-dashboard-project-links))
         (actions (append '(("a" . "Agent") ("d" . "Dired") ("m" . "Magit") ("f" . "Find")
                            ("v" . "Vterm") ("t" . "Tasks"))
                          (when has-link '(("D" . "Drive")))
                          '(("r" . "Refresh") ("q" . "Quit"))))
         (legend-parts
          (mapcar (lambda (action)
                    (concat (propertize (format "[%s]" (car action)) 
                                        'face 'project-dashboard-key-face)
                            (cdr action)))
                  actions))
         (legend-str (string-join legend-parts "  ")))
    (project-dashboard--insert-centered (format "%s\n" legend-str))))

(defun project-dashboard--render ()
  "Render the complete dashboard for the current project."
  (let* ((inhibit-read-only t)
         (project-root project-dashboard--project-root)
         (project-name (file-name-nondirectory (directory-file-name project-root))))
    (erase-buffer)
    
    ;; Header (ASCII art + project name)
    (project-dashboard--render-header project-name)
    
    ;; Actions legend (right below title)
    (project-dashboard--render-actions-legend)
    
    (insert "\n")
    
    ;; Org task sections (Next Task, Recently Completed, Files)
    (unless (project-dashboard--render-org-sections project-root)
      (insert (propertize "  Tasks" 'face 'project-dashboard-section-face)
              "\n\n"
              (propertize "    No org task file yet. Add one with M-x project-dashboard-add-org-file\n\n"
                          'face 'project-dashboard-status-pending-face)))

    ;; Recent agent-shell conversations (agent-recall index)
    (project-dashboard--render-recent-conversations
     (project-dashboard--recent-conversations project-root))

    ;; TODO file section
    (when project-dashboard-show-todo-files
      (let ((todo-info (project-dashboard--find-todo-file project-root)))
        (when todo-info
          (let* ((file-path (car todo-info))
                 (file-type (cdr todo-info))
                 (todos (if (eq file-type 'org)
                            (project-dashboard--read-todo-org file-path)
                          (project-dashboard--read-todo-md file-path))))
            (setq project-dashboard--todo-data (cons file-path todos))
            (project-dashboard--render-todo-section todos file-path)))))
    
    (goto-char (point-min))))

;;; Action Functions

(defun project-dashboard--start-agent-shell (directory)
  "Start an agent shell in DIRECTORY via `project-dashboard-agent-shell-function'."
  (let ((default-directory directory))
    (if (functionp project-dashboard-agent-shell-function)
        (funcall project-dashboard-agent-shell-function)
      (message "agent-shell not available"))))

(defun project-dashboard-open-agent-shell ()
  "Open a new agent-shell conversation for the current project.
Runs `project-dashboard-agent-shell-function' in the project root."
  (interactive)
  (project-dashboard--start-agent-shell project-dashboard--project-root))

(defun project-dashboard-open-dired ()
  "Open dired at project root."
  (interactive)
  (dired project-dashboard--project-root))

(defun project-dashboard-open-magit ()
  "Open magit for the current project."
  (interactive)
  (let ((default-directory project-dashboard--project-root))
    (if (fboundp 'magit-status)
        (magit-status)
      (message "magit not available"))))

(defun project-dashboard-open-link ()
  "Open the external link configured for the current project."
  (interactive)
  (let* ((project-name (file-name-nondirectory
                        (directory-file-name project-dashboard--project-root)))
         (url (cdr (assoc project-name project-dashboard-project-links))))
    (if url
        (browse-url url)
      (message "No external link configured for %s" project-name))))

(defun project-dashboard-find-file ()
  "Find file in the current project."
  (interactive)
  (let ((default-directory project-dashboard--project-root))
    (cond
     ((fboundp 'counsel-projectile-find-file)
      (counsel-projectile-find-file))
     ((fboundp 'projectile-find-file)
      (projectile-find-file))
     (t
      (call-interactively #'find-file)))))

(defun project-dashboard-open-vterm ()
  "Open a new vterm buffer in the project root directory."
  (interactive)
  (let ((default-directory project-dashboard--project-root))
    (if (fboundp 'vterm)
        (vterm t)  ; t means create a new buffer
      (message "vterm not available"))))

(defun project-dashboard-open-transcript-at-point (&optional pos)
  "Open the conversation transcript on the line at POS (default point).
Returns non-nil when a transcript was found and opened."
  (interactive)
  (when-let ((file (get-text-property (or pos (point))
                                      'project-dashboard-transcript)))
    (if (file-exists-p file)
        (progn
          (if (fboundp 'agent-recall--open-transcript)
              (agent-recall--open-transcript file)
            (find-file file))
          t)
      (user-error "Transcript no longer exists: %s" file))))

(defun project-dashboard-open-org-task-at-point (&optional pos)
  "Jump to the org heading for the task on the line at POS (default point).
Returns non-nil when a task target was found."
  (interactive)
  (when-let ((target (get-text-property (or pos (point))
                                        'project-dashboard-org-task)))
    (find-file (car target))
    (goto-char (cdr target))
    (when (derived-mode-p 'org-mode)
      (if (fboundp 'org-fold-show-context)
          (org-fold-show-context 'agenda)
        (with-no-warnings (org-show-context 'agenda))))
    t))

(defun project-dashboard-open-at-point ()
  "Open the thing at point: a transcript on conversation lines, an
org heading on org task lines, otherwise fall back to
`project-dashboard-find-file'."
  (interactive)
  (or (project-dashboard-open-transcript-at-point)
      (project-dashboard-open-org-task-at-point)
      (project-dashboard-find-file)))

(defun project-dashboard-mouse-open (event)
  "Open the transcript or org task clicked in EVENT."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (or (project-dashboard-open-transcript-at-point pos)
        (project-dashboard-open-org-task-at-point pos))))

(defun project-dashboard-add-org-file (file)
  "Declare org task FILE for this dashboard's project and persist it.
Adds FILE to `project-dashboard-org-task-files' under the current
project root, saves the variable via Customize, and refreshes."
  (interactive
   (progn
     (unless project-dashboard--project-root
       (user-error "Not in a project dashboard buffer"))
     (list (read-file-name
            "Add org task file: "
            (if (boundp 'org-directory)
                (file-name-as-directory org-directory)
              default-directory)
            nil t nil
            (lambda (f) (or (file-directory-p f)
                            (string-suffix-p ".org" f)))))))
  (let* ((file (abbreviate-file-name (expand-file-name file)))
         (root (directory-file-name
                (file-truename
                 (expand-file-name project-dashboard--project-root))))
         (cell (seq-find (lambda (c)
                           (equal (directory-file-name
                                   (file-truename (expand-file-name (car c))))
                                  root))
                         project-dashboard-org-task-files)))
    (if cell
        (unless (member file (cdr cell))
          (setcdr cell (append (cdr cell) (list file))))
      (push (cons (abbreviate-file-name
                   (directory-file-name
                    (expand-file-name project-dashboard--project-root)))
                  (list file))
            project-dashboard-org-task-files))
    (customize-save-variable 'project-dashboard-org-task-files
                             project-dashboard-org-task-files)
    (project-dashboard-refresh)
    (message "Org task file added: %s" file)))

(defun project-dashboard-refresh ()
  "Refresh the dashboard."
  (interactive)
  (project-dashboard--render)
  (message "Dashboard refreshed"))

(defun project-dashboard-new-art ()
  "Pick a new random ASCII art and refresh."
  (interactive)
  (setq project-dashboard--current-art (project-dashboard-art-random))
  (project-dashboard--render)
  (message "New art!"))

(defmacro project-dashboard--with-preserved-position (&rest body)
  "Execute BODY while preserving window scroll position and point."
  `(let ((win (get-buffer-window (current-buffer)))
         (saved-point (point))
         (saved-window-start (when (get-buffer-window (current-buffer))
                               (window-start (get-buffer-window (current-buffer))))))
     ,@body
     (when (and win saved-window-start)
       (set-window-start win saved-window-start)
       (goto-char saved-point))))

(defun project-dashboard--auto-refresh ()
  "Auto-refresh the dashboard if buffer is visible, preserving scroll position."
  (when (and (buffer-live-p (current-buffer))
             (get-buffer-window (current-buffer)))
    (let ((inhibit-message t))  ; Suppress "Dashboard refreshed" message
      (project-dashboard--with-preserved-position
       (project-dashboard--render)))))

(defun project-dashboard--start-auto-refresh ()
  "Start the auto-refresh timer for current dashboard buffer."
  (when (and project-dashboard-auto-refresh
             (not project-dashboard--refresh-timer))
    (setq project-dashboard--refresh-timer
          (run-with-timer project-dashboard-refresh-interval
                          project-dashboard-refresh-interval
                          (let ((buf (current-buffer)))
                            (lambda ()
                              (when (buffer-live-p buf)
                                (with-current-buffer buf
                                  (project-dashboard--auto-refresh)))))))))

(defun project-dashboard--stop-auto-refresh ()
  "Stop the auto-refresh timer for current dashboard buffer."
  (when project-dashboard--refresh-timer
    (cancel-timer project-dashboard--refresh-timer)
    (setq project-dashboard--refresh-timer nil)))

(defun project-dashboard-quit ()
  "Quit the dashboard and return to previous buffer."
  (interactive)
  (project-dashboard--stop-auto-refresh)
  (quit-window))

(defun project-dashboard-switch-tag (n)
  "Make org file number N (1-indexed) in the Files section active."
  (interactive "p")
  (if (and project-dashboard--tags-list
           (> n 0)
           (<= n (length project-dashboard--tags-list)))
      (let ((tag-name (nth (1- n) project-dashboard--tags-list)))
        (setq project-dashboard--active-org-file
              (nth (1- n) project-dashboard--org-files-list))
        (message "Switched to: %s" tag-name)
        (project-dashboard--with-preserved-position
         (project-dashboard--render)))
    (message "Invalid tag number: %d" n)))

(defun project-dashboard-switch-tag-1 () "Switch to tag 1." (interactive) (project-dashboard-switch-tag 1))
(defun project-dashboard-switch-tag-2 () "Switch to tag 2." (interactive) (project-dashboard-switch-tag 2))
(defun project-dashboard-switch-tag-3 () "Switch to tag 3." (interactive) (project-dashboard-switch-tag 3))
(defun project-dashboard-switch-tag-4 () "Switch to tag 4." (interactive) (project-dashboard-switch-tag 4))
(defun project-dashboard-switch-tag-5 () "Switch to tag 5." (interactive) (project-dashboard-switch-tag 5))
(defun project-dashboard-switch-tag-6 () "Switch to tag 6." (interactive) (project-dashboard-switch-tag 6))
(defun project-dashboard-switch-tag-7 () "Switch to tag 7." (interactive) (project-dashboard-switch-tag 7))
(defun project-dashboard-switch-tag-8 () "Switch to tag 8." (interactive) (project-dashboard-switch-tag 8))
(defun project-dashboard-switch-tag-9 () "Switch to tag 9." (interactive) (project-dashboard-switch-tag 9))
;; Shift+number for tags 10-18
(defun project-dashboard-switch-tag-10 () "Switch to tag 10." (interactive) (project-dashboard-switch-tag 10))
(defun project-dashboard-switch-tag-11 () "Switch to tag 11." (interactive) (project-dashboard-switch-tag 11))
(defun project-dashboard-switch-tag-12 () "Switch to tag 12." (interactive) (project-dashboard-switch-tag 12))
(defun project-dashboard-switch-tag-13 () "Switch to tag 13." (interactive) (project-dashboard-switch-tag 13))
(defun project-dashboard-switch-tag-14 () "Switch to tag 14." (interactive) (project-dashboard-switch-tag 14))
(defun project-dashboard-switch-tag-15 () "Switch to tag 15." (interactive) (project-dashboard-switch-tag 15))
(defun project-dashboard-switch-tag-16 () "Switch to tag 16." (interactive) (project-dashboard-switch-tag 16))
(defun project-dashboard-switch-tag-17 () "Switch to tag 17." (interactive) (project-dashboard-switch-tag 17))
(defun project-dashboard-switch-tag-18 () "Switch to tag 18." (interactive) (project-dashboard-switch-tag 18))

;;; Major Mode

(defun project-dashboard-open-org-tasks ()
  "Open the active org task file, jumping to its Tasks heading if any.
Falls back to the project's TODO file when no org files are declared."
  (interactive)
  (let ((file (or project-dashboard--active-org-file
                  (car (project-dashboard--org-files
                        project-dashboard--project-root))
                  (car project-dashboard--todo-data))))
    (unless file
      (user-error "No org task files declared (M-x project-dashboard-add-org-file)"))
    (find-file file)
    (goto-char (point-min))
    (when (re-search-forward "^\\*+ Tasks\\b" nil t)
      (goto-char (line-beginning-position))
      (when (derived-mode-p 'org-mode)
        (if (fboundp 'org-fold-show-context)
            (org-fold-show-context 'agenda)
          (with-no-warnings (org-show-context 'agenda)))
        (if (fboundp 'org-fold-show-children)
            (org-fold-show-children)
          (with-no-warnings (org-show-children)))))))

(defvar project-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'project-dashboard-open-agent-shell)
    (define-key map (kbd "d") #'project-dashboard-open-dired)
    (define-key map (kbd "m") #'project-dashboard-open-magit)
    (define-key map (kbd "D") #'project-dashboard-open-link)
    (define-key map (kbd "f") #'project-dashboard-find-file)
    (define-key map (kbd "v") #'project-dashboard-open-vterm)
    (define-key map (kbd "t") #'project-dashboard-open-org-tasks)
    (define-key map (kbd "r") #'project-dashboard-refresh)
    (define-key map (kbd "g") #'project-dashboard-refresh)
    (define-key map (kbd "q") #'project-dashboard-quit)
    (define-key map (kbd "RET") #'project-dashboard-open-at-point)
    (define-key map [mouse-1] #'project-dashboard-mouse-open)
    (define-key map (kbd "o") #'project-dashboard-add-org-file)
    ;; Tag switching (1-9)
    (define-key map (kbd "1") #'project-dashboard-switch-tag-1)
    (define-key map (kbd "2") #'project-dashboard-switch-tag-2)
    (define-key map (kbd "3") #'project-dashboard-switch-tag-3)
    (define-key map (kbd "4") #'project-dashboard-switch-tag-4)
    (define-key map (kbd "5") #'project-dashboard-switch-tag-5)
    (define-key map (kbd "6") #'project-dashboard-switch-tag-6)
    (define-key map (kbd "7") #'project-dashboard-switch-tag-7)
    (define-key map (kbd "8") #'project-dashboard-switch-tag-8)
    (define-key map (kbd "9") #'project-dashboard-switch-tag-9)
    ;; Tag switching (shift+1-9 for 10-18)
    (define-key map (kbd "!") #'project-dashboard-switch-tag-10)
    (define-key map (kbd "@") #'project-dashboard-switch-tag-11)
    (define-key map (kbd "#") #'project-dashboard-switch-tag-12)
    (define-key map (kbd "$") #'project-dashboard-switch-tag-13)
    (define-key map (kbd "%") #'project-dashboard-switch-tag-14)
    (define-key map (kbd "^") #'project-dashboard-switch-tag-15)
    (define-key map (kbd "&") #'project-dashboard-switch-tag-16)
    (define-key map (kbd "*") #'project-dashboard-switch-tag-17)
    (define-key map (kbd "(") #'project-dashboard-switch-tag-18)
    map)
  "Keymap for `project-dashboard-mode'.")

(define-derived-mode project-dashboard-mode special-mode "ProjDash"
  "Major mode for displaying project dashboard.

\\{project-dashboard-mode-map}"
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local show-trailing-whitespace nil))

;; Evil mode integration
(with-eval-after-load 'evil
  (evil-set-initial-state 'project-dashboard-mode 'normal)
  (evil-define-key 'normal project-dashboard-mode-map
    (kbd "a") #'project-dashboard-open-agent-shell
    (kbd "d") #'project-dashboard-open-dired
    (kbd "m") #'project-dashboard-open-magit
    (kbd "D") #'project-dashboard-open-link
    (kbd "f") #'project-dashboard-find-file
    (kbd "v") #'project-dashboard-open-vterm
    (kbd "t") #'project-dashboard-open-org-tasks
    (kbd "r") #'project-dashboard-refresh
    (kbd "R") #'project-dashboard-new-art
    (kbd "gr") #'project-dashboard-refresh
    (kbd "q") #'project-dashboard-quit
    (kbd "o") #'project-dashboard-add-org-file
    (kbd "RET") #'project-dashboard-open-at-point
    ;; Tag switching (1-9)
    (kbd "1") #'project-dashboard-switch-tag-1
    (kbd "2") #'project-dashboard-switch-tag-2
    (kbd "3") #'project-dashboard-switch-tag-3
    (kbd "4") #'project-dashboard-switch-tag-4
    (kbd "5") #'project-dashboard-switch-tag-5
    (kbd "6") #'project-dashboard-switch-tag-6
    (kbd "7") #'project-dashboard-switch-tag-7
    (kbd "8") #'project-dashboard-switch-tag-8
    (kbd "9") #'project-dashboard-switch-tag-9
    ;; Tag switching (shift+1-9 for 10-18)
    (kbd "!") #'project-dashboard-switch-tag-10
    (kbd "@") #'project-dashboard-switch-tag-11
    (kbd "#") #'project-dashboard-switch-tag-12
    (kbd "$") #'project-dashboard-switch-tag-13
    (kbd "%") #'project-dashboard-switch-tag-14
    (kbd "^") #'project-dashboard-switch-tag-15
    (kbd "&") #'project-dashboard-switch-tag-16
    (kbd "*") #'project-dashboard-switch-tag-17
    (kbd "(") #'project-dashboard-switch-tag-18))

;;; Entry Points

;;;###autoload
(defun project-dashboard-open (&optional project-root)
  "Open the project dashboard for PROJECT-ROOT.
If PROJECT-ROOT is nil, use current projectile project."
  (interactive)
  (let* ((root (or project-root
                   (projectile-project-root)
                   default-directory))
         (buf-name (format "*Project: %s*"
                           (file-name-nondirectory (directory-file-name root))))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'project-dashboard-mode)
        (project-dashboard-mode))
      (setq project-dashboard--project-root root)
      (project-dashboard--render)
      (project-dashboard--start-auto-refresh))
    (switch-to-buffer buf)))

;;;###autoload
(defun project-dashboard--projectile-switch-action ()
  "Action to run when switching projects via projectile.
Opens the project dashboard for the selected project."
  (project-dashboard-open (projectile-project-root)))

;;; Project Launcher

(defcustom project-dashboard-projects
  '(("dotfiles" . "~/.dotfiles")
    ("sandbox" . "~/.emacs-sandbox")
    ;; Roaming
    ("roaming/claude" . "~/roaming/claude")
    ("roaming/code" . "~/roaming/code")
    ("roaming/notes" . "~/roaming/notes")
    ("roaming/personal" . "~/roaming/personal")
    ;; Work
    ("work/cloudburst" . "~/work/cloudburst")
    ("work/experian" . "~/work/experian")
    ("work/omi-live" . "~/work/omi-live")
    ("work/virtual-bid" . "~/work/virtual-bid")
    ("work/york" . "~/work/york"))
  "Alist of project names and their paths for the project launcher."
  :type '(alist :key-type string :value-type string)
  :group 'project-dashboard)

;;; Embark Integration

(defun project-dashboard--resolve-path (name)
  "Resolve project NAME to its expanded filesystem path."
  (when-let ((entry (assoc name project-dashboard-projects)))
    (expand-file-name (cdr entry))))

(defun project-dashboard--action-open (name)
  "Open project dashboard for NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (project-dashboard-open path)))

(defun project-dashboard--action-magit (name)
  "Open magit status for project NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (magit-status path)))

(defun project-dashboard--action-dired (name)
  "Open dired for project NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (dired path)))

(defun project-dashboard--action-vterm (name)
  "Open vterm in project NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (let ((default-directory path))
      (vterm t))))

(defun project-dashboard--action-agent-shell (name)
  "Open a new agent-shell conversation in project NAME.
Runs `project-dashboard-agent-shell-function' in the project root."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (project-dashboard--start-agent-shell path)))

(defun project-dashboard--action-find-file (name)
  "Find file in project NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (let ((default-directory path))
      (if (fboundp 'projectile-find-file)
          (projectile-find-file)
        (call-interactively #'find-file)))))

(with-eval-after-load 'embark
  (defvar-keymap embark-project-dashboard-actions
    :doc "Actions for project-dashboard candidates."
    :parent embark-general-map
    "RET" #'project-dashboard--action-open
    "m"   #'project-dashboard--action-magit
    "d"   #'project-dashboard--action-dired
    "v"   #'project-dashboard--action-vterm
    "a"   #'project-dashboard--action-agent-shell
    "f"   #'project-dashboard--action-find-file)
  (add-to-list 'embark-keymap-alist
               '(project-dashboard . embark-project-dashboard-actions)))

;;; Entry Point - Launch

;;;###autoload
(defun project-dashboard-launch ()
  "Launch a project dashboard from a list of known projects.
With Embark installed, press \\`C-.' on a candidate for actions
like Magit, Dired, Vterm, Agent Shell, or Find File."
  (interactive)
  (let* ((choice (completing-read
                  "Project: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (category . project-dashboard))
                      (complete-with-action
                       action project-dashboard-projects string pred)))))
         (path (project-dashboard--resolve-path choice)))
    (when path
      (project-dashboard-open path))))

;;;###autoload
(defun project-dashboard-add-project (path name)
  "Add a project at PATH with NAME to the project list."
  (interactive
   (list (read-directory-name "Project path: " "~/" nil t)
         (read-string "Project name: ")))
  (let ((entry (cons name (abbreviate-file-name path))))
    (add-to-list 'project-dashboard-projects entry t)
    (customize-save-variable 'project-dashboard-projects project-dashboard-projects)
    (message "Added project: %s -> %s" name path)))

(provide 'project-dashboard)

;;; project-dashboard.el ends here
