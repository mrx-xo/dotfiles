;;; pr-workflow.el --- Shared GitHub and Forgejo PR actions -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep provider UIs and credentials, while sharing entry points and commands.
;; A Magit diff remembers its PR only while its original range is displayed.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'forge)
(require 'forgejo-vc)
(require 'forgejo-review)
(require 'forgejo-merge)
(require 'forgejo-review-ediff)

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
         (forgejo-pull-list (plist-get c :owner) (plist-get c :name)))))))

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

(transient-define-prefix mr-x/pr-menu ()
  "PR actions for the current GitHub or Forgejo repository."
  [["Read"
    ("r" "PR list" mr-x/pr-list)
    ("v" "PR details" mr-x/pr-view)
    ("d" "Full diff" mr-x/pr-diff)
    ("e" "Compare this file (Ediff)" mr-x/forgejo-diff-ediff
     :if mr-x/forgejo-ediff-available-p)
    ("g" "Refresh" mr-x/pr-refresh)]
   ["Review"
    ("c" "Comment" mr-x/pr-comment)
    ("a" "Approve" mr-x/pr-approve)
    ("x" "Request changes" mr-x/pr-request-changes)]
   ["Merge"
    ("m" "Merge PR (confirm)" mr-x/pr-merge)]])

(provide 'pr-workflow)
;;; pr-workflow.el ends here
