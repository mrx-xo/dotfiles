;;; syzygy-handoff.el --- Cross-machine agent-session handoff (MrX <-> MrX2) -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Resume an agent-shell conversation started on another fleet machine.
;; Handoffs are staged into ~/shared/agent-sessions/ (Syncthing) by
;; agent-session-handoff.sh export; `syzygy-resume-handoff' (SPC c H)
;; imports one and resumes it locally.  See the script for the path
;; translation (home swap + symlink resolution).
;;
;; NOTE: loaded from agent-shell-config.el; must NOT hard-require
;; agent-shell (Elpaca hasn't activated packages in batch mode).

;;; Code:

(declare-function agent-shell--start "agent-shell")
(defvar agent-shell-preferred-agent-config)

(defconst syzygy-handoff-script
  (expand-file-name "~/.dotfiles/macos/syzygy/agent-session-handoff.sh")
  "Path to the export/import/sync script.")

(defun syzygy-handoff--read-meta (file)
  "Parse KEY=VALUE lines of a handoff meta FILE into an alist.
Values are read literally (never eval'd), so titles may contain spaces."
  (with-temp-buffer
    (insert-file-contents file)
    (let (kv)
      (dolist (line (split-string (buffer-string) "\n" t))
        (when (string-match "\\`\\([A-Z_]+\\)=\\(.*\\)\\'" line)
          (push (cons (match-string 1 line) (match-string 2 line)) kv)))
      (nreverse kv))))

(defun syzygy-handoff--candidates ()
  "Return resumable handoffs staged for this machine.

Scans both the Syncthing peer path (~/shared/agent-sessions, flat) and
the home-lab sync mirror (~/.local/share/agent-session-handoff, machine
subdirs).  Each candidate is a plist (:id :tgt-cwd :title :machine
:project :mtime).  Filters out handoffs that originated here, and —
crucially — those whose project cwd does NOT exist locally: you can't
stand up the agent in a directory you don't have, so the chat simply
isn't offered (it reappears on its own if you ever set that project
up).  Deduped by session id."
  (let* ((shared (expand-file-name "~/shared/agent-sessions/"))
         (staging (expand-file-name "~/.local/share/agent-session-handoff/"))
         (this-machine
          (string-trim
           (or (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "~/.config/machine-id"))
                   (buffer-string)))
               "")))
         (metas (append
                 (and (file-directory-p shared)
                      (directory-files shared t "\\.meta\\'"))
                 (and (file-directory-p staging)
                      (directory-files-recursively staging "\\.meta\\'"))))
         (seen (make-hash-table :test 'equal)))
    (delq nil
          (mapcar
           (lambda (m)
             (let* ((kv (syzygy-handoff--read-meta m))
                    (id (cdr (assoc "SESSION_ID" kv)))
                    (src-home (cdr (assoc "SRC_HOME" kv)))
                    (src-cwd (cdr (assoc "SRC_CWD" kv)))
                    (src-mach (cdr (assoc "SRC_MACHINE" kv)))
                    (title (cdr (assoc "TITLE" kv))))
               (when (and id src-home src-cwd
                          (not (equal src-mach this-machine))
                          (not (gethash id seen)))
                 (let* ((tgt-raw (if (string-prefix-p src-home src-cwd)
                                     (concat (expand-file-name "~")
                                             (substring src-cwd (length src-home)))
                                   src-cwd))
                        (tgt-cwd (file-truename tgt-raw)))
                   ;; Only offer chats whose project dir exists here.
                   (when (file-directory-p tgt-cwd)
                     (puthash id t seen)
                     (list :id id :tgt-cwd tgt-cwd
                           :title (if (and title (not (string-empty-p title)))
                                      title "(untitled)")
                           :machine (or src-mach "?")
                           :project (file-name-nondirectory
                                     (directory-file-name tgt-cwd))
                           ;; conversation recency: the staged jsonl's
                           ;; mtime (stage_session cp -p preserves it,
                           ;; rsync -a carries it through the hub)
                           :mtime (file-attribute-modification-time
                                   (file-attributes
                                    (expand-file-name
                                     (concat id ".jsonl")
                                     (file-name-directory m))))))))))
           metas))))

(defconst syzygy-handoff--machine-colors
  '(("mrx" . "#fe8019") ("mrx2" . "#8ec07c")
    ("vengeance" . "#fb4934") ("home-lab" . "#b8bb26"))
  "Machine name -> gruvbox accent, per the color-is-machine convention.")

(defun syzygy-handoff--age (mtime)
  "Compact relative age of MTIME: 5m, 3h, 2d — or ? when unknown."
  (if (null mtime) "?"
    (let ((s (float-time (time-subtract (current-time) mtime))))
      (cond ((< s 3600) (format "%dm" (max 1 (/ s 60))))
            ((< s 86400) (format "%dh" (/ s 3600)))
            (t (format "%dd" (/ s 86400)))))))

(defun syzygy-handoff--read (candidates)
  "Pick one of CANDIDATES with marginalia-style annotations.

The candidate is the chat title (plus a dim #id chip that also keeps
identical titles distinct for `completing-read').  Annotations are
aligned columns — machine (colored per machine), age — and rows are
grouped by project and sorted newest-first, consult-style."
  (let* ((table
          (mapcar (lambda (pl)
                    ;; Pad the title to a FIXED 72 columns (truncate
                    ;; long, space-fill short) so the id chip and the
                    ;; annotation columns line up on every row.  ASCII
                    ;; ellipsis on purpose: fonts often draw Unicode …
                    ;; wider than the 1 column Emacs counts it as,
                    ;; nudging truncated rows out of alignment.
                    (cons (concat
                           (truncate-string-to-width
                            (plist-get pl :title) 72 nil ?\s "...")
                           (propertize
                            (format "  #%s" (substring (plist-get pl :id) 0 8))
                            'face 'shadow))
                          pl))
                  candidates))
         (lookup (lambda (cand) (cdr (assoc cand table))))
         (annotate
          (lambda (cand)
            (let* ((pl (funcall lookup cand))
                   (mach (plist-get pl :machine))
                   (color (or (cdr (assoc mach syzygy-handoff--machine-colors))
                              "#928374")))
              (concat
               "   "
               (propertize (format "%-10s" mach)
                           'face `(:foreground ,color :weight bold))
               (propertize (format "%6s ago" (syzygy-handoff--age
                                              (plist-get pl :mtime)))
                           'face 'shadow)))))
         (newest-first
          (lambda (cands)
            (sort cands
                  (lambda (a b)
                    (time-less-p
                     (or (plist-get (funcall lookup b) :mtime) 0)
                     (or (plist-get (funcall lookup a) :mtime) 0))))))
         (group
          (lambda (cand transform)
            (if transform cand
              (plist-get (funcall lookup cand) :project))))
         (choice
          (completing-read
           "Resume handoff: "
           (lambda (str pred action)
             (if (eq action 'metadata)
                 `(metadata (category . syzygy-handoff)
                            (annotation-function . ,annotate)
                            (display-sort-function . ,newest-first)
                            (group-function . ,group))
               (complete-with-action action (mapcar #'car table) str pred)))
           nil t)))
    (funcall lookup choice)))

;;;###autoload
(defun syzygy-resume-handoff (&optional sync)
  "Resume an agent-shell conversation from another fleet machine.

Candidates come from `syzygy-handoff--candidates' (see it for the
staging paths and filtering), presented by `syzygy-handoff--read'
(auto-picked when there's only one).  Imports the transcript into the
local ~/.claude (paths rewritten and symlinks resolved by the script),
then resumes — forcing the resolved project cwd and the Claude config so
no agent picker appears and the cwd can't mismatch (a mismatch silently
yields a BLANK shell).

The candidate list is populated by `agent-session-handoff.sh sync'.  With
a prefix argument (\\[universal-argument]), run that sync first to pull the
latest sessions from the other machines before listing."
  (interactive "P")
  (let* ((_ (when sync
              (message "Syncing handoffs…")
              (with-temp-buffer
                (if (zerop (call-process "bash" nil t nil
                                         syzygy-handoff-script "sync"))
                    (message "Handoff sync done")
                  (message "Handoff sync failed: %s"
                           (string-trim (buffer-string)))))))
         (candidates (syzygy-handoff--candidates)))
    (unless candidates
      (user-error "No resumable handoffs — run `agent-session-handoff.sh sync', or the projects aren't set up here"))
    (let* ((pl (if (= (length candidates) 1)
                   (car candidates)
                 (syzygy-handoff--read candidates)))
           (id (plist-get pl :id))
           (tgt-cwd (plist-get pl :tgt-cwd)))
      ;; Place the transcript at the resolved path (script rewrites paths).
      (with-temp-buffer
        (unless (zerop (call-process "bash" nil t nil
                                     syzygy-handoff-script "import" id))
          (user-error "Handoff import failed: %s"
                      (string-trim (buffer-string)))))
      ;; Resume with forced cwd + Claude config: no picker, no mismatch.
      (let ((default-directory (file-name-as-directory tgt-cwd)))
        (agent-shell--start
         :config agent-shell-preferred-agent-config
         :session-id id
         :new-session t))
      (message "Resumed handoff %s in %s" id tgt-cwd))))

(provide 'syzygy-handoff)
;;; syzygy-handoff.el ends here
