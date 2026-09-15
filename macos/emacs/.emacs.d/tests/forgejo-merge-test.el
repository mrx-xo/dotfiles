;;; forgejo-merge-test.el --- Merge command checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'forgejo-pull)
(require 'forgejo-merge nil t)

(defmacro forgejo-merge-test--fixture (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (setq major-mode 'forgejo-pull-view-mode)
     (setq-local forgejo-repo--host "https://forge.example")
     (setq-local forgejo-repo--owner "team")
     (setq-local forgejo-repo--name "project")
     (setq-local forgejo-view--data '((number . 11)))
     (let* ((sha (make-string 40 ?a))
            (pr `((number . 11) (title . "Fix navigation") (state . "open")
                  (merged . :false) (mergeable . t)
                  (head . ((sha . ,sha)))
                  (base . ((ref . "main")
                           (repo . ((allow_merge_commits . t)
                                    (allow_squash_merge . :false)
                                    (default_merge_style . "merge")))))))
            (accept t) prompt choices post refreshed failure)
       (cl-letf (((symbol-function 'forgejo-api-get)
                  (lambda (host endpoint _params callback &rest _)
                    (should (equal host "https://forge.example"))
                    (should (equal endpoint "repos/team/project/pulls/11"))
                    (funcall callback pr nil)))
                 ((symbol-function 'completing-read)
                  (lambda (_prompt collection &rest _) (setq choices collection) (car collection)))
                 ((symbol-function 'yes-or-no-p)
                  (lambda (text) (setq prompt text) accept))
                 ((symbol-function 'forgejo-api-post)
                  (lambda (host endpoint _params payload callback &rest args)
                    (setq post (list host endpoint payload))
                    (if failure
                        (funcall (plist-get args :error-callback) failure)
                      (funcall callback nil nil))))
                 ((symbol-function 'forgejo--post-action-callback)
                  (lambda () (lambda () (setq refreshed t)))))
         ,@body))))

(ert-deftest forgejo-merge-submits-confirmed-head-without-force-or-deletion ()
  (forgejo-merge-test--fixture
    (mr-x/forgejo-merge-pr)
    (should (equal (car post) "https://forge.example"))
    (should (equal (cadr post) "repos/team/project/pulls/11/merge"))
    (let* ((json-object-type 'alist)
           (payload (json-read-from-string (json-encode (nth 2 post)))))
      (should (equal (alist-get 'Do payload) "merge"))
      (should (equal (alist-get 'head_commit_id payload) sha))
      (dolist (key '(force_merge delete_branch_after_merge merge_when_checks_succeed))
        (should (eq (alist-get key payload) json-false))))
    (should (equal choices '("merge")))
    (dolist (text '("team/project#11" "main" "aaaaaaaa" "Fix navigation"))
      (should (string-match-p text prompt)))
    (should refreshed)))

(ert-deftest forgejo-merge-cancel-never-posts ()
  (forgejo-merge-test--fixture
    (setq accept nil)
    (mr-x/forgejo-merge-pr)
    (should-not post)
    (should-not refreshed)))

(ert-deftest forgejo-merge-rejects-closed-conflicting-and-draft-prs ()
  (dolist (change '((state . "closed") (merged . t) (mergeable . :false) (draft . t)))
    (forgejo-merge-test--fixture
      (setf (alist-get (car change) pr) (cdr change))
      (should-error (mr-x/forgejo-merge-pr) :type 'user-error)
      (should-not post))))

(ert-deftest forgejo-merge-rejects-missing-head-and-disabled-methods ()
  (forgejo-merge-test--fixture
    (setf (alist-get 'head pr) nil)
    (should-error (mr-x/forgejo-merge-pr) :type 'user-error)
    (should-not post))
  (forgejo-merge-test--fixture
    (setf (alist-get 'repo (alist-get 'base pr)) '((allow_merge_commits . :false)))
    (should-error (mr-x/forgejo-merge-pr) :type 'user-error)
    (should-not post)))

(ert-deftest forgejo-merge-failed-server-check-does-not-report-success ()
  (forgejo-merge-test--fixture
    (setq failure '(:status 409 :message "Head changed"))
    (should-error (mr-x/forgejo-merge-pr) :type 'user-error)
    (should post)
    (should-not refreshed)))

(ert-deftest forgejo-merge-only-runs-from-pr-details ()
  (with-temp-buffer
    (should-error (mr-x/forgejo-merge-pr) :type 'user-error)))

(ert-deftest forgejo-merge-ignores-response-after-buffer-changes-repository ()
  (forgejo-merge-test--fixture
    (let (reply)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host _endpoint _params callback &rest _) (setq reply callback))))
        (mr-x/forgejo-merge-pr))
      (setq-local forgejo-repo--owner "different-team")
      (funcall reply pr nil)
      (should-not prompt)
      (should-not post))))

(ert-deftest forgejo-merge-success-survives-detail-refresh-failure ()
  (forgejo-merge-test--fixture
    (let (reports)
      (cl-letf (((symbol-function 'forgejo--post-action-callback)
                 (lambda () (lambda () (error "Refresh unavailable"))))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) reports))))
        (mr-x/forgejo-merge-pr)
        (should post)
        (should (seq-some (lambda (s) (string-match-p "Merged team/project#11" s)) reports))
        (should (seq-some (lambda (s) (string-match-p "[Rr]efresh" s)) reports))))))

(ert-deftest forgejo-merge-success-survives-list-refresh-failure ()
  (forgejo-merge-test--fixture
    (let ((list-buffer (generate-new-buffer " *merge-list-test*")))
      (unwind-protect
          (progn
            (with-current-buffer list-buffer
              (setq major-mode 'forgejo-pull-list-mode)
              (setq-local forgejo-repo--host "https://forge.example")
              (setq-local forgejo-repo--owner "team")
              (setq-local forgejo-repo--name "project"))
            (cl-letf (((symbol-function 'forgejo-pull-refresh)
                       (lambda () (error "List refresh unavailable"))))
              (mr-x/forgejo-merge-pr)
              (should post)
              (should refreshed)))
        (kill-buffer list-buffer)))))

(provide 'forgejo-merge-test)
