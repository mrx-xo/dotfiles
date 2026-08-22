;;; project-dashboard.el --- Project dashboard for Emacs -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1") (projectile "2.0"))
;; Keywords: project, dashboard, tasks

;;; Commentary:

;; A project dashboard that opens when switching projects via Projectile,
;; showing Task Master tasks and TODO items with quick-action keybindings.

;;; Code:

(require 'json)
(require 'projectile)
(require 'project-dashboard-art)

;; Soft dependency: the Recent Conversations section reads agent-recall's
;; transcript index when the package is available, and hides otherwise.
(declare-function agent-recall--index-ensure "agent-recall")
(declare-function agent-recall--display-timestamp "agent-recall")
(declare-function agent-recall--open-transcript "agent-recall")
(declare-function agent-recall-session-label "agent-recall")
(defvar agent-recall--index)

;;; Customization

(defgroup project-dashboard nil
  "Project dashboard settings."
  :group 'projectile
  :prefix "project-dashboard-")

(defcustom project-dashboard-show-taskmaster t
  "Whether to show Task Master tasks in the dashboard."
  :type 'boolean
  :group 'project-dashboard)

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

(defcustom project-dashboard-task-source 'auto
  "Which task system drives the dashboard's task sections.
`auto' uses org when the project has files declared in
`project-dashboard-org-task-files', Task Master otherwise.
The `s' key toggles the current dashboard buffer at any time."
  :type '(choice (const auto) (const taskmaster) (const org))
  :group 'project-dashboard)

(defcustom project-dashboard-org-task-files nil
  "Alist mapping project roots to lists of org task files.
Each entry is (PROJECT-ROOT . (ORG-FILE ...)).  Files behave like
Task Master tags: each gets a stats row in the Tags section and
number keys switch which file feeds Next Task / Recently Completed.

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

(defvar-local project-dashboard--taskmaster-data nil
  "Cached Task Master data for this dashboard.")

(defvar-local project-dashboard--todo-data nil
  "Cached TODO file data for this dashboard.")

(defvar-local project-dashboard--refresh-timer nil
  "Timer for auto-refreshing this dashboard buffer.")

(defvar-local project-dashboard--tags-list nil
  "Ordered list of tag names for number-based switching.")

;;; Data Layer - Task Master

(defvar-local project-dashboard--task-source nil
  "Task source resolved for this dashboard buffer: `taskmaster' or `org'.")

(defvar-local project-dashboard--source-override nil
  "Session override from `project-dashboard-toggle-task-source', or nil.")

(defvar-local project-dashboard--active-org-file nil
  "The org task file currently feeding the task sections.")

(defvar-local project-dashboard--org-files-list nil
  "Org task files for this project, same order as the rendered rows.")

(defvar project-dashboard--org-cache (make-hash-table :test 'equal)
  "Cache of parsed org task files: file -> (MTIME . TASKS).
Avoids re-running `org-mode' over every file on each auto-refresh.")

(defun project-dashboard--get-active-tag (project-root)
  "Get the active Task Master tag for PROJECT-ROOT.
Returns the tag name from state.json, or \"master\" as fallback."
  (let ((state-file (expand-file-name ".taskmaster/state.json" project-root)))
    (if (file-exists-p state-file)
        (condition-case nil
            (let* ((json-object-type 'alist)
                   (json-key-type 'symbol)
                   (state (json-read-file state-file)))
              (or (alist-get 'currentTag state) "master"))
          (error "master"))
      "master")))

(defun project-dashboard--set-active-tag (project-root tag-name)
  "Set the active Task Master tag for PROJECT-ROOT to TAG-NAME.
Writes to state.json file."
  (let ((state-file (expand-file-name ".taskmaster/state.json" project-root)))
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-key-type 'symbol)
               (state (if (file-exists-p state-file)
                          (json-read-file state-file)
                        '()))
               (new-state (cons (cons 'currentTag tag-name)
                                (assq-delete-all 'currentTag state))))
          (with-temp-file state-file
            (insert (json-encode new-state)))
          t)
      (error
       (message "project-dashboard: Error setting tag: %s" err)
       nil))))

(defun project-dashboard--read-taskmaster-json (project-root)
  "Read and parse Task Master tasks.json from PROJECT-ROOT.
Returns nil if file doesn't exist or is invalid.
Only returns tasks for the active tag - no fallback to other tags."
  (let ((tasks-file (expand-file-name ".taskmaster/tasks/tasks.json" project-root)))
    (when (file-exists-p tasks-file)
      (condition-case err
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (data (json-read-file tasks-file))
                 (active-tag (project-dashboard--get-active-tag project-root))
                 (tag-symbol (intern active-tag)))
            ;; Task Master stores tasks under tag name
            ;; Structure is: { "tagname": { "tasks": [...] } }
            ;; Only return tasks for active tag - no fallback
            (alist-get 'tasks (alist-get tag-symbol data)))
        (error
         (message "project-dashboard: Error reading tasks.json: %s" err)
         nil)))))

(defun project-dashboard--parse-tasks (tasks &optional filter-statuses)
  "Parse TASKS and optionally filter by FILTER-STATUSES.
FILTER-STATUSES is a list of status strings like (\"pending\" \"in-progress\").
Returns a list of task plists with :id, :title, :status, :priority, :dependencies."
  (let ((filtered-tasks
         (if filter-statuses
             (seq-filter (lambda (task)
                           (member (alist-get 'status task) filter-statuses))
                         tasks)
           tasks)))
    (mapcar (lambda (task)
              (list :id (alist-get 'id task)
                    :title (alist-get 'title task)
                    :status (alist-get 'status task)
                    :priority (alist-get 'priority task)
                    :dependencies (alist-get 'dependencies task)
                    :description (alist-get 'description task)))
            filtered-tasks)))

(defun project-dashboard--find-next-task (all-tasks)
  "Find the next task to work on from ALL-TASKS (raw alist format).
Returns a plist for the first in-progress task, or first pending task
whose dependencies are all done, or nil."
  (let* ((done-ids (mapcar (lambda (task)
                             (format "%s" (alist-get 'id task)))
                           (seq-filter (lambda (task)
                                         (string= (alist-get 'status task) "done"))
                                       all-tasks)))
         ;; First check for in-progress tasks
         (in-progress (seq-find (lambda (task)
                                  (string= (alist-get 'status task) "in-progress"))
                                all-tasks))
         ;; Then find first pending task with all deps satisfied
         (next-pending (seq-find
                        (lambda (task)
                          (and (string= (alist-get 'status task) "pending")
                               (let ((deps (alist-get 'dependencies task)))
                                 (or (null deps)
                                     (seq-every-p
                                      (lambda (dep)
                                        (member (format "%s" dep) done-ids))
                                      deps)))))
                        all-tasks))
         (result (or in-progress next-pending)))
    (when result
      (list :id (alist-get 'id result)
            :title (alist-get 'title result)
            :status (alist-get 'status result)
            :priority (alist-get 'priority result)
            :description (alist-get 'description result)))))

(defun project-dashboard--get-recently-completed (tasks &optional limit)
  "Get recently completed tasks from TASKS, up to LIMIT (default 5).
Returns list of completed task alists ordered by ID descending (higher = more recent)."
  (when tasks
    (let* ((done-tasks (seq-filter
                        (lambda (task)
                          (string= (alist-get 'status task) "done"))
                        tasks))
           (sorted-done (seq-sort
                         (lambda (a b)
                           (> (string-to-number (format "%s" (alist-get 'id a)))
                              (string-to-number (format "%s" (alist-get 'id b)))))
                         done-tasks)))
      (seq-take sorted-done (or limit 5)))))

(defun project-dashboard--get-all-tags-with-stats (project-root)
  "Get all tags with task statistics from PROJECT-ROOT.
Returns list of plists with :name, :pending, :in-progress, :done counts."
  (let ((tasks-file (expand-file-name ".taskmaster/tasks/tasks.json" project-root)))
    (when (file-exists-p tasks-file)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (data (json-read-file tasks-file)))
            (mapcar
             (lambda (tag-entry)
               (let* ((tag-name (symbol-name (car tag-entry)))
                      (tag-data (cdr tag-entry))
                      (tasks (alist-get 'tasks tag-data))
                      (pending (length (seq-filter
                                        (lambda (task) (string= (alist-get 'status task) "pending"))
                                        tasks)))
                      (in-progress (length (seq-filter
                                            (lambda (task) (string= (alist-get 'status task) "in-progress"))
                                            tasks)))
                      (done (length (seq-filter
                                     (lambda (task) (string= (alist-get 'status task) "done"))
                                     tasks))))
                 (list :name tag-name
                       :pending pending
                       :in-progress in-progress
                       :done done)))
             data))
        (error nil)))))

(defun project-dashboard--get-all-tasks-by-tag (project-root)
  "Get all tasks from all tags in PROJECT-ROOT.
Returns list of plists with :tag, :tasks where :tasks is list of task alists."
  (let ((tasks-file (expand-file-name ".taskmaster/tasks/tasks.json" project-root)))
    (when (file-exists-p tasks-file)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (data (json-read-file tasks-file)))
            (mapcar
             (lambda (tag-entry)
               (let* ((tag-name (symbol-name (car tag-entry)))
                      (tag-data (cdr tag-entry))
                      (tasks (alist-get 'tasks tag-data)))
                 (list :tag tag-name :tasks tasks)))
             data))
        (error nil)))))

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

(defun project-dashboard--resolve-task-source (project-root)
  "Resolve the task source for PROJECT-ROOT.
The buffer-local toggle override wins, then
`project-dashboard-task-source' (`auto' picks org when the project
has declared org files, Task Master otherwise)."
  (or project-dashboard--source-override
      (pcase project-dashboard-task-source
        ('taskmaster 'taskmaster)
        ('org 'org)
        (_ (if (project-dashboard--org-files project-root) 'org 'taskmaster)))))

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
  "Return tag-style stats plists for org FILES.
Shape matches `project-dashboard--get-all-tags-with-stats' so the
tags renderer can be reused: (:name :pending :in-progress :done)."
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
    ;; Render ASCII art (use cached art, specific index, or pick random)
    (unless project-dashboard--current-art
      (setq project-dashboard--current-art
            (if art-index
                (project-dashboard-art-by-index art-index)
              (project-dashboard-art-random))))
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

(defun project-dashboard--render-status (status)
  "Render STATUS with appropriate face."
  (let ((face (pcase status
                ("in-progress" 'project-dashboard-status-in-progress-face)
                ("pending" 'project-dashboard-status-pending-face)
                ("done" 'project-dashboard-status-done-face)
                (_ 'project-dashboard-status-pending-face))))
    (propertize (format "%-12s" status) 'face face)))

(defun project-dashboard--render-priority (priority)
  "Render PRIORITY indicator if high."
  (if (and priority (string= priority "high"))
      (propertize "!" 'face 'project-dashboard-priority-high-face)
    " "))

(defvar-local project-dashboard--active-tag nil
  "The active Task Master tag for this dashboard.")

(defun project-dashboard--priority-value (priority)
  "Convert PRIORITY string to numeric value for sorting (higher = more important)."
  (pcase priority
    ("high" 3)
    ("medium" 2)
    ("low" 1)
    (_ 2)))  ; default to medium

(defun project-dashboard--find-next-task (tasks)
  "Find the next task to work on from TASKS (raw alist format).
Returns a plist with :id, :title, :is-in-progress, or nil.
Algorithm matches Task Master: priority, then dependency count, then ID."
  (when tasks
    (let* (;; Build set of completed task IDs
           (done-ids (mapcar (lambda (task)
                               (format "%s" (alist-get 'id task)))
                             (seq-filter (lambda (task)
                                           (member (alist-get 'status task) '("done" "completed")))
                                         tasks)))
           ;; Check if deps are satisfied
           (deps-satisfied-p (lambda (task)
                               (let ((deps (alist-get 'dependencies task)))
                                 (or (null deps)
                                     (seq-every-p
                                      (lambda (dep)
                                        (member (format "%s" dep) done-ids))
                                      deps)))))
           ;; Get eligible tasks (in-progress or pending with deps satisfied)
           (eligible (seq-filter
                      (lambda (task)
                        (let ((status (alist-get 'status task)))
                          (and (member status '("in-progress" "pending"))
                               (funcall deps-satisfied-p task))))
                      tasks))
           ;; Sort by: status (in-progress first), priority (high->low), 
           ;; dep count (fewer first), ID (lower first)
           (sorted (seq-sort
                    (lambda (a b)
                      (let ((a-in-progress (string= (alist-get 'status a) "in-progress"))
                            (b-in-progress (string= (alist-get 'status b) "in-progress"))
                            (a-priority (project-dashboard--priority-value (alist-get 'priority a)))
                            (b-priority (project-dashboard--priority-value (alist-get 'priority b)))
                            (a-deps (length (or (alist-get 'dependencies a) '())))
                            (b-deps (length (or (alist-get 'dependencies b) '())))
                            (a-id (string-to-number (format "%s" (alist-get 'id a))))
                            (b-id (string-to-number (format "%s" (alist-get 'id b)))))
                        (cond
                         ;; In-progress tasks first
                         ((and a-in-progress (not b-in-progress)) t)
                         ((and b-in-progress (not a-in-progress)) nil)
                         ;; Then by priority (higher first)
                         ((> a-priority b-priority) t)
                         ((< a-priority b-priority) nil)
                         ;; Then by dependency count (fewer first)
                         ((< a-deps b-deps) t)
                         ((> a-deps b-deps) nil)
                         ;; Then by ID (lower first)
                         (t (< a-id b-id)))))
                    eligible))
           (result (car sorted)))
      (when result
        (list :id (alist-get 'id result)
              :title (alist-get 'title result)
              :is-in-progress (string= (alist-get 'status result) "in-progress"))))))

(defun project-dashboard--render-next-task (next-task)
  "Render the Next Task or In Progress section for NEXT-TASK plist."
  (let* ((is-in-progress (plist-get next-task :is-in-progress))
         (header (if is-in-progress "In Progress" "Next Task"))
         (header-face (if is-in-progress
                          'project-dashboard-status-in-progress-face
                        'project-dashboard-section-face)))
    (insert (propertize (format "  %s" header) 'face header-face))
    (when project-dashboard--active-tag
      (insert (propertize (format " (%s)" project-dashboard--active-tag)
                          'face 'project-dashboard-separator-face)))
    (insert (project-dashboard--source-badge))
    (insert "\n\n")
    (if next-task
        (let* ((id (plist-get next-task :id))
               (title (plist-get next-task :title)))
          (insert "    ")
          (insert (propertize (format "#%-4s" id) 'face 'project-dashboard-separator-face))
          (insert (propertize (truncate-string-to-width title 70 nil nil "...")
                              'face 'project-dashboard-task-title-face))
          (insert "\n"))
      (insert (propertize "    No next task\n" 'face 'project-dashboard-status-pending-face)))
    (insert "\n")))

(defun project-dashboard--render-recently-completed (tasks)
  "Render the Recently Completed section with TASKS.
TASKS is a list of task alists with 'id and 'title keys."
  (when tasks
    (insert (propertize "  Recently Completed" 'face 'project-dashboard-section-face))
    (insert "\n\n")
    (dolist (task tasks)
      (let ((id (alist-get 'id task))
            (title (alist-get 'title task)))
        (insert "    ")
        (insert (propertize (format "#%-4s" id) 
                            'face '(:foreground "#928374" :strike-through t)))
        (insert (propertize (truncate-string-to-width (or title "") 70 nil nil "...")
                            'face '(:foreground "#928374" :strike-through t)))
        (insert "\n")))
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
      (let* ((file (car convo))
             (entry (cdr convo))
             (date (agent-recall--display-timestamp
                    (or (plist-get entry :timestamp) "")))
             (label (agent-recall-session-label (plist-get entry :session-id)))
             (preview (or (plist-get entry :preview) ""))
             (line (concat
                    "    "
                    (propertize (format "%-8s" date) 'face 'shadow)
                    (when label
                      (concat (propertize label 'face 'agent-recall-label) "  "))
                    (propertize (truncate-string-to-width preview 60 nil nil "...")
                                'face (if label 'shadow
                                        'project-dashboard-task-title-face)))))
        (insert (propertize line
                            'project-dashboard-transcript file
                            'mouse-face 'highlight
                            'help-echo "RET/click: open transcript"))
        (insert "\n")))
    (insert "\n")))

(defun project-dashboard--source-badge ()
  "Return a propertized badge naming the buffer's task source."
  (propertize (if (eq project-dashboard--task-source 'org) " [org]" " [tm]")
              'face 'project-dashboard-key-face))

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
    (insert (project-dashboard--source-badge))
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
Returns non-nil when rendered, mirroring the has-taskmaster flag
in `project-dashboard--render'."
  (let ((files (project-dashboard--org-files project-root)))
    (if (null files)
        (progn
          (insert (propertize "  Org Tasks" 'face 'project-dashboard-section-face))
          (insert "\n\n")
          (insert (propertize
                   "    No org task files declared — see project-dashboard-org-task-files\n\n"
                   'face 'project-dashboard-status-pending-face))
          t)
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
        ;; The file list doubles as the Tags section: same stats shape,
        ;; same number-key switching.
        (project-dashboard--render-tags-section
         (project-dashboard--org-file-stats files) active-name "Files"))
      t)))

(defun project-dashboard--render-tags-section (tags-stats active-tag &optional title)
  "Render the Tags Overview section with TAGS-STATS.
TAGS-STATS is a list of plists from `project-dashboard--get-all-tags-with-stats'.
ACTIVE-TAG is the currently active tag name to highlight.  TITLE
overrides the section heading (the org source passes \"Files\").
Also stores tag names in `project-dashboard--tags-list' for number-based switching."
  (when tags-stats
    ;; Store tags list for keybinding lookup
    (setq project-dashboard--tags-list
          (mapcar (lambda (tag) (plist-get tag :name)) tags-stats))
    (insert (propertize (format "  %s" (or title "Tags"))
                        'face 'project-dashboard-section-face))
    (insert (project-dashboard--source-badge))
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

(defun project-dashboard--render-tasks-section (tasks)
  "Render the Task Master TASKS section."
  (insert (propertize "  Tasks" 'face 'project-dashboard-section-face))
  (when project-dashboard--active-tag
    (insert (propertize (format " (%s)" project-dashboard--active-tag)
                        'face 'project-dashboard-separator-face)))
  (insert "\n\n")
  (if (null tasks)
      (insert (propertize "    No tasks found\n" 'face 'project-dashboard-status-pending-face))
    (let ((count 0))
      (dolist (task tasks)
        (when (< count project-dashboard-max-tasks)
          (let* ((id (plist-get task :id))
                 (title (plist-get task :title))
                 (status (plist-get task :status))
                 (priority (plist-get task :priority)))
            (insert "    ")
            (insert (propertize (format "#%-4s" id) 'face 'project-dashboard-separator-face))
            (insert (project-dashboard--render-status status))
            (insert (project-dashboard--render-priority priority))
            (insert " ")
            (insert (propertize (truncate-string-to-width (or title "") 70 nil nil "...")
                                'face 'project-dashboard-task-title-face))
            (insert "\n"))
          (cl-incf count)))))
  (insert "\n"))

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
                            ("v" . "Vterm") ("t" . "Tasks") ("s" . "Source"))
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
         (project-name (file-name-nondirectory (directory-file-name project-root)))
         (has-taskmaster nil)
         (has-todo nil))
    (erase-buffer)
    
    ;; Header (ASCII art + project name)
    (project-dashboard--render-header project-name)
    
    ;; Actions legend (right below title)
    (project-dashboard--render-actions-legend)
    
    (insert "\n")
    
    ;; Task sections: org files or Task Master, per resolved source
    (setq project-dashboard--task-source
          (project-dashboard--resolve-task-source project-root))
    (if (eq project-dashboard--task-source 'org)
        (setq has-taskmaster (project-dashboard--render-org-sections project-root))
    (when project-dashboard-show-taskmaster
      (let* ((active-tag (project-dashboard--get-active-tag project-root))
             (tasks (project-dashboard--read-taskmaster-json project-root))
             (all-tags-stats (project-dashboard--get-all-tags-with-stats project-root)))
        (setq project-dashboard--active-tag active-tag)
        ;; Always show tags section if we have any tags
        (when all-tags-stats
          (setq has-taskmaster t)
          (if (null tasks)
              ;; Empty tag - show placeholder message
              (progn
                (insert (propertize "  Next Task" 'face 'project-dashboard-section-face))
                (insert (propertize (format " (%s)" active-tag) 'face 'project-dashboard-separator-face))
                (insert (project-dashboard--source-badge))
                (insert "\n\n")
                (insert (propertize "    Tag is empty — time to add some tasks\n\n" 
                                    'face 'project-dashboard-status-pending-face)))
            ;; Has tasks - render normally
            (let ((next-task (project-dashboard--find-next-task tasks))
                  (recently-completed (project-dashboard--get-recently-completed tasks 5))
                  (filtered (project-dashboard--parse-tasks tasks '("in-progress" "pending"))))
              (setq project-dashboard--taskmaster-data filtered)
              ;; 1. Focus Task (In Progress / Next Task) at top
              (project-dashboard--render-next-task next-task)
              ;; 2. Recently Completed section
              (project-dashboard--render-recently-completed recently-completed)))
          ;; 3. Tags overview at bottom (always show)
          (project-dashboard--render-tags-section all-tags-stats active-tag)))))

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
            (setq has-todo t)
            (project-dashboard--render-todo-section todos file-path)))))
    
    ;; Show message if no tasks found
    (when (and (not has-taskmaster) (not has-todo))
      (insert (propertize "  No tasks or TODO files found in this project\n\n"
                          'face 'project-dashboard-status-pending-face)))
    
    (goto-char (point-min))))

;;; Action Functions

(defun project-dashboard-open-agent-shell ()
  "Open a new agent-shell conversation for the current project."
  (interactive)
  (let ((default-directory project-dashboard--project-root))
    (if (fboundp 'agent-shell-new-shell)
        (agent-shell-new-shell)
      (message "agent-shell not available"))))

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

(defun project-dashboard-open-tasks-file ()
  "Open the tasks file for editing."
  (interactive)
  (let ((taskmaster-file (expand-file-name ".taskmaster/tasks/tasks.json"
                                           project-dashboard--project-root))
        (todo-file (car project-dashboard--todo-data)))
    (cond
     ;; Both exist - use ivy to choose if available
     ((and (file-exists-p taskmaster-file) todo-file)
      (if (fboundp 'ivy-read)
          (ivy-read "Open tasks file: "
                    (list (cons "Task Master (tasks.json)" taskmaster-file)
                          (cons (format "TODO (%s)" (file-name-nondirectory todo-file)) todo-file))
                    :action (lambda (choice)
                              (find-file (cdr choice))))
        ;; Fallback to Task Master if no ivy
        (find-file taskmaster-file)))
     ((file-exists-p taskmaster-file)
      (find-file taskmaster-file))
     (todo-file
      (find-file todo-file))
     (t
      (message "No tasks file found in project")))))

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
project root, saves the variable via Customize, and switches this
dashboard to the org source immediately."
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
    (setq project-dashboard--source-override 'org)
    (project-dashboard-refresh)
    (message "Org task file added: %s" file)))

(defun project-dashboard-toggle-task-source ()
  "Toggle this dashboard between Task Master and org task sources."
  (interactive)
  (let ((target (if (eq project-dashboard--task-source 'org) 'taskmaster 'org)))
    (when (and (eq target 'org)
               (null (project-dashboard--org-files project-dashboard--project-root)))
      (user-error "No org task files declared for this project (see `project-dashboard-org-task-files')"))
    (setq project-dashboard--source-override target)
    (project-dashboard-refresh)
    (message "Task source: %s" target)))

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
  "Switch to tag number N (1-indexed) from the tags list."
  (interactive "p")
  (if (and project-dashboard--tags-list
           (> n 0)
           (<= n (length project-dashboard--tags-list)))
      (let ((tag-name (nth (1- n) project-dashboard--tags-list)))
        (if (eq project-dashboard--task-source 'org)
            ;; Org source: rows are org files; switch the active one.
            (progn
              (setq project-dashboard--active-org-file
                    (nth (1- n) project-dashboard--org-files-list))
              (message "Switched to: %s" tag-name)
              (project-dashboard--with-preserved-position
               (project-dashboard--render)))
          (when (project-dashboard--set-active-tag project-dashboard--project-root tag-name)
            (message "Switched to tag: %s" tag-name)
            (project-dashboard--with-preserved-position
             (project-dashboard--render)))))
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

(defvar project-dashboard-tasks-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") #'project-dashboard-open-tag-tasks)
    (define-key map (kbd "T") #'project-dashboard-open-all-tasks)
    (define-key map (kbd "f") #'project-dashboard-open-tasks-file)
    map)
  "Keymap for task-related commands under 't' prefix.")

(defvar project-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'project-dashboard-open-agent-shell)
    (define-key map (kbd "d") #'project-dashboard-open-dired)
    (define-key map (kbd "m") #'project-dashboard-open-magit)
    (define-key map (kbd "D") #'project-dashboard-open-link)
    (define-key map (kbd "f") #'project-dashboard-find-file)
    (define-key map (kbd "v") #'project-dashboard-open-vterm)
    (define-key map (kbd "t") project-dashboard-tasks-map)
    (define-key map (kbd "r") #'project-dashboard-refresh)
    (define-key map (kbd "g") #'project-dashboard-refresh)
    (define-key map (kbd "q") #'project-dashboard-quit)
    (define-key map (kbd "RET") #'project-dashboard-open-at-point)
    (define-key map [mouse-1] #'project-dashboard-mouse-open)
    (define-key map (kbd "s") #'project-dashboard-toggle-task-source)
    (define-key map (kbd "S") #'project-dashboard-add-org-file)
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
    (kbd "t t") #'project-dashboard-open-tag-tasks
    (kbd "t T") #'project-dashboard-open-all-tasks
    (kbd "t f") #'project-dashboard-open-tasks-file
    (kbd "r") #'project-dashboard-refresh
    (kbd "R") #'project-dashboard-new-art
    (kbd "gr") #'project-dashboard-refresh
    (kbd "q") #'project-dashboard-quit
    (kbd "s") #'project-dashboard-toggle-task-source
    (kbd "S") #'project-dashboard-add-org-file
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

;;; All Tasks View

(defvar-local project-dashboard-all-tasks--project-root nil
  "Project root for the all-tasks buffer.")

(defun project-dashboard--render-all-tasks-buffer (project-root)
  "Render the all-tasks buffer for PROJECT-ROOT."
  (let ((inhibit-read-only t)
        (all-tags-tasks (project-dashboard--get-all-tasks-by-tag project-root))
        (project-name (file-name-nondirectory (directory-file-name project-root))))
    (erase-buffer)
    (insert "\n")
    (insert (propertize (format "  All Tasks: %s\n" project-name)
                        'face 'project-dashboard-header-face))
    (insert (propertize (format "  %s\n\n" (make-string 50 ?─))
                        'face 'project-dashboard-separator-face))
    (if (null all-tags-tasks)
        (insert (propertize "  No tasks found\n" 'face 'project-dashboard-status-pending-face))
      (dolist (tag-group all-tags-tasks)
        (let ((tag-name (plist-get tag-group :tag))
              (tasks (plist-get tag-group :tasks)))
          ;; Tag header
          (insert (propertize (format "  %s" tag-name) 'face 'project-dashboard-section-face))
          (insert (propertize (format " (%d tasks)\n\n" (length tasks))
                              'face 'project-dashboard-separator-face))
          ;; Tasks under this tag
          (if (null tasks)
              (insert (propertize "    No tasks\n" 'face 'project-dashboard-status-pending-face))
            (dolist (task tasks)
              (let* ((id (alist-get 'id task))
                     (title (alist-get 'title task))
                     (status (alist-get 'status task))
                     (priority (alist-get 'priority task))
                     (status-face (pcase status
                                    ("in-progress" 'project-dashboard-status-in-progress-face)
                                    ("done" 'project-dashboard-status-done-face)
                                    (_ 'project-dashboard-status-pending-face))))
                (insert "    ")
                (insert (propertize (format "#%-4s" id) 'face 'project-dashboard-separator-face))
                (insert (propertize (format "%-12s" status) 'face status-face))
                (when (and priority (string= priority "high"))
                  (insert (propertize "! " 'face 'project-dashboard-priority-high-face)))
                (unless (and priority (string= priority "high"))
                  (insert "  "))
                (insert (propertize (truncate-string-to-width (or title "") 60 nil nil "...")
                                    'face 'project-dashboard-task-title-face))
                (insert "\n"))))
          (insert "\n"))))
    (insert (propertize (format "  %s\n" (make-string 50 ?─))
                        'face 'project-dashboard-separator-face))
    (insert "\n")
    (insert (propertize "  [q] Back to dashboard\n" 'face 'project-dashboard-key-face))
    (goto-char (point-min))))

(defvar project-dashboard-all-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'project-dashboard-all-tasks-quit)
    (define-key map (kbd "g") #'project-dashboard-all-tasks-refresh)
    (define-key map (kbd "r") #'project-dashboard-all-tasks-refresh)
    map)
  "Keymap for `project-dashboard-all-tasks-mode'.")

(define-derived-mode project-dashboard-all-tasks-mode special-mode "AllTasks"
  "Major mode for displaying all tasks across all tags."
  (setq buffer-read-only t)
  (setq truncate-lines t))

(with-eval-after-load 'evil
  (evil-set-initial-state 'project-dashboard-all-tasks-mode 'normal)
  (evil-define-key 'normal project-dashboard-all-tasks-mode-map
    (kbd "q") #'project-dashboard-all-tasks-quit
    (kbd "gr") #'project-dashboard-all-tasks-refresh))

(defun project-dashboard-all-tasks-quit ()
  "Quit the all-tasks view and return to dashboard."
  (interactive)
  (let ((project-root project-dashboard-all-tasks--project-root))
    (quit-window)
    (when project-root
      (project-dashboard-open project-root))))

(defun project-dashboard-all-tasks-refresh ()
  "Refresh the all-tasks view."
  (interactive)
  (project-dashboard--render-all-tasks-buffer project-dashboard-all-tasks--project-root)
  (message "All tasks refreshed"))

(defun project-dashboard-open-all-tasks ()
  "Open the all-tasks view for the current project."
  (interactive)
  (let* ((project-root project-dashboard--project-root)
         (buf-name (format "*All Tasks: %s*"
                           (file-name-nondirectory (directory-file-name project-root))))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'project-dashboard-all-tasks-mode)
        (project-dashboard-all-tasks-mode))
      (setq project-dashboard-all-tasks--project-root project-root)
      (project-dashboard--render-all-tasks-buffer project-root))
    (switch-to-buffer buf)))

(defvar-local project-dashboard-tag-tasks--tag-name nil
  "Tag name for the tag-tasks buffer.")

(defun project-dashboard--render-tag-tasks-buffer (project-root tag-name)
  "Render the tag-tasks buffer for TAG-NAME in PROJECT-ROOT."
  (let* ((inhibit-read-only t)
         (all-tags-tasks (project-dashboard--get-all-tasks-by-tag project-root))
         (tag-data (seq-find (lambda (task) (string= (plist-get task :tag) tag-name)) all-tags-tasks))
         (tasks (plist-get tag-data :tasks))
         (project-name (file-name-nondirectory (directory-file-name project-root))))
    (erase-buffer)
    (insert "\n")
    (insert (propertize (format "  Tasks: %s" tag-name)
                        'face 'project-dashboard-header-face))
    (insert (propertize (format " (%s)\n" project-name)
                        'face 'project-dashboard-separator-face))
    (insert (propertize (format "  %s\n\n" (make-string 50 ?─))
                        'face 'project-dashboard-separator-face))
    (if (null tasks)
        (insert (propertize "  No tasks in this tag\n" 'face 'project-dashboard-status-pending-face))
      (dolist (task tasks)
        (let* ((id (alist-get 'id task))
               (title (alist-get 'title task))
               (status (alist-get 'status task))
               (priority (alist-get 'priority task))
               (status-face (pcase status
                              ("in-progress" 'project-dashboard-status-in-progress-face)
                              ("done" 'project-dashboard-status-done-face)
                              (_ 'project-dashboard-status-pending-face))))
          (insert "    ")
          (insert (propertize (format "#%-4s" id) 'face 'project-dashboard-separator-face))
          (insert (propertize (format "%-12s" status) 'face status-face))
          (when (and priority (string= priority "high"))
            (insert (propertize "! " 'face 'project-dashboard-priority-high-face)))
          (unless (and priority (string= priority "high"))
            (insert "  "))
          (insert (propertize (truncate-string-to-width (or title "") 60 nil nil "...")
                              'face 'project-dashboard-task-title-face))
          (insert "\n"))))
    (insert "\n")
    (insert (propertize (format "  %s\n" (make-string 50 ?─))
                        'face 'project-dashboard-separator-face))
    (insert "\n")
    (insert (propertize "  [q] Back to dashboard\n" 'face 'project-dashboard-key-face))
    (goto-char (point-min))))

(defvar project-dashboard-tag-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'project-dashboard-tag-tasks-quit)
    (define-key map (kbd "g") #'project-dashboard-tag-tasks-refresh)
    (define-key map (kbd "r") #'project-dashboard-tag-tasks-refresh)
    map)
  "Keymap for `project-dashboard-tag-tasks-mode'.")

(define-derived-mode project-dashboard-tag-tasks-mode special-mode "TagTasks"
  "Major mode for displaying tasks for a specific tag."
  (setq buffer-read-only t)
  (setq truncate-lines t))

(with-eval-after-load 'evil
  (evil-set-initial-state 'project-dashboard-tag-tasks-mode 'normal)
  (evil-define-key 'normal project-dashboard-tag-tasks-mode-map
    (kbd "q") #'project-dashboard-tag-tasks-quit
    (kbd "gr") #'project-dashboard-tag-tasks-refresh))

(defun project-dashboard-tag-tasks-quit ()
  "Quit the tag-tasks view and return to dashboard."
  (interactive)
  (let ((project-root project-dashboard-all-tasks--project-root))
    (quit-window)
    (when project-root
      (project-dashboard-open project-root))))

(defun project-dashboard-tag-tasks-refresh ()
  "Refresh the tag-tasks view."
  (interactive)
  (project-dashboard--render-tag-tasks-buffer 
   project-dashboard-all-tasks--project-root
   project-dashboard-tag-tasks--tag-name)
  (message "Tag tasks refreshed"))

(defun project-dashboard-open-tag-tasks ()
  "Open the tasks view for the currently active tag."
  (interactive)
  (let* ((project-root project-dashboard--project-root)
         (tag-name project-dashboard--active-tag)
         (buf-name (format "*Tasks: %s (%s)*"
                           tag-name
                           (file-name-nondirectory (directory-file-name project-root))))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'project-dashboard-tag-tasks-mode)
        (project-dashboard-tag-tasks-mode))
      (setq project-dashboard-all-tasks--project-root project-root)
      (setq project-dashboard-tag-tasks--tag-name tag-name)
      (project-dashboard--render-tag-tasks-buffer project-root tag-name))
    (switch-to-buffer buf)))

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
  "Open a new agent-shell conversation in project NAME."
  (interactive "sProject: ")
  (when-let ((path (project-dashboard--resolve-path name)))
    (let ((default-directory path))
      (agent-shell-new-shell))))

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
