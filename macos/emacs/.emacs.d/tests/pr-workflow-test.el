;;; pr-workflow-test.el --- Shared PR workflow checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'forge)
(require 'forgejo-pull)
(require 'pr-workflow nil t)

(defmacro pr-test--github (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (setq default-directory temporary-file-directory
           major-mode 'forge-pullreq-mode)
     (let* ((repo (forge-github-repository :id "repo" :forge "github.com"
                                         :githost "github.com" :apihost "api.github.com"
                                         :owner "team" :name "project"))
            (pr (forge-pullreq :id "pull" :repository "repo" :number 11
                              :title "Fix navigation" :base-ref "main" :state 'open))
            (forge-buffer-repository "repo")
            (forge-buffer-topic pr)
            (real-get-repository (symbol-function 'forge-get-repository)))
       (oset repo condition :tracked)
       ;; Isolate the DB lookup; keep Forge's PR and repository objects real.
       (cl-letf (((symbol-function 'forge-get-repository)
                  (lambda (object &rest args)
                    (if (or (eq object pr)
                            (and (eq object :id) (equal (car args) "repo")))
                        repo
                      (apply real-get-repository object args)))))
         ,@body))))

(defmacro pr-test--forgejo (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (setq default-directory temporary-file-directory
           major-mode 'forgejo-pull-view-mode)
     (setq-local forgejo-repo--host "https://forge.example")
     (setq-local forgejo-repo--owner "team")
     (setq-local forgejo-repo--name "project")
     (setq-local forgejo-view--data '((number . 11)))
     ,@body))

(ert-deftest pr-context-uses-visited-github-pr-outside-checkout ()
  (pr-test--github
    (let ((c (mr-x/pr-context t)))
      (should (eq (plist-get c :backend) 'github))
      (should (eq (plist-get c :repository) repo))
      (should (= (plist-get c :number) 11)))))

(ert-deftest pr-context-recognizes-forgejo-detail-list-and-diff ()
  (pr-test--forgejo
    (should (eq (plist-get (mr-x/pr-context t) :backend) 'forgejo))
    (setq major-mode 'forgejo-pull-list-mode)
    (setq-local tabulated-list-format [("PR" 8 t)])
    (setq-local tabulated-list-entries '((12 ["12"])))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (= (plist-get (mr-x/pr-context t) :number) 12))
    (setq major-mode 'diff-mode)
    (setq-local forgejo-diff--pr-number 13)
    (should (= (plist-get (mr-x/pr-context t) :number) 13))))

(ert-deftest pr-context-does-not-reuse-identity-for-unrelated-magit-diff ()
  (pr-test--github
    (let ((context (mr-x/pr-context t)))
      (setq major-mode 'magit-diff-mode forge-buffer-topic nil)
      (setq-local magit-buffer-diff-range "origin/main...refs/pullreqs/11")
      (setq-local mr-x/pr--diff-context
                  (plist-put context :range magit-buffer-diff-range))
      (should (= (plist-get (mr-x/pr-context t) :number) 11))
      (setq magit-buffer-diff-range "HEAD~1..HEAD")
      (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) pr)))
        (should-error (mr-x/pr-context t) :type 'user-error)))))

(ert-deftest pr-context-detail-actions-ignore-another-pr-mentioned-at-point ()
  (pr-test--github
    (let ((other (forge-pullreq :id "other" :number 99 :repository "repo")))
      (cl-letf (((symbol-function 'forge-current-pullreq) (lambda (&rest _) other)))
        (should (= (plist-get (mr-x/pr-context t) :number) 11))))))

(ert-deftest pr-forgejo-loading-detail-does-not-silently-drop-actions ()
  (pr-test--forgejo
    (cl-letf (((symbol-function 'forgejo-pull-view)
               (lambda (&rest _) (setq-local forgejo-view--data nil)))
              ((symbol-function 'forgejo-pull-view-diff)
               (lambda () (ert-fail "Diff ran before detail was ready"))))
      (should-error (mr-x/pr-diff) :type 'user-error))))

(ert-deftest pr-forgejo-local-repository-keeps-configured-web-port ()
  (with-temp-buffer
    (let ((repo (forge-forgejo-repository :id "fj" :forge "forge.example"
                                         :githost "forge.example" :apihost "forge.example/api/v1"
                                         :owner "team" :name "project"))
          (forgejo-hosts '(("http://forge.example:3000"))))
      (cl-letf (((symbol-function 'forge-get-repository) (lambda (&rest _) repo)))
        (should (equal (plist-get (mr-x/pr-context) :host) "http://forge.example:3000"))))))

(ert-deftest pr-list-routes-to-each-provider ()
  (pr-test--github
    (let (listed pulled)
      (cl-letf (((symbol-function 'forge-topics-setup-buffer)
                 (lambda (r &rest _) (setq listed r)))
                ((symbol-function 'forge--pull) (lambda (r &rest _) (setq pulled r))))
        (mr-x/pr-list)
        (should (eq listed repo))
        (should (eq pulled repo)))))
  (pr-test--forgejo
    (let (listed)
      (cl-letf (((symbol-function 'forgejo-pull-list)
                 (lambda (owner name) (setq listed (list forgejo-repo--host owner name)))))
        (mr-x/pr-list)
        (should (equal listed '("https://forge.example" "team" "project")))))))

(ert-deftest pr-forgejo-approval-cancel-does-not-submit-empty-approval ()
  (pr-test--forgejo
    (cl-letf (((symbol-function 'mr-x/pr--visit) #'ignore)
              ((symbol-function 'forgejo-utils-read-body) (lambda (&rest _) nil))
              ((symbol-function 'forgejo-api-post)
               (lambda (&rest _) (ert-fail "Cancelled approval reached HTTP"))))
      (mr-x/pr-approve))))

(ert-deftest pr-forgejo-review-type-and-target-survive-composition ()
  (dolist (case '((mr-x/pr-approve . "APPROVED")
                  (mr-x/pr-request-changes . "REQUEST_CHANGES")))
    (pr-test--forgejo
      (let (request)
        (cl-letf (((symbol-function 'mr-x/pr--visit) #'ignore)
                  ((symbol-function 'forgejo-utils-read-body)
                   (lambda (&rest _)
                     (setq-local forgejo-repo--owner "different-team")
                     "Review text"))
                  ((symbol-function 'forgejo-api-post)
                   (lambda (host endpoint _params body &rest _)
                     (setq request (list host endpoint body)))))
          (funcall (car case))
          (should (equal (cadr request) "repos/team/project/pulls/11/reviews"))
          (should (equal (alist-get 'event (nth 2 request)) (cdr case))))))))

(defmacro pr-test--github-api (&rest body)
  (declare (indent 0))
  `(let ((accept t) sent prompt methods pulled
         (response '((merged . t)))
         (head (make-string 40 ?a)))
     (cl-letf (((symbol-function 'forge--rest)
                (lambda (_repo method endpoint &optional params &rest args)
                  (let ((callback (plist-get args :callback)))
                    (pcase (list method endpoint)
                      (`("GET" "/repos/:owner/:repo")
                       (funcall callback '((allow_merge_commit . t) (allow_squash_merge . :false)) nil))
                      (`("GET" "/repos/:owner/:repo/pulls/11")
                       (funcall callback `((state . "open") (mergeable . t) (title . "Fix navigation")
                                           (head . ((sha . ,head))) (base . ((ref . "main")))) nil))
                      (`("PUT" "/repos/:owner/:repo/pulls/11/merge")
                       (setq sent params) (funcall callback response nil))
                      (_ (ert-fail (format "Unexpected API request %s %s" method endpoint)))))))
               ((symbol-function 'completing-read)
                (lambda (_prompt choices &rest _) (setq methods choices) (car choices)))
               ((symbol-function 'yes-or-no-p) (lambda (text) (setq prompt text) accept))
               ((symbol-function 'forge--pull) (lambda (&rest _) (setq pulled t)))
               ((symbol-function 'magit-call-git)
                (lambda (&rest _) (ert-fail "Merge changed the checkout"))))
       ,@body)))

(ert-deftest pr-github-merge-confirms-and-pins-head-without-local-checkout ()
  (pr-test--github
    (pr-test--github-api
      (mr-x/pr-merge)
      (should (equal sent `((sha . ,head) (merge_method . "merge"))))
      (should (equal methods '("merge")))
      (should (string-match-p "team/project#11" prompt))
      (should (string-match-p "main" prompt))
      (should pulled))))

(ert-deftest pr-github-merge-cancel-and-server-refusal-never-report-success ()
  (pr-test--github
    (pr-test--github-api
      (setq accept nil)
      (mr-x/pr-merge)
      (should-not sent)
      (should-not pulled)))
  (pr-test--github
    (pr-test--github-api
      (setq response '((merged . :false) (message . "Checks pending")))
      (should-error (mr-x/pr-merge) :type 'user-error)
      (should-not pulled))))

(provide 'pr-workflow-test)
