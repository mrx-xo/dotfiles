;;; forgejo-review-navigation.el --- Visit the source shown in a PR -*- lexical-binding: t; -*-

;;; Commentary:
;; Forgejo downloads raw patches without selecting the corresponding checkout.
;; Resolve source jumps against PR metadata, prefer matching worktree files,
;; and otherwise display a read-only API snapshot.  Check the patch's blob ID
;; before opening anything so an updated PR cannot silently change the source.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'magit)
(require 'forgejo-api)

(defvar forgejo-diff--pr-number)
(defvar forgejo-repo--host)
(defvar forgejo-repo--owner)
(defvar forgejo-repo--name)

(defun mr-x/forgejo-diff-location (&optional other-file)
  "Return the path, blob ID, side, and line at point in a Git diff.
OTHER-FILE selects the opposite side.  File headers visit line one;
removed lines visit the old source, while other lines visit the new source."
  (save-excursion
    (save-restriction
      ;; Header helpers otherwise skip binary or rename-only entries and can
      ;; resolve a hunk from the next file instead.
      (let ((position (point)) start end)
        (beginning-of-line)
        (unless (looking-at "^diff --git ")
          (unless (re-search-backward "^diff --git " nil t)
            (user-error "No Git file header at point")))
        (setq start (point))
        (forward-line 1)
        (setq end (if (re-search-forward "^diff --git " nil t)
                      (line-beginning-position)
                    (point-max)))
        (narrow-to-region start end)
        (goto-char position))
      (let* ((target (line-beginning-position))
             (header (diff--at-diff-header-p))
             (file-header (and header
                               (not (save-excursion
                                      (beginning-of-line) (looking-at "@@ ")))))
             (old (and (not header) (eq (char-after target) ?-)))
             (old (if other-file (not old) old))
             (hunk (diff-beginning-of-hunk t))
             ;; Read plain header text: extracting fontified strings here can
             ;; trigger diff syntax fontification inside our narrowed region.
             (names (save-excursion
                      (goto-char (point-min))
                      (when (re-search-forward
                             "^--- \\([^\t\n]+\\).*\n\\+\\+\\+ \\([^\t\n]+\\)" hunk t)
                        (list (match-string-no-properties 1)
                              (match-string-no-properties 2)))))
             (name (nth (if old 0 1) names))
             blob line)
	;; A deleted file has no new side, including when visiting its header.
	(when (equal name "/dev/null")
          (setq old (not old) name (nth (if old 0 1) names)))
	(unless (and name (looking-at
                           "@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? +\\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@"))
          (user-error "No source hunk at point"))
	(setq line (string-to-number (match-string (if old 1 2))))
	(forward-line 1)
	(while (< (point) target)
          (unless (memq (char-after) (if old '(?+ ?\\) '(?- ?\\)))
            (setq line (1+ line)))
          (forward-line 1))
	(goto-char hunk)
	(unless (re-search-backward "^diff --git " nil t)
          (user-error "No Git file header at point"))
	(unless (re-search-forward "^index \\([[:xdigit:]]+\\)\\.\\.\\([[:xdigit:]]+\\)" hunk t)
          (user-error "The diff has no source blob ID"))
	(setq blob (match-string-no-properties (if old 1 2))
              name (replace-regexp-in-string
                    "\\`[ab]/" "" (magit-decode-git-path (substring-no-properties name))))
	(when (or (file-name-absolute-p name)
                  (member ".." (split-string name "/")))
          (user-error "Invalid source path in diff"))
	(list :path name :blob blob :old old :line (if file-header 1 (max 1 line)))))))

(defun mr-x/forgejo-source-worktree (revision path blob)
  "Find an unchanged PATH at REVISION in this repository's worktrees.
The file must match BLOB and have no unsaved edits.  Return its path or nil."
  (when (and (not (file-remote-p default-directory)) (magit-toplevel))
    (cl-loop for tree in (magit-list-worktrees)
             for directory = (car tree)
             for file = (expand-file-name path directory)
             for buffer = (find-buffer-visiting file)
             when (and (equal (nth 1 tree) revision)
                       (file-regular-p file)
                       (not (file-symlink-p file))
                       (file-in-directory-p (file-truename file) directory)
                       (or (not buffer)
                           (and (not (buffer-modified-p buffer))
                                (verify-visited-file-modtime buffer)))
                       (let* ((default-directory (file-name-as-directory directory))
                              (hash (magit-git-string "hash-object" "--" path)))
                         (and hash (string-prefix-p blob hash))))
             return file)))

(defun mr-x/forgejo-show-source (buffer line)
  "Display BUFFER at source LINE."
  (pop-to-buffer buffer)
  (goto-char (point-min))
  (forward-line (1- line)))

(defun mr-x/forgejo-source-snapshot (data host owner repo number location)
  "Display API DATA for LOCATION in PR NUMBER on HOST, OWNER, and REPO."
  (unless (and (stringp (alist-get 'sha data))
               (string-prefix-p (plist-get location :blob) (alist-get 'sha data)))
    (user-error "PR source changed since this diff loaded; reopen the diff"))
  (unless (and (equal (alist-get 'encoding data) "base64")
               (stringp (alist-get 'content data)))
    (user-error "The API did not return source text for this file"))
  (let* ((path (plist-get location :path))
         (text (decode-coding-string (base64-decode-string (alist-get 'content data)) 'utf-8))
         (buffer (get-buffer-create
                  (format "*PR source: %s/%s/%s#%d %s @%s*"
                          (url-host (url-generic-parse-url host)) owner repo number
                          path (substring (alist-get 'sha data) 0 8)))))
    (when (string-match-p "\0" text)
      (user-error "Cannot display binary PR source as text"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      ;; Select syntax without running file hooks or evaluating file variables.
      (let ((buffer-file-name path)
            (enable-local-variables nil)
            (enable-local-eval nil))
        (delay-mode-hooks (set-auto-mode)))
      (setq buffer-read-only t
            header-line-format (format "PR #%d: %s (read-only %s source)"
                                       number path (if (plist-get location :old) "old" "new")))
      (set-buffer-modified-p nil)
      (font-lock-mode 1))
    (mr-x/forgejo-show-source buffer (plist-get location :line))))

(defun mr-x/forgejo-diff-goto-source (original &optional other-file event)
  "Visit PR source for Forgejo diffs; otherwise call ORIGINAL normally."
  (if (not (and (derived-mode-p 'diff-mode)
                (bound-and-true-p forgejo-diff--pr-number)
                (bound-and-true-p forgejo-repo--host)))
      (funcall original other-file event)
    (when event (posn-set-point (event-end event)))
    (let* ((origin (current-buffer))
           (tick (buffer-chars-modified-tick))
           (directory default-directory)
           (host forgejo-repo--host)
           (owner forgejo-repo--owner)
           (repo forgejo-repo--name)
           (number forgejo-diff--pr-number)
           (location (mr-x/forgejo-diff-location other-file))
           (path (plist-get location :path))
           (valid (lambda ()
                    (and (buffer-live-p origin)
                         (with-current-buffer origin
                           (= tick (buffer-chars-modified-tick)))))))
      (message "Resolving PR #%d source..." number)
      (forgejo-api-get
       host (format "repos/%s/%s/pulls/%d" owner repo number) nil
       (lambda (data _headers)
         (when (funcall valid)
           (let* ((default-directory directory)
                  (revision (if (plist-get location :old)
                                (or (alist-get 'merge_base data)
                                    (alist-get 'sha (alist-get 'base data)))
                              (alist-get 'sha (alist-get 'head data))))
                  (file (and revision
                             (mr-x/forgejo-source-worktree revision path (plist-get location :blob)))))
             (unless revision (user-error "PR metadata has no source revision"))
             (if file
                 (progn
                   (with-current-buffer origin
                     (setq default-directory
                           (file-name-as-directory (magit-toplevel (file-name-directory file)))))
                   (mr-x/forgejo-show-source (find-file-noselect file) (plist-get location :line)))
               (forgejo-api-get
                host (format "repos/%s/%s/contents/%s" owner repo
                             (mapconcat #'url-hexify-string (split-string path "/") "/"))
                `(("ref" . ,revision))
                (lambda (source _source-headers)
                  (when (funcall valid)
                    (mr-x/forgejo-source-snapshot source host owner repo number location))))))))))))

(advice-add 'diff-goto-source :around #'mr-x/forgejo-diff-goto-source)

(declare-function review-session-source "review-session")
(declare-function review-session-directory "review-session")
(declare-function review-source-recipe "review-source")

(defun mr-x/forgejo-review-visit (session file side line)
  "Open FILE's SIDE at LINE for a Forgejo review SESSION.
A worktree at the matching blob wins; otherwise a read-only API snapshot."
  (let ((recipe (review-source-recipe (review-session-source session))))
    (when (eq (plist-get recipe :kind) 'forgejo)
      (let* ((revs (or (plist-get recipe :revs)
                       (user-error "PR revisions are not known yet; press gr to refresh")))
             (revision (if (eq side 'old) (car revs) (cadr revs)))
             (path (if (eq side 'old) (plist-get file :old-path) (plist-get file :path)))
             (blob (nth (if (eq side 'old) 0 1) (plist-get file :blobs)))
             (default-directory (or (review-session-directory session) default-directory))
             (worktree (mr-x/forgejo-source-worktree revision path blob)))
        (when (or (null path)
                  (null blob)
                  (and (eq side 'old) (eq (plist-get file :kind) 'added))
                  (and (eq side 'new) (eq (plist-get file :kind) 'deleted)))
          (user-error "No %s side for %s in this PR" side
                      (or (plist-get file :path) (plist-get file :old-path))))
        (if worktree
            (mr-x/forgejo-show-source (find-file-noselect worktree) line)
          (let ((host (plist-get recipe :host)) (owner (plist-get recipe :owner))
                (repo (plist-get recipe :repo)) (number (plist-get recipe :number)))
            (forgejo-api-get
             host (format "repos/%s/%s/contents/%s" owner repo
                          (mapconcat #'url-hexify-string (split-string path "/") "/"))
             `(("ref" . ,revision))
             (lambda (data _headers)
               (mr-x/forgejo-source-snapshot data host owner repo number
                                             (list :path path :line line :old (eq side 'old) :blob blob))))))
        t))))

(with-eval-after-load 'review-session
  (add-hook 'review-session-visit-functions #'mr-x/forgejo-review-visit))

(provide 'forgejo-review-navigation)
;;; forgejo-review-navigation.el ends here
