;;; mr-x-docs-usage.el --- Project usage search -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'project)

(defun mr-x/docs-usage--qualified-pattern (name)
  "Return a word-bounded search pattern for qualified NAME."
  (let ((base (if (string-prefix-p "Package " name)
                  (substring name (length "Package "))
                name)))
    (concat "\\b" (regexp-quote base) "\\b")))

(defun mr-x/docs-usage-pattern (name slug)
  "Return the ripgrep pattern for documentation entry NAME in SLUG.
Return nil for prose entries that should not be searched."
  (when (and (stringp name)
             (or (string-prefix-p "Package " name)
                 (not (string-match-p " " name)))
             (not (string-match-p "\\`[0-9]" name)))
    (cond
     ((and (string-match "\\.prototype\\.\\([^()]+\\)()\\'" name)
           (or (string-prefix-p "javascript" slug)
               (string-prefix-p "dom" slug)))
      (concat "\\." (regexp-quote (match-string 1 name)) "\\("))
     ((string-suffix-p "()" name)
      (concat "\\b" (regexp-quote (substring name 0 -2)) "\\("))
     (t (mr-x/docs-usage--qualified-pattern name)))))

(defun mr-x/docs-usage-root ()
  "Return the current project root without prompting, or nil."
  (when-let* ((project (project-current nil)))
    (project-root project)))

(defun mr-x/docs-usage-search (pattern root &optional limit)
  "Search ROOT for PATTERN with ripgrep and return a result plist.
The result contains total :count, distinct-file :files, and up to LIMIT
matches in :hits.  Return nil when ripgrep is unavailable or ROOT is nil."
  (when (and root (executable-find "rg"))
    (let ((limit (or limit 3))
          (output (generate-new-buffer " *mr-x-docs-usage-rg*"))
          (timed-out nil)
          (status nil))
      (unwind-protect
          (progn
            (with-timeout (2 (setq timed-out t))
              (setq status
                    (call-process "rg" nil output nil
                                  "--vimgrep" "--no-heading" "--color" "never"
                                  "--sort" "path"
                                  "-e" pattern root)))
            (unless timed-out
              (let ((lines (with-current-buffer output
                             (split-string (buffer-string) "\n" t)))
                    (count 0)
                    (files nil)
                    (hits nil))
                (dolist (line lines)
                  (when (string-match
                         "\\`\\([^:\n]+\\):\\([0-9]+\\):[0-9]+:\\(.*\\)\\'"
                         line)
                    (let ((file (file-relative-name (match-string 1 line) root))
                          (line-number (string-to-number (match-string 2 line)))
                          (text (string-trim-left (match-string 3 line))))
                      (setq count (1+ count))
                      (cl-pushnew file files :test #'equal)
                      (when (< (length hits) limit)
                        (setq hits (append hits
                                           (list (list file line-number text))))))))
                (list :count count :files (length files) :hits hits))))
        (kill-buffer output)))))

(defun mr-x/docs-usage (name slug)
  "Return usage search results for documentation entry NAME in SLUG."
  (when-let* ((pattern (mr-x/docs-usage-pattern name slug))
              (root (mr-x/docs-usage-root)))
    (mr-x/docs-usage-search pattern root)))

(provide 'mr-x-docs-usage)

;;; mr-x-docs-usage.el ends here
