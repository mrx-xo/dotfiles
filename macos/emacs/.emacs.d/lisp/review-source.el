;;; review-source.el --- Sources for read-only review sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; The session consumes file lists, snapshot texts, and origin descriptions.
;; Only source implementations know about Git or forge APIs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(cl-defstruct review-source
  "A review backend.  TEXT calls CALLBACK with text on success.
For asynchronous failures, it calls CALLBACK with nil and an error string."
  name title range-label files text origin directory
  number subtitle)

(defvar review-source-updated-functions nil
  "Called with a source after its title or subtitle arrive late.")

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
                      ;; Prefix ./ so Git's literal ~/ directory is not HOME.
                      (let ((name (expand-file-name (concat "./" path) directory)))
                        (or (file-symlink-p name)
                            (progn
                              (unless (file-in-directory-p name directory)
                                (user-error "Review path escapes repository: %s" path))
                              (with-temp-buffer
                                (insert-file-contents name)
                                (buffer-string))))))))))
       :origin
       (lambda (file start end)
         (let ((path (or (plist-get file :origin-path) (plist-get file :path))))
           (list :label (format "%s:%s @ %s%s" path
                                (if (= start end) start (format "%d-%d" start end)) label
                                (if (eq (plist-get file :side) 'old) " (old)" ""))
                 :side (or (plist-get file :side) 'new)
                 :link (format "file:%s::%d"
                               (abbreviate-file-name
                                (expand-file-name (concat "./" path) directory)) start)
                 :url nil)))))))

(declare-function mr-x/forgejo-ediff--entry-at-point "forgejo-review-ediff")
(declare-function forgejo-api-get "forgejo-api")

(defun review-source-forgejo-patch-files ()
  "Parse every entry of the Forgejo PR patch in the current buffer."
  (require 'forgejo-review-ediff)
  (save-excursion
    (goto-char (point-min))
    (let (files)
      (while (re-search-forward "^diff --git " nil t)
        (let* ((entry (mr-x/forgejo-ediff--entry-at-point))
               (old (car (plist-get entry :sides))) (new (cadr (plist-get entry :sides)))
               (kind (cond ((plist-get old :empty) 'added)
                           ((plist-get new :empty) 'deleted)
                           ((equal (plist-get old :path) (plist-get new :path)) 'modified)
                           (t 'renamed))))
          (push (list :path (if (eq kind 'deleted) (plist-get old :path) (plist-get new :path))
                      :old-path (and (not (eq kind 'added)) (plist-get old :path))
                      :kind kind :binary (plist-get entry :binary)
                      :blobs (list (plist-get old :blob) (plist-get new :blob)))
                files)
          (goto-char (plist-get entry :end))))
      (nreverse files))))

(defun review-source-forgejo--fetch (host owner repo path revision blob callback)
  "Fetch PATH at REVISION through the contents API, check BLOB, call CALLBACK."
  (forgejo-api-get
   host (format "repos/%s/%s/contents/%s" owner repo
                (mapconcat #'url-hexify-string (split-string path "/") "/"))
   `(("ref" . ,revision))
   (lambda (source _headers)
     (let (text failure)
       (condition-case err
           (progn
             (unless (and (stringp blob) (stringp (alist-get 'sha source))
                          (string-prefix-p blob (alist-get 'sha source)))
               (user-error "PR source for %s changed since this patch loaded; reopen the diff" path))
             (unless (and (equal (alist-get 'encoding source) "base64")
                          (stringp (alist-get 'content source)))
               (user-error "The API did not return source text for %s" path))
             (setq text (decode-coding-string (base64-decode-string (alist-get 'content source))
                                              ;; -unix keeps CRLF: line endings are content.
                                              'utf-8-unix))
             (when (string-match-p "\0" text)
               (user-error "Cannot compare binary source %s as text" path)))
         (error (setq failure (error-message-string err))))
       (if failure (funcall callback nil failure) (funcall callback text))))
   :error-callback
   (lambda (error)
     (funcall callback nil (format "Cannot load %s: %s" path (plist-get error :message))))))

(defun review-source-forgejo-pr (host owner repo number files &optional title)
  "Return a source for PR NUMBER of OWNER/REPO on HOST with FILES from the patch."
  (require 'forgejo-api)
  (let ((revisions nil) source)
    (cl-flet ((with-revisions (k failure)
                (if revisions (funcall k revisions)
                  (forgejo-api-get
                   host (format "repos/%s/%s/pulls/%d" owner repo number) nil
                   (lambda (data _headers)
                     ;; The header shows the PR's title and branches.
                     (when-let ((pr-title (alist-get 'title data)))
                       (setf (review-source-title source) pr-title))
                     (let ((head (alist-get 'ref (alist-get 'head data)))
                           (base (alist-get 'ref (alist-get 'base data))))
                       (when (and head base)
                         (setf (review-source-subtitle source)
                               (format "%s / %s   %s -> %s" owner repo head base))))
                     (run-hook-with-args 'review-source-updated-functions source)
                     (let ((revs (list (or (alist-get 'merge_base data)
                                           (alist-get 'sha (alist-get 'base data)))
                                       (alist-get 'sha (alist-get 'head data)))))
                       (if (and (stringp (car revs)) (stringp (cadr revs)))
                           (progn (setq revisions revs) (funcall k revisions))
                         (funcall failure "PR metadata has no source revisions"))))
                   :error-callback
                   (lambda (error)
                     (funcall failure (format "Cannot load PR metadata: %s"
                                              (plist-get error :message))))))))
      (setq source
       (make-review-source
       :name "forgejo" :title (or title (format "PR #%d" number)) :number number
       :subtitle (format "%s / %s" owner repo)
       :directory default-directory
       :range-label (format "%s/%s#%d" owner repo number)
       :files (lambda () files)
       :text (lambda (file side callback)
               (let* ((path (if (eq side 'old) (plist-get file :old-path) (plist-get file :path)))
                      (blob (nth (if (eq side 'old) 0 1) (plist-get file :blobs))))
                 (if (or (null path) (plist-get file :binary)
                         (and (eq side 'old) (eq (plist-get file :kind) 'added))
                         (and (eq side 'new) (eq (plist-get file :kind) 'deleted)))
                     (funcall callback "")
                   (with-revisions
                    (lambda (revs)
                      (review-source-forgejo--fetch host owner repo path
                                                    (if (eq side 'old) (car revs) (cadr revs))
                                                    blob callback))
                    (lambda (error) (funcall callback nil error))))))
       :origin (lambda (file start end)
                 (list :label (format "%s/%s#%d %s:%s%s" owner repo number
                                      (or (plist-get file :origin-path) (plist-get file :path))
                                      (if (= start end) start (format "%d-%d" start end))
                                      (if (eq (plist-get file :side) 'old) " (old)" ""))
                       :side (or (plist-get file :side) 'new)
                       :link (format "forgejo:%s/%s#%d" owner repo number)
                       :url (format "%s/%s/%s/pulls/%d/files" host owner repo number)))))
      source)))

(provide 'review-source)
;;; review-source.el ends here
