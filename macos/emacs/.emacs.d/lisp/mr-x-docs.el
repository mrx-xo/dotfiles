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

(provide 'mr-x-docs)
;;; mr-x-docs.el ends here
