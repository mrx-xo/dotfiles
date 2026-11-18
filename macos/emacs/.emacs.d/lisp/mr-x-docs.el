;;; mr-x-docs.el --- One-key DevDocs lookup with a fixed digest layout -*- lexical-binding: t; -*-

;; `SPC ? c' searches every entry of every docset devdocs.el has
;; downloaded and renders the hit as a digest (blurb, SYNOPSIS, EXAMPLES,
;; PARAMETERS) in the `*tldr*' layout.  devdocs.el stays the downloader
;; and updater; only its on-disk data is read here.
;;
;; Design: docs/active/specs/2026-11-17-docs-lookup-design.md

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'dom)
(require 'ansi-color)
(require 'url-util)

(defvar mr-x/docs-data-dir
  (expand-file-name "var/devdocs/data/" user-emacs-directory)
  "Directory holding one devdocs docset per subdirectory.")

(defvar mr-x/docs--cache nil
  "Alist SLUG -> (MTIME . ENTRIES) memoising each docset's parsed index.")

;;; Data

(defun mr-x/docs--read-file (file)
  "Return the printed Lisp object stored in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (read (current-buffer))))

(defun mr-x/docs--docsets ()
  "Return the installed docsets as a list of (SLUG . TYPE)."
  (let (acc)
    (dolist (dir (and (file-directory-p mr-x/docs-data-dir)
                      (directory-files mr-x/docs-data-dir t "\\`[^.]")))
      (let ((meta (expand-file-name "metadata" dir)))
        (when (and (file-directory-p dir) (file-readable-p meta))
          (let ((m (mr-x/docs--read-file meta)))
            (push (cons (or (alist-get 'slug m) (file-name-nondirectory dir))
                        (alist-get 'type m))
                  acc)))))
    (nreverse acc)))

(defun mr-x/docs--docset-entries (slug)
  "Return SLUG's entries as plists, reading its index once per mtime."
  (let* ((index (expand-file-name (concat slug "/index") mr-x/docs-data-dir))
         (mtime (file-attribute-modification-time (file-attributes index)))
         (hit (assoc slug mr-x/docs--cache)))
    (if (and hit (equal (cadr hit) mtime))
        (cddr hit)
      (let ((entries
             (mapcar
              (lambda (e)
                (let* ((path (alist-get 'path e))
                       (hash (string-search "#" path)))
                  (list :name (alist-get 'name e)
                        :path (if hash (substring path 0 hash) path)
                        :anchor (and hash (substring path (1+ hash)))
                        :type (alist-get 'type e)
                        :slug slug)))
              (alist-get 'entries (mr-x/docs--read-file index)))))
        (setf (alist-get slug mr-x/docs--cache nil nil #'equal)
              (cons mtime entries))
        entries))))

(defun mr-x/docs--entries ()
  "Return every entry of every installed docset."
  (mapcan (lambda (d) (copy-sequence (mr-x/docs--docset-entries (car d))))
          (mr-x/docs--docsets)))

(defun mr-x/docs-refresh ()
  "Forget the cached indexes so the next lookup rereads them."
  (interactive)
  (setq mr-x/docs--cache nil))

;;; Completion

(defcustom mr-x/docs-mode-docsets
  '(((js-mode js-ts-mode typescript-mode typescript-ts-mode tsx-ts-mode web-mode)
     "javascript" "dom" "html")
    ((python-mode python-ts-mode) "python~3.12")
    ((go-mode go-ts-mode) "go"))
  "Alist of (MAJOR-MODES . SLUGS): docsets listed first in those modes."
  :type '(alist :key-type (repeat symbol) :value-type (repeat string))
  :group 'mr-x)

(defun mr-x/docs--preferred-slugs ()
  "Return the docset slugs to list first for the current buffer's major mode."
  (cdr (seq-find (lambda (row) (apply #'derived-mode-p (car row)))
                 mr-x/docs-mode-docsets)))

(defun mr-x/docs--candidates ()
  "Return an alist (STRING . ENTRY) over every entry, STRINGs made unique.
A name that appears more than once gets an invisible slug/path suffix so
the completion table keeps every entry while the visible text stays the
plain name."
  (let ((seen (make-hash-table :test #'equal))
        acc)
    (dolist (e (mr-x/docs--entries))
      (puthash (plist-get e :name) (1+ (gethash (plist-get e :name) seen 0)) seen))
    (dolist (e (mr-x/docs--entries))
      (let ((name (plist-get e :name)))
        (push (cons (if (> (gethash name seen) 1)
                        (concat name (propertize (format " %s/%s" (plist-get e :slug)
                                                        (plist-get e :path))
                                                 'invisible t))
                      name)
                    e)
              acc)))
    (nreverse acc)))

(defun mr-x/docs--read (initial)
  "Prompt for an entry with INITIAL input and return the chosen entry plist."
  (let* ((cands (mr-x/docs--candidates))
         ;; 28k candidates: every metadata callback must be O(1), not `assoc'.
         (table-hash (let ((h (make-hash-table :test #'equal :size (length cands))))
                       (dolist (c cands h) (puthash (car c) (cdr c) h))))
         (entry (lambda (cand) (gethash cand table-hash)))
         (preferred (mr-x/docs--preferred-slugs))
         (sort (lambda (strings)
                 (seq-sort-by (lambda (s) (if (member (plist-get (funcall entry s) :slug)
                                                      preferred)
                                              0 1))
                              #'< strings)))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . mr-x-docs)
                        (group-function
                         . ,(lambda (cand transform)
                              (if transform cand
                                (plist-get (funcall entry cand) :slug))))
                        (annotation-function
                         . ,(lambda (cand)
                              (propertize (concat "  " (plist-get (funcall entry cand) :type))
                                          'face 'completions-annotations)))
                        (display-sort-function . ,sort)
                        (cycle-sort-function . ,sort))
                    (complete-with-action action cands string pred))))
         (choice (completing-read "docs: " table nil t initial)))
    (or (funcall entry choice)
        (user-error "No docs entry named %s" choice))))

(provide 'mr-x-docs)
;;; mr-x-docs.el ends here
