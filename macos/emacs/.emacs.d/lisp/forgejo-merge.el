;;; forgejo-merge.el --- Merge a PR through Forgejo -*- lexical-binding: t; -*-

;;; Commentary:
;; A server-side merge action for the PR detail buffer.  Fetch current
;; metadata, choose an allowed method, and confirm the exact head to merge.
;; Forgejo enforces branch protection; never force, queue, or delete branches.

;;; Code:
(require 'forgejo-pull)
(require 'json)

;;;###autoload
(defun mr-x/forgejo-merge-pr ()
  "Merge the PR in the current detail buffer after explicit confirmation.
The request pins the confirmed head commit and respects server checks.
No local checkout, push, or branch deletion is performed."
  (interactive)
  (unless (and (derived-mode-p 'forgejo-pull-view-mode)
               forgejo-repo--host forgejo-repo--owner forgejo-repo--name
               (integerp (alist-get 'number forgejo-view--data)))
    (user-error "Open a PR's detail buffer before merging"))
  (let* ((origin (current-buffer))
         (host forgejo-repo--host)
         (owner forgejo-repo--owner)
         (repo forgejo-repo--name)
         (number (alist-get 'number forgejo-view--data))
         (endpoint (format "repos/%s/%s/pulls/%d" owner repo number))
         (valid (lambda ()
                  (and (buffer-live-p origin)
                       (with-current-buffer origin
                         (and (derived-mode-p 'forgejo-pull-view-mode)
                              (equal forgejo-repo--host host)
                              (equal forgejo-repo--owner owner)
                              (equal forgejo-repo--name repo)
                              (equal number (alist-get 'number forgejo-view--data)))))))
         (refresh (forgejo--post-action-callback))
         (on-error (lambda (err)
                     (user-error "Forgejo merge failed (%s): %s"
                                 (or (plist-get err :status) "network")
                                 (plist-get err :message)))))
    (forgejo-api-get
     host endpoint nil
     (lambda (data _headers)
       (when (funcall valid)
         (unless (and (equal (alist-get 'state data) "open")
                      (not (eq (alist-get 'merged data) t)))
           (user-error "This PR is already merged or closed"))
         (when (or (eq (alist-get 'draft data) t)
                   (eq (alist-get 'work_in_progress data) t))
           (user-error "Mark this PR ready for review before merging"))
         (unless (eq (alist-get 'mergeable data) t)
           (user-error "Forgejo does not currently report this PR as mergeable"))
         (let* ((head (alist-get 'sha (alist-get 'head data)))
                (base (alist-get 'base data))
                (settings (alist-get 'repo base))
                (methods
                 (cl-loop for (flag . method) in
                          '((allow_merge_commits . "merge")
                            (allow_squash_merge . "squash")
                            (allow_rebase . "rebase")
                            (allow_rebase_explicit . "rebase-merge")
                            (allow_fast_forward_only_merge . "fast-forward-only"))
                          when (eq (alist-get flag settings) t) collect method))
                (preferred (alist-get 'default_merge_style settings)))
           (unless (and (stringp head)
                        (string-match-p "\\`[[:xdigit:]]\\{40,64\\}\\'" head)
                        (stringp (alist-get 'ref base)))
             (user-error "Forgejo returned incomplete PR commit information"))
           (unless methods (user-error "No merge method is enabled for this repository"))
           (let ((method (completing-read "Merge method: " methods nil t nil nil
                                          (if (member preferred methods) preferred (car methods)))))
             (when (and (yes-or-no-p
                         (format "Merge %s/%s#%d (%s) into %s on %s using %s, head %s? "
                                 owner repo number (alist-get 'title data)
                                 (alist-get 'ref base) host method (substring head 0 12)))
                        (funcall valid))
               (forgejo-api-post
                host (concat endpoint "/merge") nil
                `((Do . ,method) (head_commit_id . ,head)
                  (force_merge . ,json-false)
                  (delete_branch_after_merge . ,json-false)
                  (merge_when_checks_succeed . ,json-false))
                (lambda (_result _response-headers)
                  (let (refresh-errors)
                    (when (funcall valid)
                      (condition-case err (funcall refresh)
                        (error (push (error-message-string err) refresh-errors))))
                    (dolist (buffer (buffer-list))
                      (with-current-buffer buffer
                        (when (and (derived-mode-p 'forgejo-pull-list-mode)
                                   (equal forgejo-repo--host host)
                                   (equal forgejo-repo--owner owner)
                                   (equal forgejo-repo--name repo))
                          (condition-case err (forgejo-pull-refresh)
                            (error (push (error-message-string err) refresh-errors))))))
                    (message "Merged %s/%s#%d into %s using %s%s"
                             owner repo number (alist-get 'ref base) method
                             (if refresh-errors
                                 (concat "; refresh failed: " (string-join refresh-errors "; "))
                               ""))))
                :error-callback on-error))))))
     :error-callback on-error)))

(provide 'forgejo-merge)
;;; forgejo-merge.el ends here
