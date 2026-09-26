;;; forgejo-review-navigation-test.el --- PR source jumps -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'forgejo-pull)
(require 'forgejo-review-navigation nil t)

(defun forgejo-nav-test--git (directory &rest args)
  "Run Git ARGS in DIRECTORY and return its output."
  (let ((default-directory directory))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "Fixture Git failed: %s" (buffer-string)))
      (string-trim-right (buffer-string)))))

(defmacro forgejo-nav-test--fixture (&rest body)
  "Run BODY with a real repository, PR commit, and a separate worktree."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "forgejo-nav-" t))
          (root (file-name-as-directory (expand-file-name "repo" directory)))
          (worktree (expand-file-name "review tree" directory))
          (path "src/new file.py")
          (contents "def greet():\n    return \"hello\"\n")
          base head blob patch source-revision merge-base
          (original-buffers (buffer-list)))
     (unwind-protect
         (save-window-excursion
           (make-directory root)
           (forgejo-nav-test--git root "init" "-b" "main")
           (forgejo-nav-test--git root "config" "user.email" "test@example.invalid")
           (forgejo-nav-test--git root "config" "user.name" "Test")
           (forgejo-nav-test--git root "-c" "commit.gpgsign=false"
                                 "commit" "--allow-empty" "-m" "base")
           (setq base (forgejo-nav-test--git root "rev-parse" "HEAD"))
           (forgejo-nav-test--git root "checkout" "-b" "feature")
           (make-directory (expand-file-name "src" root))
           (write-region contents nil (expand-file-name path root) nil 'silent)
           (forgejo-nav-test--git root "add" ".")
           (forgejo-nav-test--git root "-c" "commit.gpgsign=false"
                                 "commit" "-m" "add source")
           (setq head (forgejo-nav-test--git root "rev-parse" "HEAD")
                 blob (forgejo-nav-test--git root "rev-parse" (concat "HEAD:" path))
                 patch (concat (forgejo-nav-test--git root "diff" base head) "\n"))
           (forgejo-nav-test--git root "checkout" "main")
           (forgejo-nav-test--git root "worktree" "add" worktree "feature")
           ,@body)
       (dolist (buffer (buffer-list))
         (unless (memq buffer original-buffers)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(defmacro forgejo-nav-test--api (&rest body)
  "Replace only remote HTTP reads with PR metadata and contents fixtures."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'forgejo-api-get)
              (lambda (host endpoint &optional params callback &rest _args)
                (should (equal host "https://forge.example"))
                (cond
                 ((equal endpoint "repos/team/project/pulls/10")
                  (funcall callback
                           `((head . ((sha . ,head))) (base . ((sha . ,base)))
                             (merge_base . ,merge-base)) nil))
                 ((equal endpoint "repos/team/project/contents/src/new%20file.py")
                  (should (equal params `(("ref" . ,(or source-revision head)))))
                  (funcall callback
                           `((type . "file") (sha . ,blob) (encoding . "base64")
                             (content . ,(base64-encode-string contents t))) nil))
                 (t (error "Unexpected API request: %s" endpoint))))))
     ,@body))

(defun forgejo-nav-test--open-diff (root patch &optional needle)
  "Open PATCH from ROOT, leaving point on NEEDLE or its new-file header."
  (switch-to-buffer (generate-new-buffer " *forgejo-navigation-test*"))
  (setq default-directory root)
  (insert patch)
  (diff-mode)
  (setq-local forgejo-repo--host "https://forge.example")
  (setq-local forgejo-repo--owner "team")
  (setq-local forgejo-repo--name "project")
  (setq-local forgejo-diff--pr-number 10)
  (goto-char (point-min))
  (search-forward (or needle "+++ b/src/new file.py")))

(ert-deftest forgejo-nav-header-finds-pr-worktree-without-changing-main ()
  "RET from the main checkout must visit the new file in the PR worktree."
  (forgejo-nav-test--fixture
    (forgejo-nav-test--api
      (forgejo-nav-test--open-diff root patch)
      (diff-goto-source)
      (should (equal (file-truename buffer-file-name)
                     (file-truename (expand-file-name path worktree))))
      (should (= (line-number-at-pos) 1))
      (should (equal (forgejo-nav-test--git root "branch" "--show-current") "main"))
      (should-not (file-exists-p (expand-file-name path root))))))

(ert-deftest forgejo-nav-added-line-visits-corresponding-source-line ()
  "Jumping from an added line must preserve its new-file line number."
  (forgejo-nav-test--fixture
    (forgejo-nav-test--api
      (forgejo-nav-test--open-diff root patch "+    return")
      (diff-goto-source)
      (should (equal (file-truename buffer-file-name)
                     (file-truename (expand-file-name path worktree))))
      (should (= (line-number-at-pos) 2)))))

(ert-deftest forgejo-nav-no-checkout-opens-read-only-pr-source ()
  "Without a matching worktree, RET must show versioned API contents."
  (forgejo-nav-test--fixture
    (forgejo-nav-test--git root "worktree" "remove" worktree)
    (forgejo-nav-test--api
      (forgejo-nav-test--open-diff root patch "+    return")
      (diff-goto-source)
      (should (equal (buffer-string) contents))
      (should buffer-read-only)
      (should-not buffer-file-name)
      (should (memq major-mode '(python-mode python-ts-mode)))
      (should (= (line-number-at-pos) 2)))))

(ert-deftest forgejo-nav-dirty-worktree-opens-snapshot-and-preserves-edits ()
  "Uncommitted file changes must not be mistaken for the displayed PR."
  (forgejo-nav-test--fixture
    (let ((file (expand-file-name path worktree)))
      (write-region "local changes\n" nil file nil 'silent)
      (forgejo-nav-test--api
        (forgejo-nav-test--open-diff root patch)
        (diff-goto-source)
        (should (equal (buffer-string) contents))
        (should buffer-read-only)
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                       "local changes\n"))))))

(ert-deftest forgejo-nav-unsaved-source-buffer-is-preserved ()
  "An unsaved visiting buffer must not silently replace the PR version."
  (forgejo-nav-test--fixture
    (let ((edited (find-file-noselect (expand-file-name path worktree))))
      (with-current-buffer edited (goto-char (point-max)) (insert "# unsaved\n"))
      (forgejo-nav-test--api
        (forgejo-nav-test--open-diff root patch)
        (diff-goto-source)
        (should-not (eq (current-buffer) edited))
        (should (equal (buffer-string) contents))
        (should (buffer-modified-p edited))))))

(ert-deftest forgejo-nav-stale-diff-does-not-open-different-api-contents ()
  "If the PR file changed since the diff loaded, fail instead of lying."
  (forgejo-nav-test--fixture
    (forgejo-nav-test--git root "worktree" "remove" worktree)
    (let ((blob (make-string 40 ?a)))
      (forgejo-nav-test--api
        (forgejo-nav-test--open-diff root patch)
        (let ((origin (current-buffer)))
          (should-error (diff-goto-source) :type 'user-error)
          (should (eq (current-buffer) origin)))))))

(ert-deftest forgejo-nav-deleted-file-opens-old-source-and-line ()
  "Deleted file headers and removed lines must visit the old PR source."
  (forgejo-nav-test--fixture
    (forgejo-nav-test--git root "worktree" "remove" worktree)
    (setq patch (concat (forgejo-nav-test--git root "diff" head base) "\n")
          source-revision head)
    ;; The target branch advanced: the patch's old side is the merge base.
    (let ((head base) (base (make-string 40 ?d)) (merge-base head))
      (dolist (case '(("+++ /dev/null" . 1) ("-    return" . 2)))
        (forgejo-nav-test--api
          (forgejo-nav-test--open-diff root patch (car case))
          (diff-goto-source)
          (should (equal (buffer-string) contents))
          (should buffer-read-only)
          (should (= (line-number-at-pos) (cdr case))))))))

(ert-deftest forgejo-nav-refreshed-diff-ignores-pending-source-response ()
  "A pending response must not open a file after the diff has been replaced."
  (forgejo-nav-test--fixture
    (let (reply)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host _endpoint _params callback &rest _args)
                   (setq reply callback))))
        (forgejo-nav-test--open-diff root patch)
        (let ((origin (current-buffer)))
          (diff-goto-source)
          (let ((inhibit-read-only t)) (insert "updated diff\n"))
          (funcall reply `((head . ((sha . ,head))) (base . ((sha . ,base)))) nil)
          (should (eq (current-buffer) origin))
          (should-not (find-buffer-visiting (expand-file-name path worktree))))))))

(ert-deftest forgejo-nav-leaves-ordinary-diff-source-jumps-alone ()
  "The global advice must preserve ordinary local diff navigation."
  (forgejo-nav-test--fixture
    (cl-letf (((symbol-function 'forgejo-api-get)
               (lambda (&rest _) (ert-fail "Ordinary diff made an API call"))))
      (forgejo-nav-test--open-diff (file-name-as-directory worktree) patch)
      (kill-local-variable 'forgejo-diff--pr-number)
      (diff-goto-source)
      (should (equal (file-truename buffer-file-name)
                     (file-truename (expand-file-name path worktree)))))))

(ert-deftest forgejo-nav-hunk-header-visits-hunk-start ()
  (with-temp-buffer
    (insert "diff --git a/file.py b/file.py\nindex 1234567..abcdef0 100644\n--- a/file.py\n+++ b/file.py\n@@ -10 +20 @@\n-old\n+new\n")
    (diff-mode)
    (goto-char (point-min))
    (search-forward "@@ -10")
    (should (= (plist-get (mr-x/forgejo-diff-location) :line) 20))))

(ert-deftest forgejo-nav-stale-visiting-buffer-is-not-pr-source ()
  (forgejo-nav-test--fixture
    (let* ((file (expand-file-name path worktree))
           (default-directory root))
      (write-region "old source\n" nil file nil 'silent)
      (let ((stale (find-file-noselect file)))
        (write-region contents nil file nil 'silent)
        (set-file-times file (time-add (current-time) 5))
        (should-not (verify-visited-file-modtime stale))
        (should-not (mr-x/forgejo-source-worktree head path blob))))))

(ert-deftest forgejo-nav-binary-header-never-opens-the-following-file ()
  (with-temp-buffer
    (insert "diff --git a/image.png b/image.png\nindex 1111111..2222222 100644\nBinary files a/image.png and b/image.png differ\ndiff --git a/file.py b/file.py\nindex 1234567..abcdef0 100644\n--- a/file.py\n+++ b/file.py\n@@ -1 +1 @@\n-old\n+new\n")
    (diff-mode)
    (goto-char (point-min))
    (should-error (mr-x/forgejo-diff-location))))

(ert-deftest forgejo-review-visit-prefers-worktree ()
  (require 'review-session)
  (let* ((source (make-review-source :name "forgejo" :directory "/tmp/"
                                     :recipe '(:kind forgejo :host "h" :owner "o" :repo "r" :number 2
                                               :revs ("base" "head"))))
         (session (make-review-session :source source :directory "/tmp/"))
         (file '(:path "a.el" :old-path "a.el" :blobs ("b1" "b2")))
         shown)
    (cl-letf (((symbol-function 'mr-x/forgejo-source-worktree)
               (lambda (rev path blob) (should (equal (list rev path blob) '("head" "a.el" "b2"))) "/tmp/wt/a.el"))
              ((symbol-function 'find-file-noselect) (lambda (f) (list 'buffer f)))
              ((symbol-function 'mr-x/forgejo-show-source) (lambda (b line) (setq shown (list b line)))))
      (should (mr-x/forgejo-review-visit session file 'new 12))
      (should (equal shown '((buffer "/tmp/wt/a.el") 12))))))

(ert-deftest forgejo-review-visit-ignores-other-sources ()
  (require 'review-session)
  (let ((session (make-review-session :source (make-review-source :recipe '(:kind git-range)))))
    (should-not (mr-x/forgejo-review-visit session '(:path "a") 'new 1))))

(provide 'forgejo-review-navigation-test)
