;;; forgejo-review-ediff.el --- Read-only per-file PR comparisons -*- lexical-binding: t; -*-

;;; Commentary:
;; Optional Ediff view for a file in a Forgejo patch.  Both panes are API
;; snapshots checked against the patch's blob IDs, never working-tree files.

;;; Code:
(require 'cl-lib)
(require 'diff-mode)
(require 'magit)
(require 'ediff)
(require 'face-remap)
(require 'forgejo-api)

(defvar forgejo-repo--host)
(defvar forgejo-repo--owner)
(defvar forgejo-repo--name)
(defvar forgejo-diff--pr-number)
(defvar-local mr-x/forgejo-ediff--request nil)

(defun mr-x/forgejo-ediff-available-p ()
  "Whether the current buffer is a Forgejo PR patch."
  (and (derived-mode-p 'diff-mode)
       (bound-and-true-p forgejo-repo--host)
       (bound-and-true-p forgejo-diff--pr-number)))

(defun mr-x/forgejo-ediff--sides ()
  "Read old and new paths and blob IDs for the file at point.
Reject binary and metadata-only entries rather than using the next file."
  (save-excursion
    (save-restriction
      (beginning-of-line)
      (unless (looking-at "^diff --git ")
        (unless (re-search-backward "^diff --git " nil t)
          (user-error "Put point inside a file's diff first")))
      (let ((start (point)))
        (forward-line)
        (narrow-to-region start (if (re-search-forward "^diff --git " nil t)
                                   (line-beginning-position) (point-max))))
      (goto-char (point-min))
      (unless (re-search-forward "^@@ " nil t)
        (user-error "This entry has no text changes to compare (binary or metadata-only)"))
      (let ((limit (line-beginning-position)) blobs paths)
        (goto-char (point-min))
        (unless (re-search-forward "^index \\([[:xdigit:]]+\\)\\.\\.\\([[:xdigit:]]+\\)" limit t)
          (user-error "This patch has no source blob IDs"))
        (setq blobs (list (match-string-no-properties 1) (match-string-no-properties 2)))
        (unless (re-search-forward "^--- \\([^\t\n]+\\).*\n\\+\\+\\+ \\([^\t\n]+\\)" limit t)
          (user-error "This patch has no old/new file paths"))
        (setq paths (list (match-string-no-properties 1) (match-string-no-properties 2)))
        (cl-mapcar
         (lambda (name blob)
           (let* ((decoded (magit-decode-git-path name))
                  (empty (equal decoded "/dev/null"))
                  (path (if empty decoded (replace-regexp-in-string "\\`[ab]/" "" decoded))))
             (unless (or empty
                         (and (not (file-name-absolute-p path))
                              (not (member ".." (split-string path "/")))))
               (user-error "Invalid source path in patch"))
             (list :path path :blob blob :empty empty)))
         paths blobs)))))

(defun mr-x/forgejo-ediff--buffer (path text side number)
  "Create a read-only, syntax-highlighted snapshot of PATH and TEXT.
SIDE and NUMBER label the pane.  Never run file-local code from a PR."
  (let ((buffer (generate-new-buffer (format "PR #%d %s: %s" number side path))))
    (condition-case err
        (with-current-buffer buffer
          (insert text)
          (let ((buffer-file-name path)
                (enable-local-variables nil)
                (enable-local-eval nil))
            ;; Polymode needs its interactive buffer lifecycle.  Plain Markdown
            ;; reliably fontifies these disposable snapshots, including at EOF.
            (delay-mode-hooks
              (if (string-match-p "\\.\\(?:md\\|markdown\\|mkd\\|mdown\\|mkdn\\|mdwn\\|mdx\\)\\'" path)
                  (progn (require 'markdown-mode) (markdown-mode))
                (set-auto-mode))))
          (font-lock-mode 1)
          (font-lock-ensure (point-min) (point-max))
          (dolist (spec '((ediff-current-diff-A . "#3b2626")
                          (ediff-current-diff-B . "#2e3b2e")
                          (ediff-fine-diff-A . "#5c3030")
                          (ediff-fine-diff-B . "#3d5c3d")))
            ;; Replace the face base: a relative background still inherits the
            ;; theme's foreground and would turn all added text yellow.
            (face-remap-set-base (car spec) (list :background (cdr spec) :extend t)))
          (setq buffer-read-only t
                header-line-format (format "PR #%d | %s | %s (read-only)" number side path)
                display-line-numbers t)
          (set-buffer-modified-p nil)
          buffer)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun mr-x/forgejo-ediff--show (sides texts number frame)
  "Show SIDES and TEXTS for PR NUMBER in FRAME; restore its layout on quit."
  (with-selected-frame frame
    (let ((layout (current-window-configuration)) buffers)
      (condition-case err
          (progn
            (cl-mapc
             (lambda (side text label)
               (push (mr-x/forgejo-ediff--buffer
                      (if (plist-get side :empty)
                          (concat (plist-get (if (equal label "before") (cadr sides) (car sides)) :path)
                                  " (absent)")
                        (plist-get side :path))
                      text label number) buffers))
             sides texts '("before" "after"))
            (setq buffers (nreverse buffers))
            (let ((ediff-split-window-function #'split-window-horizontally)
                  (ediff-window-setup-function #'ediff-setup-windows-plain))
              (ediff-buffers
               (car buffers) (cadr buffers)
               (list
                (lambda ()
                  (setq-local ediff-keep-variants t)
                  (add-hook 'ediff-after-quit-hook-internal
                            (lambda ()
                              (when (frame-live-p frame) (set-window-configuration layout))
                              (dolist (buffer buffers)
                                (when (and (buffer-live-p buffer)
                                           (not (buffer-modified-p buffer)))
                                  (kill-buffer buffer)))) t t)
                  (let ((delta (/ (- (window-total-width ediff-window-B)
                                    (window-total-width ediff-window-A)) 2)))
                    (unless (zerop delta) (window-resize ediff-window-A delta t)))
                  (ediff-next-difference))))))
        (error
         (set-window-configuration layout)
         (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) buffers)
         (signal (car err) (cdr err)))))))

;;;###autoload
(defun mr-x/forgejo-diff-ediff ()
  "Compare the file at point in a Forgejo PR patch using read-only Ediff."
  (interactive)
  (unless (mr-x/forgejo-ediff-available-p)
    (user-error "Open a Forgejo PR diff and put point on a changed file"))
  (let* ((sides (mr-x/forgejo-ediff--sides))
         (origin (current-buffer))
         (tick (buffer-chars-modified-tick))
         (request (setq mr-x/forgejo-ediff--request (make-symbol "ediff-request")))
         (frame (selected-frame))
         (host forgejo-repo--host)
         (owner forgejo-repo--owner)
         (repo forgejo-repo--name)
         (number forgejo-diff--pr-number)
         (valid (lambda ()
                  (and (frame-live-p frame) (buffer-live-p origin)
                       (with-current-buffer origin
                         (and (eq request mr-x/forgejo-ediff--request)
                              (= tick (buffer-chars-modified-tick))))))))
    (message "Loading before/after snapshots for PR #%d..." number)
    (forgejo-api-get
     host (format "repos/%s/%s/pulls/%d" owner repo number) nil
     (lambda (data _headers)
       (when (funcall valid)
         (let ((revisions (list (or (alist-get 'merge_base data)
                                   (alist-get 'sha (alist-get 'base data)))
                               (alist-get 'sha (alist-get 'head data)))))
           (cl-labels
               ((fetch (remaining refs texts)
                  (when (funcall valid)
                    (if (null remaining)
                        (mr-x/forgejo-ediff--show sides (nreverse texts) number frame)
                      (let ((side (car remaining)) (revision (car refs)))
                        (if (plist-get side :empty)
                            (fetch (cdr remaining) (cdr refs) (cons "" texts))
                          (unless revision (user-error "PR metadata has no source revision"))
                          (forgejo-api-get
                           host (format "repos/%s/%s/contents/%s" owner repo
                                        (mapconcat #'url-hexify-string
                                                   (split-string (plist-get side :path) "/") "/"))
                           `(("ref" . ,revision))
                           (lambda (source _source-headers)
                             (when (funcall valid)
                               (unless (and (stringp (alist-get 'sha source))
                                            (string-prefix-p (plist-get side :blob) (alist-get 'sha source)))
                                 (user-error "PR source changed since this patch loaded; reopen the diff"))
                               (unless (and (equal (alist-get 'encoding source) "base64")
                                            (stringp (alist-get 'content source)))
                                 (user-error "The API did not return source text"))
                               (let ((text (decode-coding-string
                                            (base64-decode-string (alist-get 'content source)) 'utf-8)))
                                 (when (string-match-p "\0" text)
                                   (user-error "Cannot compare binary source as text"))
                                 (fetch (cdr remaining) (cdr refs) (cons text texts))))))))))))
             (fetch sides revisions nil))))))))

(provide 'forgejo-review-ediff)
;;; forgejo-review-ediff.el ends here
