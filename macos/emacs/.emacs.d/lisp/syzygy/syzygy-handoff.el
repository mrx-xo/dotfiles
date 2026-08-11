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
subdirs).  Each candidate is (LABEL . (:id ID :tgt-cwd DIR)).  Filters
out handoffs that originated here, and — crucially — those whose project
cwd does NOT exist locally: you can't stand up the agent in a directory
you don't have, so the chat simply isn't offered (it reappears on its
own if you ever set that project up).  Deduped by session id."
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
                     (cons (format "%s  ·  %s  ·  %s"
                                   (if (and title (not (string-empty-p title)))
                                       title "(untitled)")
                                   (or src-mach "?")
                                   (file-name-nondirectory
                                    (directory-file-name tgt-cwd)))
                           (list :id id :tgt-cwd tgt-cwd)))))))
           metas))))

;;;###autoload
(defun syzygy-resume-handoff ()
  "Resume an agent-shell conversation from another fleet machine.

Candidates come from `syzygy-handoff--candidates' (see it for the
staging paths and filtering).  Picks one (auto if there's only one),
imports its transcript into the local ~/.claude (paths rewritten and
symlinks resolved by the script), then resumes — forcing the resolved
project cwd and the Claude config so no agent picker appears and the cwd
can't mismatch (a mismatch silently yields a BLANK shell).

Populate the list with `agent-session-handoff.sh sync'."
  (interactive)
  (let ((candidates (syzygy-handoff--candidates)))
    (unless candidates
      (user-error "No resumable handoffs — run `agent-session-handoff.sh sync', or the projects aren't set up here"))
    (let* ((choice
            (if (= (length candidates) 1)
                (car candidates)
              (assoc (completing-read "Resume handoff: "
                                      (mapcar #'car candidates) nil t)
                     candidates)))
           (pl (cdr choice))
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
