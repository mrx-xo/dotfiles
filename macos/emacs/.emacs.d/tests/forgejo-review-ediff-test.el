;;; forgejo-review-ediff-test.el --- Per-file PR comparisons -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'forgejo-pull)
(require 'forgejo-review-ediff nil t)

(defconst forgejo-ediff-test--patch
  "diff --git a/old.md b/new.md\nindex 1111111..2222222 100644\n--- a/old.md\n+++ b/new.md\n@@ -1 +1 @@\n-old\n+new\n")

(defmacro forgejo-ediff-test--diff (patch &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,patch)
     (diff-mode)
     (setq-local forgejo-repo--host "https://forge.example")
     (setq-local forgejo-repo--owner "team")
     (setq-local forgejo-repo--name "project")
     (setq-local forgejo-diff--pr-number 10)
     (goto-char (point-max))
     (forward-line -1)
     ,@body))

(ert-deftest forgejo-ediff-renamed-text-keeps-both-paths ()
  (forgejo-ediff-test--diff forgejo-ediff-test--patch
    (let ((sides (mr-x/forgejo-ediff--sides)))
      (should (equal (plist-get (car sides) :path) "old.md"))
      (should (equal (plist-get (cadr sides) :path) "new.md"))
      (should (equal (plist-get (car sides) :blob) "1111111")))))

(ert-deftest forgejo-ediff-added-and-deleted-sides-stay-empty ()
  (dolist (case '(("--- /dev/null\n+++ b/new.md" "0000000..2222222" 0)
                  ("--- a/old.md\n+++ /dev/null" "1111111..0000000" 1)))
    (forgejo-ediff-test--diff
        (format "diff --git a/old.md b/new.md\nindex %s\n%s\n@@ -1 +1 @@\n-old\n+new\n"
                (nth 1 case) (car case))
      (should (plist-get (nth (nth 2 case) (mr-x/forgejo-ediff--sides)) :empty)))))

(ert-deftest forgejo-ediff-binary-does-not-use-following-file ()
  (forgejo-ediff-test--diff
      (concat "diff --git a/a.png b/a.png\nindex 1234567..7654321\nBinary files differ\n"
              forgejo-ediff-test--patch)
    (goto-char (point-min))
    (should-error (mr-x/forgejo-ediff--sides) :type 'user-error)))

(ert-deftest forgejo-ediff-snapshot-has-markdown-colors-and-no-file ()
  "Catches the Polymode setup that left the trial unfontified."
  (let ((buffer (mr-x/forgejo-ediff--buffer
                 "new.md" "## Heading\n\nSome **bold** and `code`.\n" "after" 10)))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq major-mode 'markdown-mode))
          (should (get-text-property 4 'face))
          (should buffer-read-only)
          (should-not buffer-file-name)
          (should-not (bound-and-true-p polymode-mode))
          (should-not (buffer-modified-p)))
      (kill-buffer buffer))))

(ert-deftest forgejo-ediff-api-uses-merge-base-and-checks-both-blobs ()
  "The old side must not follow an advanced target branch."
  (dolist (stale '(nil t))
    (forgejo-ediff-test--diff forgejo-ediff-test--patch
      (let (shown requests)
        (cl-letf (((symbol-function 'forgejo-api-get)
                   (lambda (_host endpoint params callback &rest _)
                     (push (cons endpoint params) requests)
                     (cond
                      ((string-suffix-p "/pulls/10" endpoint)
                       (funcall callback '((merge_base . "merge-base")
                                           (base . ((sha . "advanced-base")))
                                           (head . ((sha . "head")))) nil))
                      ((string-suffix-p "/old.md" endpoint)
                       (should (equal params '(("ref" . "merge-base"))))
                       (funcall callback
                                `((sha . ,(if stale "3333333" "1111111"))
                                  (encoding . "base64") (content . "b2xkCg==")) nil))
                      ((string-suffix-p "/new.md" endpoint)
                       (should (equal params '(("ref" . "head"))))
                       (funcall callback '((sha . "2222222")
                                           (encoding . "base64") (content . "bmV3Cg==")) nil))
                      (t (ert-fail endpoint)))))
                  ((symbol-function 'mr-x/forgejo-ediff--show)
                   (lambda (_sides texts &rest _) (setq shown texts))))
          (if stale
              (progn (should-error (mr-x/forgejo-diff-ediff) :type 'user-error)
                     (should-not shown))
            (mr-x/forgejo-diff-ediff)
            (should (equal shown '("old\n" "new\n")))
            (should (= (length requests) 3))))))))

(ert-deftest forgejo-ediff-refreshed-patch-ignores-pending-response ()
  (forgejo-ediff-test--diff forgejo-ediff-test--patch
    (let (reply)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host _endpoint _params callback &rest _) (setq reply callback)))
                ((symbol-function 'mr-x/forgejo-ediff--show)
                 (lambda (&rest _) (ert-fail "Opened a stale comparison"))))
        (mr-x/forgejo-diff-ediff)
        (let ((inhibit-read-only t)) (insert "changed"))
        (let ((first-reply reply))
          (funcall first-reply '((head . ((sha . "head")))) nil)
          (should (eq first-reply reply)))))))

(ert-deftest forgejo-ediff-new-file-does-not-fetch-dev-null ()
  (forgejo-ediff-test--diff
      "diff --git a/new.md b/new.md\nindex 0000000..2222222\n--- /dev/null\n+++ b/new.md\n@@ -0,0 +1 @@\n+new\n"
    (let (shown)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host endpoint _params callback &rest _)
                   (cond
                    ((string-suffix-p "/pulls/10" endpoint)
                     (funcall callback '((head . ((sha . "head")))) nil))
                    ((string-suffix-p "/contents/new.md" endpoint)
                     (funcall callback '((sha . "2222222") (encoding . "base64")
                                         (content . "bmV3Cg==")) nil))
                    (t (ert-fail endpoint)))))
                ((symbol-function 'mr-x/forgejo-ediff--show)
                 (lambda (_sides texts &rest _) (setq shown texts))))
        (mr-x/forgejo-diff-ediff)
        (should (equal shown '("" "new\n")))))))

(ert-deftest forgejo-ediff-session-is-readable-and-restores-layout ()
  "Exercise real Ediff startup and quit, not just snapshot preparation."
  (save-window-excursion
    (delete-other-windows)
    (let ((layout (current-window-configuration)) control a b)
      (unwind-protect
          (progn
            (mr-x/forgejo-ediff--show
             '((:path "note.md") (:path "note.md"))
             '("## Heading\n\nold\n" "## Heading\n\nnew\n") 99 (selected-frame))
            (setq a (get-buffer "PR #99 before: note.md")
                  b (get-buffer "PR #99 after: note.md")
                  control (car (buffer-local-value 'ediff-this-buffer-ediff-sessions a)))
            (dolist (buffer (list a b))
              (with-current-buffer buffer
                (should buffer-read-only)
                (should (get-text-property 4 'face))
                (should-not buffer-file-name)
                (should-not (plist-get (cadr (assq 'ediff-current-diff-B face-remapping-alist))
                                       :foreground))))
            (with-current-buffer control
              (should (<= (abs (- (window-total-width ediff-window-A)
                                 (window-total-width ediff-window-B))) 1)))
            (with-selected-window (get-buffer-window control)
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (ediff-quit nil)))
            (should (compare-window-configurations layout (current-window-configuration)))
            (should-not (buffer-live-p a))
            (should-not (buffer-live-p b)))
        (dolist (buffer (list control a b))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'forgejo-review-ediff-test)
