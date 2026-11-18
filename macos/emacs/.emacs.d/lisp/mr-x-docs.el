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

;;; Pages and DOM helpers

(defun mr-x/docs--page (slug path)
  "Return the parsed DOM of docset SLUG's page at PATH (no anchor)."
  (let ((file (expand-file-name (concat slug "/" (url-hexify-string path) ".html")
                                mr-x/docs-data-dir)))
    (unless (file-readable-p file)
      (user-error "No page on disk for %s/%s; run `devdocs-update-all'" slug path))
    (with-temp-buffer
      (insert-file-contents file)
      (libxml-parse-html-region (point-min) (point-max)))))

(defun mr-x/docs--by-id (dom id)
  "Return the first node in DOM whose id attribute is ID, or nil."
  (car (dom-search dom (lambda (n) (equal (dom-attr n 'id) id)))))

(defun mr-x/docs--nodes (dom)
  "Return every element node of DOM in document order."
  (let (acc)
    (cl-labels ((walk (n)
                  (when (consp n)
                    (push n acc)
                    (dolist (c (dom-children n)) (walk c)))))
      (walk dom))
    (nreverse acc)))

(defun mr-x/docs--first-after (dom start pred &optional stop)
  "Return the first node after START in DOM satisfying PRED.
With START nil, search from the top.  Stop and return nil at the first
node satisfying STOP, if given."
  (let ((seen (null start)))
    (seq-find (lambda (n)
                (cond ((eq n start) (setq seen t) nil)
                      ((not seen) nil)
                      ((and stop (funcall stop n)) (setq seen 'stopped) nil)
                      ((eq seen 'stopped) nil)
                      (t (funcall pred n))))
              (mr-x/docs--nodes dom))))

(defun mr-x/docs--tag-p (tag)
  "Return a predicate matching nodes of TAG (a symbol or list of symbols)."
  (let ((tags (ensure-list tag)))
    (lambda (n) (memq (dom-tag n) tags))))

(defun mr-x/docs--text (node)
  "Return NODE's text with whitespace collapsed, or nil for a nil NODE."
  (and node
       (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (dom-texts node "")))))

(defun mr-x/docs--pre-text (node)
  "Return NODE's text verbatim, trailing whitespace trimmed."
  (and node (string-trim-right (dom-texts node ""))))

(defun mr-x/docs--first-sentence (text)
  "Return TEXT up to and including its first sentence end."
  (if (and text (string-match "\\`\\(.*?[.!?]\\)\\( \\|\\'\\)" text))
      (match-string 1 text)
    text))

(defun mr-x/docs--direct-child (node tag)
  "Return NODE's first direct child element with TAG."
  (seq-find (lambda (c) (and (consp c) (eq (dom-tag c) tag))) (dom-children node)))

;;; Extractors
;; Each takes (DOM ANCHOR-NODE ENTRY) and returns a plist with :title
;; :blurb :synopsis :examples :params.  ANCHOR-NODE is nil for page-level
;; entries and for anchors the page no longer carries.

(defun mr-x/docs--extract-mdn (dom _anchor _entry)
  "Extractor for MDN pages (javascript, dom, html, css docsets)."
  (let* ((h1 (car (dom-by-tag dom 'h1)))
         (blurb (car (dom-by-tag (car (dom-by-class dom "\\`content-section\\'")) 'p)))
         (syntax (mr-x/docs--by-id dom "syntax"))
         (sig (and syntax (mr-x/docs--first-after dom syntax (mr-x/docs--tag-p 'pre)
                                                  (mr-x/docs--tag-p 'h2))))
         (params-h (mr-x/docs--by-id dom "parameters"))
         (dl (and params-h (mr-x/docs--direct-child (dom-parent dom params-h) 'dl)))
         (examples-h (mr-x/docs--by-id dom "examples"))
         (examples
          ;; Each example is its own <section>: an h3 then a pre, siblings of
          ;; the Examples heading's section, running until the next h2.
          (when examples-h
            (let (acc (n 0) (seen nil))
              (cl-block scan
                (dolist (node (mr-x/docs--nodes dom))
                  (cond ((eq node examples-h) (setq seen t))
                        ((not seen))
                        ((eq (dom-tag node) 'h2) (cl-return-from scan))
                        ((and (eq (dom-tag node) 'h3) (< n 3))
                         (let ((pre (mr-x/docs--first-after dom node (mr-x/docs--tag-p 'pre)
                                                            (mr-x/docs--tag-p '(h2 h3)))))
                           (when pre
                             (cl-incf n)
                             (push (cons (mr-x/docs--text node) (mr-x/docs--pre-text pre))
                                   acc)))))))
              (nreverse acc)))))
    (list :title (mr-x/docs--text h1)
          :blurb (mr-x/docs--text blurb)
          :synopsis (mr-x/docs--pre-text sig)
          :params (when dl
                    (let (acc name)
                      (dolist (c (dom-children dl) (nreverse acc))
                        (when (consp c)
                          (pcase (dom-tag c)
                            ('dt (setq name (mr-x/docs--text c)))
                            ('dd (let* ((optional (and name (string-suffix-p " Optional" name)))
                                        (desc (mr-x/docs--first-sentence
                                               (mr-x/docs--text (or (car (dom-by-tag c 'p)) c)))))
                                   (push (list (if optional (string-remove-suffix " Optional" name) name)
                                               desc (and optional t))
                                         acc))))))))
          :examples examples)))

(defun mr-x/docs--extract-python (dom anchor entry)
  "Extractor for Sphinx pages (python docset)."
  (if (null anchor)
      (mr-x/docs--extract-fallback dom nil entry)
    (let* ((dd (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'dd)))
           (p (and dd (car (dom-by-tag dd 'p))))
           (pres (and dd (seq-take (dom-by-tag dd 'pre) 3))))
      (list :title (plist-get entry :name)
            :blurb (mr-x/docs--text p)
            :synopsis (replace-regexp-in-string "¶" "" (mr-x/docs--text anchor))
            :examples (mapcar (lambda (pre) (cons "Example" (mr-x/docs--pre-text pre))) pres)
            :params nil))))

(defun mr-x/docs--extract-go (dom anchor entry)
  "Extractor for Go package pages (go docset)."
  (if (null anchor)
      (mr-x/docs--extract-fallback dom nil entry)
    (let* ((heading (mr-x/docs--tag-p '(h2 h3)))
           (pre (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'pre) heading))
           (p (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'p) heading))
           (ex-h (mr-x/docs--by-id dom (concat "example_" (dom-attr anchor 'id))))
           (code (and ex-h (mr-x/docs--first-after dom ex-h (mr-x/docs--tag-p 'pre) heading)))
           (out (and code (mr-x/docs--first-after dom code (mr-x/docs--tag-p 'pre) heading))))
      (list :title (plist-get entry :name)
            :blurb (mr-x/docs--text p)
            :synopsis (mr-x/docs--pre-text pre)
            :examples (and code
                           (list (cons "Example"
                                       (concat (mr-x/docs--pre-text code)
                                               (and out (concat "\n// Output: "
                                                                (mr-x/docs--pre-text out)))))))
            :params nil))))

(defun mr-x/docs--extract-fallback (dom anchor entry)
  "Extractor for docset types without a dedicated one: title and first paragraph."
  (let ((p (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'p))))
    (list :title (or (and (not anchor) (mr-x/docs--text (car (dom-by-tag dom 'h1))))
                     (plist-get entry :name))
          :blurb (or (mr-x/docs--text p) "")
          :synopsis nil :examples nil :params nil)))

(defvar mr-x/docs-extractors
  '(("mdn" . mr-x/docs--extract-mdn)
    ("python" . mr-x/docs--extract-python)
    ("go" . mr-x/docs--extract-go))
  "Alist of docset TYPE (from its metadata) to extractor function.")

(defun mr-x/docs--url (entry)
  "Return ENTRY's page on devdocs.io."
  (concat "https://devdocs.io/" (plist-get entry :slug) "/" (plist-get entry :path)
          (and (plist-get entry :anchor) (concat "#" (plist-get entry :anchor)))))

(defun mr-x/docs--digest (entry)
  "Return the digest plist for ENTRY: the extractor's plist plus :docset and :url."
  (let* ((slug (plist-get entry :slug))
         (type (cdr (assoc slug (mr-x/docs--docsets))))
         (extract (or (cdr (assoc type mr-x/docs-extractors)) #'mr-x/docs--extract-fallback))
         (dom (mr-x/docs--page slug (plist-get entry :path)))
         (anchor (and (plist-get entry :anchor) (mr-x/docs--by-id dom (plist-get entry :anchor))))
         (pl (funcall extract dom anchor entry)))
    (append pl (list :docset slug :url (mr-x/docs--url entry)))))

;;; Faces

(defgroup mr-x/docs nil "One-key DevDocs lookup." :group 'mr-x)

(defface mr-x/docs-title '((t :weight bold)) "Entry name on the title line." :group 'mr-x/docs)
(defface mr-x/docs-heading '((t :weight bold)) "Section headings." :group 'mr-x/docs)
(defface mr-x/docs-synopsis '((t)) "Signature lines." :group 'mr-x/docs)
(defface mr-x/docs-param '((t :weight bold)) "Parameter names." :group 'mr-x/docs)
(defface mr-x/docs-code '((t)) "Example code." :group 'mr-x/docs)
(defface mr-x/docs-description '((t)) "Prose." :group 'mr-x/docs)
(defface mr-x/docs-docset '((t :slant italic)) "Docset tag on the title line." :group 'mr-x/docs)
(defface mr-x/docs-optional '((t :inherit shadow)) "The [optional] marker." :group 'mr-x/docs)

(defconst mr-x/docs--palette
  '((mr-x/docs-title    . ansi-color-magenta)
    (mr-x/docs-heading  . ansi-color-magenta)
    (mr-x/docs-synopsis . ansi-color-cyan)
    (mr-x/docs-code     . ansi-color-cyan)
    (mr-x/docs-param    . ansi-color-yellow)
    (mr-x/docs-docset   . ansi-color-green))
  "Which ANSI colour each docs face borrows; the same palette as `mr-x/tldr'.")

(defun mr-x/docs--sync-faces ()
  "Point the docs faces at the current theme's ANSI colours (foreground only)."
  (pcase-dolist (`(,face . ,ansi) mr-x/docs--palette)
    (set-face-foreground face (face-foreground ansi nil t))))

;;; Rendering

(defvar-local mr-x/docs--entry nil
  "The entry plist this `*docs*' buffer describes.")

(defvar-local mr-x/docs--full-shown nil
  "Position of the full page once appended to this buffer, else nil.")

(defun mr-x/docs--ins (text face)
  (insert (propertize text 'face face)))

(defun mr-x/docs--heading (name)
  (mr-x/docs--ins (concat name "\n") 'mr-x/docs-heading))

(defun mr-x/docs--wrap-synopsis (line width)
  "Split LINE after commas so no piece exceeds WIDTH, continuing under the open paren."
  (if (<= (length line) width)
      (list line)
    (let* ((paren (string-search "(" line))
           (indent (make-string (if paren (1+ paren) 4) ?\s))
           (pieces nil)
           (current ""))
      (dolist (part (split-string line ", "))
        (let ((candidate (if (string-empty-p current) part (concat current ", " part))))
          (if (and (not (string-empty-p current))
                   (> (+ (length indent) (length candidate)) width))
              (progn (push (concat current ",") pieces)
                     (setq current (concat indent part)))
            (setq current candidate))))
      (push current pieces)
      (nreverse pieces))))

(defun mr-x/docs--fill (text width)
  "Return TEXT filled to WIDTH columns, keeping its existing line breaks."
  (with-temp-buffer
    (insert text)
    (let ((fill-column width))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((end (line-end-position)))
          (fill-region-as-paragraph (line-beginning-position) end)
          (forward-line 1))))
    (buffer-string)))

(defun mr-x/docs--render (pl)
  "Insert the digest PL at point using the `*tldr*' layout."
  (let* ((title (or (plist-get pl :title) ""))
         (docset (or (plist-get pl :docset) ""))
         (width (- (if (window-live-p (selected-window)) (window-width) 80) 4)))
    (insert "\n  ")
    (mr-x/docs--ins title 'mr-x/docs-title)
    (insert (make-string (max 1 (- 70 (length title) (length docset))) ?\s))
    (mr-x/docs--ins (concat docset "\n") 'mr-x/docs-docset)
    ;; HTML prose carries no line breaks of its own (unlike tldr markdown),
    ;; so the blurb is filled to 70 columns; existing breaks are kept.
    (dolist (line (split-string (mr-x/docs--fill (or (plist-get pl :blurb) "") 70) "\n"))
      (mr-x/docs--ins (concat "  " line "\n") 'mr-x/docs-description))
    (when (plist-get pl :synopsis)
      (insert "\n")
      (mr-x/docs--heading "SYNOPSIS")
      (dolist (line (split-string (plist-get pl :synopsis) "\n"))
        (dolist (piece (mr-x/docs--wrap-synopsis line width))
          (mr-x/docs--ins (concat "  " piece "\n") 'mr-x/docs-synopsis))))
    (when (plist-get pl :examples)
      (insert "\n")
      (mr-x/docs--heading "EXAMPLES")
      (let ((first t))
        (pcase-dolist (`(,label . ,code) (plist-get pl :examples))
          (unless first (insert "\n"))
          (setq first nil)
          (mr-x/docs--ins (concat "  " label ":") 'mr-x/docs-description)
          (insert "\n\n")
          (dolist (line (split-string code "\n"))
            (mr-x/docs--ins (concat (if (string-empty-p line) "" (concat "    " line)) "\n")
                            'mr-x/docs-code)))))
    (when (plist-get pl :params)
      (insert "\n")
      (mr-x/docs--heading "PARAMETERS")
      (let ((w (apply #'max (mapcar (lambda (p) (length (car p))) (plist-get pl :params)))))
        (pcase-dolist (`(,name ,desc ,optional) (plist-get pl :params))
          (mr-x/docs--ins (concat "  " name (make-string (+ 3 (- w (length name))) ?\s))
                          'mr-x/docs-param)
          (mr-x/docs--ins (or desc "") 'mr-x/docs-description)
          (when optional (mr-x/docs--ins " [optional]" 'mr-x/docs-optional))
          (insert "\n"))))))

(define-derived-mode mr-x/docs-mode special-mode "docs"
  "Major mode for the `*docs*' digest buffer.")

;;; Commands

(defun mr-x/docs-show-full ()
  "Append the full page below the digest, or jump to it if already shown."
  (interactive)
  (cond
   (mr-x/docs--full-shown
    (goto-char mr-x/docs--full-shown)
    (recenter 0))
   (t
    (let* ((entry mr-x/docs--entry)
           (dom (mr-x/docs--page (plist-get entry :slug) (plist-get entry :path)))
           (inhibit-read-only t)
           (start nil))
      (require 'devdocs nil t)              ; its shr face overrides, when installed
      (require 'shr)
      (goto-char (point-max))
      (insert "\n" (make-string 70 ?─) "\n\n")
      (setq start (point))
      (let ((shr-max-width 90)
            (shr-use-fonts nil)
            (shr-bullet "  • "))
        (shr-insert-document dom))
      (setq mr-x/docs--full-shown start)
      (goto-char start)
      (recenter 0)))))

(defun mr-x/docs-open ()
  "Open this entry on devdocs.io in the agent browser."
  (interactive)
  (unless mr-x/docs--entry (user-error "No docs entry in this buffer"))
  (start-process "agent-open" nil "agent-open" (mr-x/docs--url mr-x/docs--entry)))

(let ((map mr-x/docs-mode-map))
  (define-key map (kbd "m") #'mr-x/docs-show-full)
  (define-key map (kbd "o") #'mr-x/docs-open))

(with-eval-after-load 'evil
  (evil-define-key 'normal mr-x/docs-mode-map
    (kbd "m") #'mr-x/docs-show-full
    (kbd "o") #'mr-x/docs-open))

;;;###autoload
(defun mr-x/docs (entry)
  "Look up ENTRY in the installed DevDocs docsets and show its digest.
Interactively, complete over every entry of every docset, prefilled with
the symbol at point.  In the `*docs*' buffer, `m' appends the full page
and `o' opens the entry on devdocs.io."
  (interactive (list (mr-x/docs--read (thing-at-point 'symbol t))))
  (let ((pl (mr-x/docs--digest entry)))
    (mr-x/docs--sync-faces)
    (with-current-buffer (get-buffer-create "*docs*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (mr-x/docs--render pl)
        (mr-x/docs-mode)
        (setq mr-x/docs--entry entry
              mr-x/docs--full-shown nil)
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

(provide 'mr-x-docs)
;;; mr-x-docs.el ends here
