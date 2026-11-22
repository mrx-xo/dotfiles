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
(require 'mr-x-docs-usage)

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

(defun mr-x/docs--sort-candidates (strings slug-of preferred)
  "Order STRINGS: docsets in PREFERRED first, then shorter names, then alphabetical.
SLUG-OF maps a candidate string to its docset slug."
  (sort (copy-sequence strings)
        (lambda (a b)
          (let ((pa (if (member (funcall slug-of a) preferred) 0 1))
                (pb (if (member (funcall slug-of b) preferred) 0 1)))
            (cond ((/= pa pb) (< pa pb))
                  ((/= (length a) (length b)) (< (length a) (length b)))
                  (t (string< a b)))))))

(defun mr-x/docs--symbol-at-point ()
  "Return the qualified name at point when some entry contains it, else the bare symbol.
`os.Open' and `json.loads' are indexed qualified; `rows.map' is not, so the
receiver is dropped and `map' is searched."
  (when-let* ((bounds (bounds-of-thing-at-point 'symbol))
              (bare (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (let* ((start (save-excursion
                    (goto-char (car bounds))
                    (skip-chars-backward "A-Za-z0-9_.")
                    (point)))
           (qualified (string-trim (buffer-substring-no-properties start (cdr bounds)) "\\."))
           (needle (downcase qualified)))
      (if (and (not (equal qualified bare))
               (seq-some (lambda (c) (string-search needle (downcase (car c))))
                         (mr-x/docs--candidates)))
          qualified
        bare))))

(defun mr-x/docs--read (initial)
  "Prompt for an entry with INITIAL input and return the chosen entry plist."
  (let* ((cands (mr-x/docs--candidates))
         ;; 28k candidates: every metadata callback must be O(1), not `assoc'.
         (table-hash (let ((h (make-hash-table :test #'equal :size (length cands))))
                       (dolist (c cands h) (puthash (car c) (cdr c) h))))
         (entry (lambda (cand) (gethash cand table-hash)))
         (preferred (mr-x/docs--preferred-slugs))
         (sort (lambda (strings)
                 (mr-x/docs--sort-candidates
                  strings (lambda (s) (plist-get (funcall entry s) :slug)) preferred)))
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

(defun mr-x/docs--mdn-status (dom)
  "Return the MDN baseline and warning status for DOM, or nil."
  (let* ((baseline (seq-find (lambda (n)
                               (and (eq (dom-tag n) 'details)
                                    (string-match-p "baseline-indicator"
                                                    (or (dom-attr n 'class) ""))))
                             (mr-x/docs--nodes dom)))
         (level (and baseline (dom-attr baseline 'class)))
         (span (and baseline
                    (seq-find (lambda (n) (eq (dom-tag n) 'span))
                              (mr-x/docs--nodes baseline))))
         (base (cond ((string-match-p "high" (or level ""))
                      "Baseline: widely available")
                     ((string-match-p "low" (or level ""))
                      "Baseline: newly available")
                     (span "Limited availability")))
         (card (seq-find (lambda (n)
                           (and (eq (dom-tag n) 'div)
                                (or (string-match-p "deprecated"
                                                    (or (dom-attr n 'class) ""))
                                    (string-match-p "experimental"
                                                    (or (dom-attr n 'class) ""))
                                    (string-match-p "warning"
                                                    (or (dom-attr n 'class) "")))))
                         (mr-x/docs--nodes dom)))
         (prefix (and card
                      (cond ((string-match-p "deprecated" (dom-attr card 'class))
                             "Deprecated. ")
                            ((string-match-p "experimental" (dom-attr card 'class))
                             "Experimental. ")
                            (t "Warning. ")))))
    (and base (concat (or prefix "") base))))

(defun mr-x/docs--python-status (dd)
  "Return up to two version status sentences from Python entry DD."
  (when dd
    (let (statuses)
      (dolist (node (dom-by-class dd "\\`version\\(?:added\\|changed\\)\\'"))
        (let ((text (mr-x/docs--text (car (dom-by-tag node 'p)))))
          (when (and text (string-match-p "\\`\\(?:Added\\|Changed\\) in version 3\\." text))
            (push (replace-regexp-in-string "[.!?]\\'" ""
                                            (mr-x/docs--first-sentence text))
                  statuses))))
      (when statuses (string-join (seq-take (nreverse statuses) 2) "; ")))))

(defun mr-x/docs--page-examples (dom call-forms synopsis)
  "Return up to two page PRE examples matching CALL-FORMS.
Skip signature PREs and a PRE equal to SYNOPSIS."
  (let (examples)
    (dolist (pre (dom-by-tag dom 'pre))
      (let ((text (mr-x/docs--pre-text pre)))
        (when (and (< (length examples) 2)
                   (seq-some (lambda (form) (string-search form text)) call-forms)
                   (not (string-prefix-p "func " text))
                   (not (equal text synopsis)))
          (push (cons "Usage on the page" text) examples))))
    (nreverse examples)))

;;; Extractors
;; Each takes (DOM ANCHOR-NODE ENTRY) and returns a plist with :title
;; :blurb :synopsis :examples :params.  ANCHOR-NODE is nil for page-level
;; entries and for anchors the page no longer carries.

(defun mr-x/docs--mdn-lead-paragraph (dom)
  "Return the first top-level <p> of an MDN page outside details/notecards."
  (let ((skip (lambda (n) (and (consp n)
                               (or (eq (dom-tag n) 'details)
                                   (string-match-p "notecard"
                                                   (or (dom-attr n 'class) "")))))))
    (cl-labels ((walk (n)
                  (when (and (consp n) (not (funcall skip n)))
                    (if (eq (dom-tag n) 'p)
                        n
                      (seq-some #'walk (dom-children n))))))
      (walk dom))))

(defconst mr-x/docs--badge-re
  "\\(?: *\\(?:Optional\\|Deprecated\\|Experimental\\|Non-standard\\|Read only\\)\\)+\\'"
  "MDN status badges that trail a dt name.")

(defun mr-x/docs--dl-pairs (dl)
  "Return DL's (NAME . FIRST-SENTENCE) pairs, MDN badges stripped from NAME."
  (let (acc name)
    (dolist (c (dom-children dl) (nreverse acc))
      (when (consp c)
        (pcase (dom-tag c)
          ('dt (setq name (replace-regexp-in-string mr-x/docs--badge-re ""
                                                    (mr-x/docs--text c))))
          ('dd (push (cons name (mr-x/docs--first-sentence
                                 (mr-x/docs--text (or (car (dom-by-tag c 'p)) c))))
                     acc)))))))

(defconst mr-x/docs--mdn-member-sections
  '(("constructor" . "Constructor")
    ("static_properties" . "Static properties")
    ("static_methods" . "Static methods")
    ("instance_properties" . "Instance properties")
    ("instance_methods" . "Instance methods")
    ("attributes" . "Attributes"))
  "MDN heading ids that list members, with the label the digest shows.")

(defun mr-x/docs--mdn-members (dom)
  "Return MDN member groups: a list of (LABEL . ((NAME . DESC) ...))."
  (let (acc)
    (pcase-dolist (`(,id . ,label) mr-x/docs--mdn-member-sections)
      (let* ((h (mr-x/docs--by-id dom id))
             (dl (and h (mr-x/docs--first-after dom h (mr-x/docs--tag-p 'dl)
                                                (mr-x/docs--tag-p 'h2))))
             (pairs (and dl (mr-x/docs--dl-pairs dl))))
        (when pairs (push (cons label pairs) acc))))
    (nreverse acc)))

(defun mr-x/docs--extract-mdn (dom _anchor _entry)
  "Extractor for MDN pages (javascript, dom, html, css docsets)."
  (let* ((h1 (car (dom-by-tag dom 'h1)))
         (blurb (or (car (dom-by-tag (car (dom-by-class dom "\\`content-section\\'")) 'p))
                    ;; dom/html pages have no content-section: take the first
                    ;; paragraph that is not Baseline chrome or a notecard.
                    (mr-x/docs--mdn-lead-paragraph dom)))
         (syntax (mr-x/docs--by-id dom "syntax"))
         (sig (and syntax (mr-x/docs--first-after dom syntax (mr-x/docs--tag-p 'pre)
                                                  (mr-x/docs--tag-p 'h2))))
         (returns-h (mr-x/docs--by-id dom "return_value"))
         (returns (and returns-h (mr-x/docs--first-after dom returns-h (mr-x/docs--tag-p 'p)
                                                         (mr-x/docs--tag-p '(h2 h3)))))
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
          :returns (mr-x/docs--text returns)
          :status (mr-x/docs--mdn-status dom)
          :params (when dl
                    (let (acc name)
                      (dolist (c (dom-children dl) (nreverse acc))
                        (when (consp c)
                          (pcase (dom-tag c)
                            ('dt (setq name (mr-x/docs--text c)))
                            ('dd (let* ((optional (and name (string-match-p " Optional\\b" name)))
                                        (clean (replace-regexp-in-string mr-x/docs--badge-re "" name))
                                        (desc (mr-x/docs--first-sentence
                                               (mr-x/docs--text (or (car (dom-by-tag c 'p)) c)))))
                                   (push (list clean desc (and optional t)) acc))))))))
          :members (mr-x/docs--mdn-members dom)
          :examples examples)))

(defun mr-x/docs--extract-python (dom anchor entry)
  "Extractor for Sphinx pages (python docset)."
  (cond
   ((null anchor)
    ;; A module page: title, lead paragraph, and its functions/classes.
    (let ((p (seq-find (lambda (n) (not (string-prefix-p "Source code:" (mr-x/docs--text n))))
                       (dom-by-tag dom 'p))))
      (list :title (mr-x/docs--text (car (dom-by-tag dom 'h1)))
            :blurb (or (mr-x/docs--text p) "")
            :members (mr-x/docs--python-members dom))))
   ((not (eq (dom-tag anchor) 'dt))
    ;; Section, paragraph and index anchors are prose, not signatures.
    (mr-x/docs--extract-fallback dom anchor entry))
    (t
     (let* ((dd (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'dd)))
            (p (and dd (car (dom-by-tag dd 'p))))
            (pres (and dd (seq-take (dom-by-tag dd 'pre) 3))))
       (list :title (plist-get entry :name)
             :blurb (mr-x/docs--text p)
             :synopsis (replace-regexp-in-string "¶" "" (mr-x/docs--text anchor))
             :status (mr-x/docs--python-status dd)
             :examples (or (mapcar (lambda (pre)
                                     (cons "Example" (mr-x/docs--pre-text pre)))
                                   pres)
                           (mr-x/docs--page-examples
                            dom
                            (let ((id (dom-attr anchor 'id)))
                              (delete-dups
                               (list (concat id "(")
                                     (concat (car (last (split-string id "\\.")))
                                             "("))))
                            (replace-regexp-in-string "¶" ""
                                                      (mr-x/docs--text anchor))))
             :params nil)))))

(defun mr-x/docs--python-members (dom)
  "Return a Sphinx module page's functions, classes and exceptions as member groups."
  (let (acc)
    (pcase-dolist (`(,class . ,label) '(("function" . "Functions") ("class" . "Classes")
                                        ("exception" . "Exceptions")))
      (let (pairs)
        (dolist (dl (dom-by-class dom (concat "\\`py " class "\\'")))
          (let* ((dt (car (dom-by-tag dl 'dt)))
                 (dd (car (dom-by-tag dl 'dd)))
                 (sig (replace-regexp-in-string "¶" "" (mr-x/docs--text dt)))
                 (name (string-remove-prefix
                        "exception " (string-remove-prefix "class " (car (split-string sig "(")))))
                 (name (if (and (equal class "function") (string-search "(" sig))
                           (concat (string-trim name) "()")
                         (string-trim name))))
            (push (cons name (mr-x/docs--first-sentence
                              (mr-x/docs--text (and dd (car (dom-by-tag dd 'p))))))
                  pairs)))
        (when pairs (push (cons label (nreverse pairs)) acc))))
    (nreverse acc)))

(defun mr-x/docs--extract-go (dom anchor entry)
  "Extractor for Go package pages (go docset)."
  (if (null anchor)
      (let* ((nav (mr-x/docs--by-id dom "manual-nav"))
             (items (and nav (mapcar (lambda (li) (cons (mr-x/docs--text li) nil))
                                     (dom-by-tag nav 'li)))))
        (append (mr-x/docs--extract-fallback dom nil entry)
                (and items (list :members (list (cons "Index" items))))))
    (let* ((heading (mr-x/docs--tag-p '(h2 h3)))
           (pre (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'pre) heading))
           (p (mr-x/docs--first-after dom anchor (mr-x/docs--tag-p 'p) heading))
           (ex-h (mr-x/docs--by-id dom (concat "example_" (dom-attr anchor 'id))))
           (code (and ex-h (mr-x/docs--first-after dom ex-h (mr-x/docs--tag-p 'pre) heading)))
           (out (and code (mr-x/docs--first-after dom code (mr-x/docs--tag-p 'pre) heading))))
      (list :title (plist-get entry :name)
            :blurb (mr-x/docs--text p)
             :synopsis (mr-x/docs--pre-text pre)
             :examples (or (and code
                                (list (cons "Example"
                                            (concat (mr-x/docs--pre-text code)
                                                    (and out
                                                         (concat "\n// Output: "
                                                                 (mr-x/docs--pre-text out)))))))
                           (mr-x/docs--page-examples
                            dom
                            (list (concat (string-remove-prefix "Package "
                                                                (mr-x/docs--text
                                                                 (car (dom-by-tag dom 'h1))))
                                          "." (dom-attr anchor 'id) "("))
                            (mr-x/docs--pre-text pre)))
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

(defvar mr-x/docs-member-rows 20
  "How many member rows the digest shows before deferring to `m'.")

(defvar mr-x/docs-example-lines 12
  "How many lines of one example the digest shows before eliding.")

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
           (indent (make-string (min (if paren (1+ paren) 4) (/ width 2)) ?\s))
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

(defconst mr-x/docs--modes
  '(("javascript" js-ts-mode js-mode)
    ("dom" js-ts-mode js-mode)
    ("html" mhtml-mode html-mode)
    ("python" python-ts-mode python-mode)
    ("go" go-ts-mode go-mode))
  "Docset slug prefix -> major modes to try, in order, for fontifying code.")

(defun mr-x/docs--fontify (code slug)
  "Return CODE with the font-lock faces SLUG's language mode gives it.
Unknown slugs, or modes that fail to load, return CODE unchanged."
  (let* ((row (seq-find (lambda (r) (string-prefix-p (car r) (or slug ""))) mr-x/docs--modes))
         (mode (seq-find #'fboundp (cdr row))))
    (if (null mode)
        code
      (condition-case nil
          (with-temp-buffer
            (insert code)
            (delay-mode-hooks (funcall mode))
            (font-lock-ensure)
            (buffer-string))
        (error code)))))

(defun mr-x/docs--ins-code (text face)
  "Insert TEXT.  Fontified text is inserted as is, so punctuation keeps the
default colour exactly as in a source buffer; unfontified text gets FACE."
  (if (text-property-not-all 0 (length text) 'face nil text)
      (insert text)
    (mr-x/docs--ins text face)))

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
    (when (plist-get pl :status)
      (insert "\n")
      (dolist (line (split-string (mr-x/docs--fill (plist-get pl :status) 70) "\n"))
        (mr-x/docs--ins (concat "  " line "\n") 'mr-x/docs-optional)))
    (when (plist-get pl :synopsis)
      (insert "\n")
      (mr-x/docs--heading "SYNOPSIS")
      (dolist (line (split-string (mr-x/docs--fontify (plist-get pl :synopsis) docset) "\n"))
        (dolist (piece (mr-x/docs--wrap-synopsis line width))
          (mr-x/docs--ins-code (concat "  " piece "\n") 'mr-x/docs-synopsis))))
    (when (plist-get pl :returns)
      (insert "\n")
      (mr-x/docs--heading "RETURNS")
      (dolist (line (split-string (mr-x/docs--fill (plist-get pl :returns) 70) "\n"))
        (mr-x/docs--ins (concat "  " line "\n") 'mr-x/docs-description)))
    (when (plist-get pl :members)
      (insert "\n")
      (mr-x/docs--heading "MEMBERS")
      (let ((budget mr-x/docs-member-rows) (total 0) (first t))
        (dolist (group (plist-get pl :members))
          (cl-incf total (length (cdr group))))
        (cl-block groups
          (dolist (group (plist-get pl :members))
            (unless first (insert "\n"))
            (setq first nil)
            (mr-x/docs--ins (concat "  " (car group) ":\n") 'mr-x/docs-description)
            (let ((w (apply #'max (mapcar (lambda (m) (length (car m))) (cdr group)))))
              (dolist (m (cdr group))
                (when (<= budget 0)
                  (mr-x/docs--ins (format "  ... %d more (m)\n" (- total mr-x/docs-member-rows))
                                  'mr-x/docs-optional)
                  (cl-return-from groups))
                (cl-decf budget)
                (mr-x/docs--ins (concat "  " (car m)) 'mr-x/docs-param)
                (when (cdr m)
                  (insert (make-string (+ 3 (- w (length (car m)))) ?\s))
                  ;; One line per member: cut the sentence to the window.
                  (let* ((room (max 10 (- (min width 78) (current-column))))
                         (desc (cdr m)))
                    (mr-x/docs--ins (if (> (length desc) room)
                                        (concat (substring desc 0 (1- room)) "…")
                                      desc)
                                    'mr-x/docs-description)))
                (put-text-property (line-beginning-position) (point) 'mr-x/docs-member (car m))
                (insert "\n")))))))
    (when (plist-get pl :examples)
      (insert "\n")
      (mr-x/docs--heading "EXAMPLES")
      (let ((first t))
        (pcase-dolist (`(,label . ,code) (plist-get pl :examples))
          (unless first (insert "\n"))
          (setq first nil)
          (mr-x/docs--ins (concat "  " label ":") 'mr-x/docs-description)
          (insert "\n\n")
          (let ((lines (split-string (mr-x/docs--fontify code docset) "\n")))
            (dolist (line (seq-take lines mr-x/docs-example-lines))
              (mr-x/docs--ins-code (concat (if (string-empty-p line) "" (concat "    " line)) "\n")
                                   'mr-x/docs-code))
            (when (> (length lines) mr-x/docs-example-lines)
              (mr-x/docs--ins "    ...\n" 'mr-x/docs-optional))))))
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

(defun mr-x/docs--member-entry (name slug title)
  "Return the entry a MEMBERS row NAME refers to, preferring docset SLUG.
TITLE is the current page title, used to qualify Go index lines
\"func Clone(...)\" as \"strings.Clone()\".  Nil when nothing matches."
  (let* ((bare (if (string-match "\\`func \\(?:([^)]*) \\)?\\([A-Za-z0-9_]+\\)" name)
                   (concat (string-remove-prefix "Package " title) "." (match-string 1 name) "()")
                 name))
         (variants (delete-dups
                    (list bare
                          (string-remove-suffix "()" bare)
                          (concat (string-remove-suffix "()" bare) "()"))))
         (hits (seq-filter (lambda (e) (member (plist-get e :name) variants))
                           (mr-x/docs--entries))))
    (or (seq-find (lambda (e) (equal (plist-get e :slug) slug)) hits)
        (car hits))))

(cl-defun mr-x/docs-follow ()
  "Look up the member on this line, or visit the usage hit on this line."
  (interactive)
  (when (get-text-property (line-beginning-position) 'mr-x/docs-usage)
    (cl-return-from mr-x/docs-follow (mr-x/docs-visit-usage)))
  (let ((name (get-text-property (line-beginning-position) 'mr-x/docs-member)))
    (unless name (user-error "Not on a member or usage row"))
    (let ((entry (mr-x/docs--member-entry name (plist-get mr-x/docs--entry :slug)
                                          (save-excursion (goto-char (point-min))
                                                          (forward-line 1)
                                                          (string-trim (car (split-string (thing-at-point 'line t) "  +" t)))))))
      (unless entry (user-error "No docs entry for %s" name))
      (mr-x/docs entry))))

(defun mr-x/docs-open ()
  "Open this entry on devdocs.io in the agent browser."
  (interactive)
  (unless mr-x/docs--entry (user-error "No docs entry in this buffer"))
  (start-process "agent-open" nil "agent-open" (mr-x/docs--url mr-x/docs--entry)))

(let ((map mr-x/docs-mode-map))
  (define-key map (kbd "m") #'mr-x/docs-show-full)
  (define-key map (kbd "o") #'mr-x/docs-open)
  (define-key map (kbd "RET") #'mr-x/docs-follow))

(with-eval-after-load 'evil
  (evil-define-key 'normal mr-x/docs-mode-map
    (kbd "m") #'mr-x/docs-show-full
    (kbd "o") #'mr-x/docs-open
    (kbd "RET") #'mr-x/docs-follow))

;;;###autoload
(defun mr-x/docs (entry)
  "Look up ENTRY in the installed DevDocs docsets and show its digest.
Interactively, complete over every entry of every docset, prefilled with
the symbol at point.  In the `*docs*' buffer, `m' appends the full page
and `o' opens the entry on devdocs.io."
  (interactive (list (mr-x/docs--read (mr-x/docs--symbol-at-point))))
  (let ((pl (mr-x/docs--digest entry))
        (usage (mr-x/docs--usage-for entry))   ; from the caller's project
        (root (mr-x/docs-usage-root)))
    (mr-x/docs--sync-faces)
    (with-current-buffer (get-buffer-create "*docs*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (mr-x/docs--render pl)
        (when usage (mr-x/docs--render-usage (car usage) (cdr usage)))
        (mr-x/docs-mode)
        (setq mr-x/docs--entry entry
              mr-x/docs--full-shown nil
              mr-x/docs--usage-root root)
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

;;; Project usage

(defun mr-x/docs--render-usage (usage project)
  "Insert the USAGE section for USAGE (from `mr-x/docs-usage') in PROJECT.
Inserts nothing when there are no hits."
  (when (and usage (> (plist-get usage :count) 0))
    (insert "\n")
    (mr-x/docs--ins (format "USAGE  %d hit%s in %d file%s (project: %s)\n"
                            (plist-get usage :count)
                            (if (= 1 (plist-get usage :count)) "" "s")
                            (plist-get usage :files)
                            (if (= 1 (plist-get usage :files)) "" "s")
                            project)
                    'mr-x/docs-heading)
    (let* ((locs (mapcar (lambda (h) (format "%s:%d" (car h) (cadr h))) (plist-get usage :hits)))
           (w (apply #'max (mapcar #'length locs))))
      (cl-loop for hit in (plist-get usage :hits)
               for loc in locs
               do (let ((start (point)))
                    (mr-x/docs--ins (concat "  " loc (make-string (+ 2 (- w (length loc))) ?\s))
                                    'mr-x/docs-param)
                    (mr-x/docs--ins (concat (nth 2 hit) "\n") 'mr-x/docs-description)
                    (put-text-property start (point) 'mr-x/docs-usage
                                       (list (car hit) (cadr hit))))))))

(defun mr-x/docs--usage-for (entry)
  "Return (USAGE . PROJECT-NAME) for ENTRY in the current project, or nil."
  (when-let* ((root (mr-x/docs-usage-root))
              (pattern (mr-x/docs-usage-pattern (plist-get entry :name) (plist-get entry :slug)))
              (usage (ignore-errors (mr-x/docs-usage-search pattern root))))
    (cons usage (file-name-nondirectory (directory-file-name root)))))

(defun mr-x/docs-visit-usage ()
  "Jump to the project file and line of the USAGE row at point."
  (interactive)
  (let ((loc (get-text-property (line-beginning-position) 'mr-x/docs-usage)))
    (unless loc (user-error "Not on a usage row"))
    (find-file-other-window (expand-file-name (car loc) mr-x/docs--usage-root))
    (goto-char (point-min))
    (forward-line (1- (cadr loc)))))

(defvar-local mr-x/docs--usage-root nil
  "Project root the USAGE rows of this buffer are relative to.")

(provide 'mr-x-docs)
;;; mr-x-docs.el ends here
