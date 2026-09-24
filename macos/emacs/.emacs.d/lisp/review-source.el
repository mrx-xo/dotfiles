;;; review-source.el --- Sources for read-only review sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; The session consumes file lists, snapshot texts, and origin descriptions.
;; Only source implementations know about Git or forge APIs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(cl-defstruct review-source
  name title range-label files text origin directory)

(defun review-source--git (directory &rest args)
  "Run Git ARGS in DIRECTORY, returning stdout or signalling an error."
  (let ((default-directory directory)
        (coding-system-for-read 'utf-8-unix))
    (with-temp-buffer
      (let ((status (apply #'call-process "git" nil t nil args)))
        (unless (eq status 0)
          (user-error "Git failed: %s" (string-trim (buffer-string)))))
      (buffer-string))))

(defun review-source--git-kind (status)
  "Map a Git name-status STATUS to a file kind."
  (pcase (substring status 0 1)
    ("A" 'added) ("D" 'deleted) ("R" 'renamed) ("C" 'added)
    (_ 'modified)))

(defun review-source--git-revision (directory revision)
  "Resolve REVISION to a commit in DIRECTORY; reject flags and invalid names."
  (string-trim
   (review-source--git directory "rev-parse" "--verify" "--end-of-options"
                       (concat (if (string-empty-p revision) "HEAD" revision)
                               "^{commit}"))))

(defun review-source--git-revs (directory range)
  "Resolve RANGE to immutable (OLD . NEW) revisions in DIRECTORY.
NEW nil means working tree; :index means staged content."
  (cond
   ((or (null range) (equal range "--staged"))
    (cons (review-source--git-revision directory "HEAD")
          (and range :index)))
   ((string-match "\\`\\(.*?\\)\\(\\.\\.\\.?\\)\\(.*\\)\\'" range)
    (let* ((left (match-string 1 range))
           (dots (match-string 2 range))
           (right (match-string 3 range))
           (a (review-source--git-revision directory left))
           (b (review-source--git-revision directory right)))
      (cons (if (equal dots "...")
                (string-trim (review-source--git directory "merge-base" a b))
              a)
            b)))
   (t
    (let* ((rev (review-source--git-revision directory range))
           (parents (split-string
                     (string-trim
                      (review-source--git directory "rev-list" "--parents" "-n" "1" rev)))))
      (cons (or (cadr parents)
                (string-trim (review-source--git directory "hash-object" "-t" "tree" "--stdin")))
            rev)))))

(defun review-source--git-files (directory revs)
  "List changed files in DIRECTORY using resolved REVS.
Parse NUL-delimited output so spaces, tabs, newlines and renames are safe."
  (let* ((old (car revs)) (new (cdr revs))
         (args (append '("diff" "--no-ext-diff" "--no-textconv" "--find-renames")
                       (cond ((eq new :index) (list "--cached" old))
                             (new (list old new))
                             (t (list old)))))
         (fields (split-string
                  (apply #'review-source--git directory
                         (append args '("--name-status" "-z" "--"))) "\0" t))
         (stats (split-string
                 (apply #'review-source--git directory
                        (append args '("--numstat" "-z" "--"))) "\0"))
         binaries files)
    (while stats
      (let ((stat (pop stats)))
        (when (string-match "\\`\\([0-9-]+\\)\t\\([0-9-]+\\)\t" stat)
          (let ((binary (equal (match-string 1 stat) "-"))
                (path (substring stat (match-end 0))))
            (when (string-empty-p path)
              (pop stats)
              (setq path (pop stats)))
            (when binary (push path binaries))))))
    (while fields
      (let* ((status (pop fields))
             (kind (review-source--git-kind status))
             (from (and (memq (aref status 0) '(?R ?C)) (pop fields)))
             (path (pop fields)))
        (push (list :path path
                    :old-path (unless (eq kind 'added) (or from path))
                    :kind kind :binary (and (member path binaries) t)
                    :index-blob
                    (when (and (eq new :index) (not (eq kind 'deleted)))
                      (string-trim (review-source--git directory "rev-parse"
                                                       (concat ":" path)))))
              files)))
    (sort files (lambda (a b) (string< (plist-get a :path) (plist-get b :path))))))

(defun review-source--git-show (directory rev path)
  "Read PATH at REV in DIRECTORY.  Errors must never look like empty files."
  (review-source--git directory "show" (format "%s:%s" rev path)))

(defun review-source-git-range (directory &optional range)
  "Create a source for Git RANGE in DIRECTORY.
Nil reviews the working tree against HEAD; --staged reviews the index.
A..B and A...B review commit ranges; a single revision reviews that
commit against its first parent, or the empty tree for a root commit.
Revisions and index blobs are pinned when the file list is first read."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (label (cond ((null range) "working tree vs HEAD")
                      ((equal range "--staged") "staged vs HEAD")
                      (t range)))
         revs files loaded)
    (cl-labels ((ensure-files ()
                  (unless loaded
                    (setq revs (review-source--git-revs directory range)
                          files (review-source--git-files directory revs)
                          loaded t))
                  files))
      (make-review-source
       :name "git" :title (abbreviate-file-name directory)
       :directory directory :range-label label
       :files #'ensure-files
       :text
       (lambda (file side callback)
         (ensure-files)
         (let ((path (plist-get file (if (eq side 'old) :old-path :path)))
               (kind (plist-get file :kind)))
           (funcall callback
                    (cond
                     ((or (null path) (plist-get file :binary)
                          (and (eq side 'old) (eq kind 'added))
                          (and (eq side 'new) (eq kind 'deleted))) "")
                     ((eq side 'old) (review-source--git-show directory (car revs) path))
                     ((eq (cdr revs) :index)
                      (review-source--git directory "cat-file" "blob"
                                          (plist-get file :index-blob)))
                     ((cdr revs) (review-source--git-show directory (cdr revs) path))
                     (t
                      (let ((name (expand-file-name path directory)))
                        (or (file-symlink-p name)
                            (with-temp-buffer
                              (insert-file-contents name)
                              (buffer-string)))))))))
       :origin
       (lambda (file start end)
         (let ((path (or (plist-get file :origin-path) (plist-get file :path))))
           (list :label (format "%s:%s @ %s" path
                                (if (= start end) start (format "%d-%d" start end)) label)
                 :link (format "file:%s::%d"
                               (abbreviate-file-name (expand-file-name path directory)) start)
                 :url nil)))))))

(provide 'review-source)
;;; review-source.el ends here
