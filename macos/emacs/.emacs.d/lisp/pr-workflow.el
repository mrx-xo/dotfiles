;;; pr-workflow.el --- Shared GitHub and Forgejo PR actions -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep provider UIs and credentials, while sharing entry points and commands.
;; A Magit diff remembers its PR only while its original range is displayed.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'hydra)
(require 'forge)
(require 'forgejo-db)
(require 'forgejo-pull)
(require 'forgejo-vc)
(require 'forgejo-review)
(require 'forgejo-merge)
(require 'forgejo-review-ediff)
(require 'review-source)
(require 'review-session)
(require 'review-panel)
(require 'review-store)
(require 'review-walkthrough)

(with-eval-after-load 'review-store
  (add-to-list 'review-store-refresh-functions
               (cons 'forgejo (lambda (recipe _record)
                                (mr-x/pr--review-forgejo (plist-get recipe :host) (plist-get recipe :owner)
                                                         (plist-get recipe :repo) (plist-get recipe :number))))))

(with-eval-after-load 'review-walkthrough
  (add-to-list 'review-walkthrough-open-functions
               (cons 'forgejo (lambda (target)
                                (mr-x/pr--review-forgejo (plist-get target :host) (plist-get target :owner)
                                                         (plist-get target :repo) (plist-get target :number))
                                nil))))

(defvar-local mr-x/pr--diff-context nil
  "PR identity and range for a diff opened through the shared workflow.")

(defun mr-x/pr-context (&optional require-pr)
  "Resolve the current repository and, when available, pull request.
REQUIRE-PR means to reject contexts without a specific PR."
  (let* ((fj (and (bound-and-true-p forgejo-repo--host)
                  (or (derived-mode-p 'forgejo-pull-list-mode 'forgejo-pull-view-mode)
                      (and (derived-mode-p 'diff-mode)
                           (bound-and-true-p forgejo-diff--pr-number)))))
         (remembered (and (derived-mode-p 'magit-diff-mode)
                          mr-x/pr--diff-context
                          (equal magit-buffer-diff-range
                                 (plist-get mr-x/pr--diff-context :range))
                          mr-x/pr--diff-context))
         ;; A number mentioned in discussion/diff text is not an action target.
         (pr (unless (or fj remembered)
               (cond ((derived-mode-p 'forge-pullreq-mode) forge-buffer-topic)
                     ((derived-mode-p 'forge-topics-mode 'magit-status-mode)
                      (magit-section-value-if 'pullreq)))))
         (repo (unless (or fj remembered)
                 (if (forge-pullreq-p pr)
                     (forge-get-repository pr)
                   (forge-get-repository :stub? nil 'notatpt))))
         (context
          (cond
           (remembered remembered)
           (fj
            (list :backend 'forgejo :host forgejo-repo--host
                  :owner forgejo-repo--owner :name forgejo-repo--name
                  :number (cond
                           ((derived-mode-p 'forgejo-pull-list-mode) (tabulated-list-get-id))
                           ((derived-mode-p 'forgejo-pull-view-mode) (alist-get 'number forgejo-view--data))
                           (t forgejo-diff--pr-number))))
           ((and repo (forge-github-repository-p repo))
            (list :backend 'github :repository repo :pullreq pr
                    :host (concat "https://" (oref repo githost))
                    :owner (oref repo owner) :name (oref repo name)
                    :number (and pr (oref pr number))))
           ((and repo (forge-forgejo-repository-p repo))
            (list :backend 'forgejo :host (forgejo--host-url-for-hostname (oref repo forge))
                  :owner (oref repo owner) :name (oref repo name))))))
    (unless context (user-error "Open a repository hosted on GitHub or configured Forgejo"))
    (when (and require-pr (not (integerp (plist-get context :number))))
      (user-error "Select a PR in the list or open its detail buffer first"))
    (plist-put context :directory default-directory)))

(defun mr-x/pr-list ()
  "Open this repository's pull requests using its provider."
  (interactive)
  (let* ((c (mr-x/pr-context))
         (repo (plist-get c :repository)))
    (pcase (plist-get c :backend)
      ('github
       (if (eq (oref repo condition) :tracked)
           (progn (forge-topics-setup-buffer repo nil :type 'pullreq)
                  (forge--pull repo))
         (forge-add-repository)))
      ('forgejo
       (let ((forgejo-repo--host (plist-get c :host)))
         (forgejo-pull-list (plist-get c :owner) (plist-get c :name))
         ;; The list's own sync only asks for open PRs changed since the last
         ;; one, so a PR merged meanwhile never comes back and stays listed.
         ;; The forced refresh is the sync that closes what the server dropped.
         (forgejo-pull-refresh))))))

(defun mr-x/forgejo-close-missing-when-none-open
    (orig host owner repo numbers &optional is-pull)
  "Call ORIG, treating an empty NUMBERS as \"nothing is open\".
Upstream skips the update entirely when NUMBERS is nil, so once a
repository's last open PR is merged the cache keeps it open forever.
Both callers pass NUMBERS only from a complete, open-only sync; a failed
or partial fetch never reaches this function."
  (if numbers
      (funcall orig host owner repo numbers is-pull)
    (forgejo-db--execute
     (format "UPDATE issues SET state = 'closed'
              WHERE host = ? AND owner = ? AND repo = ?
              AND state = 'open' %s"
             (if is-pull "AND is_pull = 1" "AND is_pull = 0"))
     (list host (downcase owner) (downcase repo)))))

(advice-add 'forgejo-db-close-missing :around
            #'mr-x/forgejo-close-missing-when-none-open)

(defun mr-x/pr--visit (context)
  "Visit the PR described by CONTEXT."
  (let ((default-directory (plist-get context :directory)))
    (pcase (plist-get context :backend)
      ('github (forge-visit-topic (plist-get context :pullreq)))
      ('forgejo
       (let ((forgejo-repo--host (plist-get context :host)))
         (forgejo-pull-view (plist-get context :owner) (plist-get context :name)
                           (plist-get context :number))
         (unless (and (equal forgejo-repo--host (plist-get context :host))
                      (equal forgejo-repo--owner (plist-get context :owner))
                      (equal forgejo-repo--name (plist-get context :name))
                      (equal (alist-get 'number forgejo-view--data) (plist-get context :number)))
           (user-error "PR details are loading; run the action again when they appear")))))))

(defun mr-x/pr-view ()
  "Open the selected PR's description and discussion."
  (interactive)
  (mr-x/pr--visit (mr-x/pr-context t)))

(defun mr-x/pr-diff ()
  "Open the full diff of the PR at point or being visited."
  (interactive)
  (let ((c (mr-x/pr-context t)))
    (pcase (plist-get c :backend)
      ('github
       (let ((range (forge--pullreq-range (plist-get c :pullreq) t)))
         (unless range (user-error "PR commits are not available yet; refresh the PR list first"))
         (with-current-buffer (magit-diff-range range)
           (setq-local mr-x/pr--diff-context (plist-put c :range range)))))
      ('forgejo (mr-x/pr--visit c) (forgejo-pull-view-diff)))))

(defun mr-x/pr-refresh ()
  "Fetch current PR data, or fully refresh the current list.
From a diff, return to the PR detail so the diff can be reopened afterward."
  (interactive)
  (let ((c (mr-x/pr-context)))
    (pcase (plist-get c :backend)
      ('github
       (when (and (derived-mode-p 'magit-diff-mode) (plist-get c :number))
         (mr-x/pr--visit c))
       (forge--pull (plist-get c :repository)))
      ('forgejo
       (if (derived-mode-p 'forgejo-pull-list-mode)
           (forgejo-pull-refresh)
         (if (plist-get c :number)
             (progn (mr-x/pr--visit c) (forgejo-view-refresh))
           (mr-x/pr-list)))))))

(defun mr-x/pr-comment ()
  "Compose a general comment on the selected PR."
  (interactive)
  (let ((c (mr-x/pr-context t)))
    (mr-x/pr--visit c)
    (pcase (plist-get c :backend)
      ('github (forge-create-post))
      ('forgejo (forgejo-view-comment)))))

(defun mr-x/pr--review (event)
  "Compose an approval or request-changes review, selected by EVENT."
  (let ((c (mr-x/pr-context t)))
    (mr-x/pr--visit c)
    (pcase (plist-get c :backend)
      ('github
       (if (eq event 'approve) (forge-approve-pullreq) (forge-request-changes)))
      ('forgejo
       (let* ((refresh (forgejo--post-action-callback))
              (body (forgejo-utils-read-body)))
         ;; Upstream's general review command posts even when compose returns
         ;; nil on cancel.  Only a submitted string may reach the HTTP layer.
         (when (stringp body)
           (forgejo-review--post-review
            (plist-get c :host) (plist-get c :owner) (plist-get c :name)
            (plist-get c :number)
            `((event . ,(if (eq event 'approve) "APPROVED" "REQUEST_CHANGES"))
              (body . ,body))
            (lambda (_data _headers)
              (funcall refresh)
              (message "PR review submitted")))))))))

(defun mr-x/pr-approve ()
  "Compose an approval for the selected PR."
  (interactive)
  (mr-x/pr--review 'approve))

(defun mr-x/pr-request-changes ()
  "Compose a request-changes review for the selected PR."
  (interactive)
  (mr-x/pr--review 'request-changes))

(defun mr-x/pr--github-merge (context)
  "Merge CONTEXT on GitHub with a confirmed head and no local checkout changes."
  (let* ((repo (plist-get context :repository))
         (number (plist-get context :number))
         (path (format "/repos/:owner/:repo/pulls/%d" number))
         (origin (current-buffer))
         (valid (lambda ()
                  (and (buffer-live-p origin)
                       (with-current-buffer origin
                         (let ((current (ignore-errors (mr-x/pr-context t))))
                           (cl-every (lambda (key) (equal (plist-get context key)
                                                         (plist-get current key)))
                                     '(:backend :host :owner :name :number))))))))
    (forge--rest repo "GET" "/repos/:owner/:repo" nil
      :callback
      (lambda (settings &rest _)
        (when (funcall valid)
          (forge--rest repo "GET" path nil
            :callback
            (lambda (data &rest _)
              (when (funcall valid)
                (unless (and (equal (alist-get 'state data) "open")
                             (not (eq (alist-get 'merged data) t))
                             (not (eq (alist-get 'draft data) t))
                             (eq (alist-get 'mergeable data) t))
                  (user-error "GitHub does not currently report this PR ready to merge"))
                (let* ((head (alist-get 'sha (alist-get 'head data)))
                       (base (alist-get 'ref (alist-get 'base data)))
                       (methods (cl-loop for (flag . method) in
                                         '((allow_merge_commit . "merge")
                                           (allow_squash_merge . "squash")
                                           (allow_rebase_merge . "rebase"))
                                         when (eq (alist-get flag settings) t) collect method)))
                  (unless (and (stringp head)
                               (string-match-p "\\`[[:xdigit:]]\\{40,64\\}\\'" head)
                               (stringp base))
                    (user-error "GitHub returned incomplete PR commit information"))
                  (unless methods (user-error "No merge method is enabled for this repository"))
                  (let ((method (completing-read "Merge method: " methods nil t nil nil (car methods))))
                    (when (and (yes-or-no-p
                                (format "Merge %s/%s#%d (%s) into %s on %s using %s, head %s? "
                                        (plist-get context :owner) (plist-get context :name)
                                        number (alist-get 'title data) base (plist-get context :host)
                                        method (substring head 0 12)))
                               (funcall valid))
                      (forge--rest repo "PUT" (concat path "/merge")
                        `((sha . ,head) (merge_method . ,method))
                        :callback
                        (lambda (result &rest _)
                          (unless (eq (alist-get 'merged result) t)
                            (user-error "GitHub did not merge the PR: %s" (alist-get 'message result)))
                          (let (refresh-error)
                            (condition-case err (forge--pull repo)
                              (error (setq refresh-error (error-message-string err))))
                            (message "Merged PR #%d into %s%s" number base
                                     (if refresh-error (concat "; refresh failed: " refresh-error) ""))))))))))))))))

(defun mr-x/pr-merge ()
  "Merge the selected PR on its provider, with explicit confirmation."
  (interactive)
  (let ((c (mr-x/pr-context t)))
    (pcase (plist-get c :backend)
      ('github (mr-x/pr--github-merge c))
      ('forgejo (mr-x/pr--visit c) (mr-x/forgejo-merge-pr)))))

(defun mr-x/pr--github-review-context ()
  "The GitHub PR context here, or nil."
  (ignore-errors
    (let ((c (mr-x/pr-context t)))
      (and (eq (plist-get c :backend) 'github) (plist-get c :pullreq) c))))

(defun mr-x/pr-review-available-p ()
  "Whether this buffer shows a PR the review session can open."
  (or (mr-x/forgejo-ediff-available-p)
      (and (mr-x/pr--github-review-context) t)))

(defun mr-x/pr--github-review-source (c)
  "A review source for GitHub PR context C, read from its local clone."
  (let* ((repo (plist-get c :repository))
         (pr (plist-get c :pullreq))
         (dir (or (forge-get-worktree repo)
                  (user-error "Review needs a local clone of %s/%s"
                              (plist-get c :owner) (plist-get c :name)))))
    (review-source-github-pr dir (plist-get c :owner) (plist-get c :name) (plist-get c :number)
                             :title (oref pr title)
                             :base-ref (oref pr base-ref) :head-ref (oref pr head-ref)
                             :base-rev (oref pr base-rev) :head-rev (oref pr head-rev))))

(defun mr-x/pr-review-session ()
  "Review this PR one file at a time: an open Forgejo PR diff, or a GitHub PR."
  (interactive)
  (let ((source
         (cond
          ((mr-x/forgejo-ediff-available-p)
           (review-source-forgejo-pr forgejo-repo--host forgejo-repo--owner forgejo-repo--name
                                     forgejo-diff--pr-number (review-source-forgejo-patch-files)))
          ((mr-x/pr--github-review-context)
           (mr-x/pr--github-review-source (mr-x/pr--github-review-context)))
          (t (user-error "Open a Forgejo PR diff (SPC , d) or a GitHub PR first")))))
    (when-let ((session (review-session-start source)))
      (review-panel-open session))))

(defun mr-x/pr--review-forgejo (host owner repo number)
  "Fetch Forgejo PR NUMBER of OWNER/REPO on HOST, then review it.
Needs no PR buffer: this is the route from a PR list row or details."
  (let ((url-request-method "GET")
        (url-request-extra-headers
         `(("Authorization" . ,(encode-coding-string
                                (concat "token " (forgejo-token host)) 'ascii)))))
    ;; Same request and diff buffer as `forgejo-pull-view-diff', so the
    ;; session sees exactly what the raw PR diff would have shown.
    (url-retrieve
     (format "%s/api/v1/repos/%s/%s/pulls/%d.diff" host owner repo number)
     (lambda (status)
       (let ((response (current-buffer)))
         (unwind-protect
             (condition-case err
                 (if-let ((failure (plist-get status :error)))
                     (message "PR review: fetching %s/%s#%d failed: %S" owner repo number failure)
                   (goto-char (point-min))
                   (re-search-forward "\r?\n\r?\n" nil t)
                   (let ((text (buffer-substring-no-properties (point) (point-max)))
                         (name (format "*forgejo-diff: %s/%s#%d*" owner repo number)))
                     ;; It also switches the selected window to the diff;
                     ;; only the review frames should appear.
                     (save-window-excursion
                       (forgejo-view--show-diff-buffer name text host owner repo number))
                     (with-current-buffer name (mr-x/pr-review-session))))
               (error (message "PR review: %s" (error-message-string err))))
           (when (buffer-live-p response) (kill-buffer response)))))
     nil t)))

(defun mr-x/pr-review-open (url)
  "Start a review session for the Forgejo PR at URL, skipping the PR views.
URL is the PR's web address: https://HOST/OWNER/REPO/pulls/NUMBER."
  (interactive "sForgejo PR URL: ")
  (unless (string-match "\\`\\(https?://[^/]+\\)/\\([^/]+\\)/\\([^/]+\\)/pulls/\\([0-9]+\\)/?\\'"
                        url)
    (user-error "Not a Forgejo PR URL: %s" url))
  (mr-x/pr--review-forgejo (match-string 1 url) (match-string 2 url) (match-string 3 url)
                           (string-to-number (match-string 4 url))))

(defvar mr-x/review-git-range-history nil
  "History of review presets and manually entered Git ranges.")

(defun mr-x/review--read-git-range ()
  "Pick a common comparison or enter any Git revision or range.
Return an empty string for the working tree, which remains the default."
  (let* ((presets '(("Uncommitted changes" . "")
                    ("Staged changes" . "--staged")
                    ("Latest commit" . "HEAD")
                    ("Last 3 commits" . "HEAD~3..HEAD")
                    ("Branch changes since main" . "main...HEAD")))
         (annotate (lambda (candidate)
                     (when-let ((range (cdr (assoc candidate presets))))
                       (concat "  " (propertize
                                     (if (string-empty-p range) "working tree vs HEAD" range)
                                     'face 'completions-annotations)))))
         (choice
          (string-trim
           (completing-read
            "Review (pick or type a Git range): "
            (lambda (string predicate action)
              (if (eq action 'metadata)
                  `(metadata (category . review-git-range)
                             (annotation-function . ,annotate)
                             (display-sort-function . identity)
                             (cycle-sort-function . identity))
                (complete-with-action action presets string predicate)))
            nil nil nil 'mr-x/review-git-range-history (caar presets)))))
    (or (cdr (assoc choice presets)) choice)))

(defun mr-x/review-git-range (&optional range)
  "Review a git RANGE of the current repository.
When RANGE is omitted, pick a preset or type any revision or range.
Empty input means the working tree against HEAD; \"--staged\" the index."
  (interactive)
  (let* ((root (or (magit-toplevel) (user-error "Not inside a git repository")))
         (range (or range (mr-x/review--read-git-range)))
         (source (review-source-git-range root (unless (string-empty-p range) range))))
    (when-let ((session (review-session-start source)))
      (review-panel-open session))))

(defun mr-x/review ()
  "Review the PR in this buffer, or else pick a git range to review.
A PR list row, PR details and a raw PR diff all count as the PR."
  (interactive)
  (let ((c (ignore-errors (mr-x/pr-context))))
    (if (not (integerp (plist-get c :number)))
        (mr-x/review-git-range)
      (if (or (mr-x/pr-review-available-p) (not (eq (plist-get c :backend) 'forgejo)))
          (mr-x/pr-review-session)
        (mr-x/pr--review-forgejo (plist-get c :host) (plist-get c :owner)
                                 (plist-get c :name) (plist-get c :number))))))

(defhydra hydra-pr (:hint nil :exit t)
  "
 PR
 Review              Read                     Merge
 _r_: review          _v_: details   _l_: list   _m_: merge (confirm)
 _c_: comment         _d_: raw diff  _g_: refresh
 _a_: approve         _e_: Ediff this file
 _x_: request changes                          _q_: quit"
  ("r" mr-x/review)
  ("c" mr-x/pr-comment)
  ("a" mr-x/pr-approve)
  ("x" mr-x/pr-request-changes)
  ("v" mr-x/pr-view)
  ("d" mr-x/pr-diff)
  ("e" mr-x/forgejo-diff-ediff)
  ("l" mr-x/pr-list)
  ("g" mr-x/pr-refresh)
  ("m" mr-x/pr-merge)
  ("q" nil))

(provide 'pr-workflow)
;;; pr-workflow.el ends here
