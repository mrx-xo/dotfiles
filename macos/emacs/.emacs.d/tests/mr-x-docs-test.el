;;; mr-x-docs-test.el --- Tests for mr-x-docs -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name "../lisp" (file-name-directory
                                                     (or load-file-name buffer-file-name))))
(require 'mr-x-docs)

(defmacro mr-x-docs-test--with-data (&rest body)
  "Run BODY with `mr-x/docs-data-dir' pointing at a temp tree holding one docset."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "docs-test" t))
          (mr-x/docs-data-dir (file-name-as-directory dir))
          (mr-x/docs--cache nil))
     (make-directory (expand-file-name "fake" dir))
     (with-temp-file (expand-file-name "fake/metadata" dir)
       (prin1 '((name . "Fake") (slug . "fake") (type . "mdn")) (current-buffer)))
     (with-temp-file (expand-file-name "fake/index" dir)
       (prin1 '((pages . ["a" "b/c"])
                (entries . [((name . "alpha") (path . "a") (type . "T"))
                            ((name . "beta.c()") (path . "b/c#c") (type . "T"))]))
              (current-buffer)))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest mr-x-docs-test-docsets ()
  (mr-x-docs-test--with-data
    (should (equal (mr-x/docs--docsets) '(("fake" . "mdn"))))))

(ert-deftest mr-x-docs-test-entries-split-anchor ()
  (mr-x-docs-test--with-data
    (let ((e (seq-find (lambda (e) (equal (plist-get e :name) "beta.c()"))
                       (mr-x/docs--entries))))
      (should (equal (plist-get e :path) "b/c"))
      (should (equal (plist-get e :anchor) "c"))
      (should (equal (plist-get e :slug) "fake"))
      (should (null (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "alpha"))
                                          (mr-x/docs--entries))
                               :anchor))))))

(ert-deftest mr-x-docs-test-candidates-unique ()
  (mr-x-docs-test--with-data
    (with-temp-file (expand-file-name "fake/index" mr-x/docs-data-dir)
      (prin1 '((pages . ["a" "b"])
               (entries . [((name . "same") (path . "a") (type . "T"))
                           ((name . "same") (path . "b") (type . "T"))]))
             (current-buffer)))
    (let ((cands (mr-x/docs--candidates)))
      (should (= 2 (length cands)))
      (should (= 2 (length (delete-dups (mapcar #'car cands)))))
      (should (equal "same" (substring-no-properties (car (car cands)) 0 4))))))

(ert-deftest mr-x-docs-test-preferred-slugs ()
  (with-temp-buffer
    (python-mode)
    (should (equal (mr-x/docs--preferred-slugs) '("python~3.12"))))
  (with-temp-buffer
    (fundamental-mode)
    (should (null (mr-x/docs--preferred-slugs)))))

(defun mr-x-docs-test--fixture (name)
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "fixtures/docs/" name)
                       (file-name-directory (or load-file-name buffer-file-name
                                                (expand-file-name "tests/x")))))
    (libxml-parse-html-region (point-min) (point-max))))

(ert-deftest mr-x-docs-test-extract-mdn ()
  (let ((pl (mr-x/docs--extract-mdn (mr-x-docs-test--fixture "mdn-array-map.html") nil nil)))
    (should (equal (plist-get pl :title) "Array.prototype.map()"))
    (should (string-prefix-p "The map() method" (plist-get pl :blurb)))
    (should (equal (plist-get pl :synopsis) "map(callbackFn)\nmap(callbackFn, thisArg)"))
    (should (equal (mapcar #'car (plist-get pl :params)) '("callbackFn" "thisArg")))
    (should (equal (nth 2 (nth 1 (plist-get pl :params))) t))
    (should (equal (car (car (plist-get pl :examples)))
                   "Mapping an array of numbers to an array of square roots"))
    (should (<= (length (plist-get pl :examples)) 3))))

(ert-deftest mr-x-docs-test-extract-python ()
  (let* ((dom (mr-x-docs-test--fixture "python-json.html"))
         (pl (mr-x/docs--extract-python dom (mr-x/docs--by-id dom "json.loads")
                                        '(:name "json.loads()"))))
    (should (string-prefix-p "json.loads(s, *, cls=None" (plist-get pl :synopsis)))
    (should (string-prefix-p "Identical to load()" (plist-get pl :blurb)))
    (should (null (plist-get pl :examples)))))

(ert-deftest mr-x-docs-test-extract-go ()
  (let* ((dom (mr-x-docs-test--fixture "go-strings.html"))
         (pl (mr-x/docs--extract-go dom (mr-x/docs--by-id dom "Fields")
                                    '(:name "strings.Fields()"))))
    (should (equal (plist-get pl :synopsis) "func Fields(s string) []string"))
    (should (string-prefix-p "Fields splits" (plist-get pl :blurb)))
    (should (string-match-p "Output: Fields are" (cdr (car (plist-get pl :examples)))))))

(ert-deftest mr-x-docs-test-digest-missing-anchor-and-unknown-type ()
  (let ((dom (mr-x-docs-test--fixture "mdn-array-map.html")))
    (cl-letf (((symbol-function 'mr-x/docs--page) (lambda (&rest _) dom))
              ((symbol-function 'mr-x/docs--docsets) (lambda () '(("x" . "weird")))))
      (let ((pl (mr-x/docs--digest '(:name "n" :path "p" :anchor "nope" :slug "x"))))
        (should (equal (plist-get pl :url) "https://devdocs.io/x/p#nope"))
        (should (stringp (plist-get pl :blurb)))))))

(defun mr-x-docs-test--render (pl)
  (with-temp-buffer (mr-x/docs--render pl)
                    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest mr-x-docs-test-render-layout ()
  (let ((out (mr-x-docs-test--render
              '(:title "f()" :docset "go" :blurb "Does a thing.\nSecond line."
                :synopsis "func f()" :examples (("Basic" . "f()"))
                :params (("x" "An x" nil) ("why" "A y" t))))))
    (should (string-match-p "^  f() +go\n  Does a thing.\n  Second line.\n\nSYNOPSIS\n  func f()\n\nEXAMPLES\n  Basic:\n\n    f()\n\nPARAMETERS\n  x     An x\n  why   A y \\[optional\\]\n" out))))

(ert-deftest mr-x-docs-test-render-omits-empty-sections ()
  (let ((out (mr-x-docs-test--render '(:title "t" :docset "d" :blurb "b"))))
    (should-not (string-match-p "SYNOPSIS\\|EXAMPLES\\|PARAMETERS" out))))

(ert-deftest mr-x-docs-test-render-wraps-long-synopsis ()
  (let ((out (mr-x-docs-test--render
              (list :title "t" :docset "d" :blurb "b"
                    :synopsis (concat "json.loads(" (make-string 90 ?a) ", b=None)")))))
    (should (string-match-p "\n             " out))))

(ert-deftest mr-x-docs-test-full-page-once ()
  (let ((dom (mr-x-docs-test--fixture "mdn-array-map.html")))
    (cl-letf (((symbol-function 'mr-x/docs--page) (lambda (&rest _) dom))
              ((symbol-function 'mr-x/docs--docsets) (lambda () '(("javascript" . "mdn")))))
      (save-window-excursion
        (mr-x/docs '(:name "Array.prototype.map()" :path "global_objects/array/map"
                     :anchor nil :slug "javascript"))
        (with-current-buffer "*docs*"
          (should (eq major-mode 'mr-x/docs-mode))
          (mr-x/docs-show-full)
          (let ((len (buffer-size)))
            (should (> len 1000))
            (mr-x/docs-show-full)
            (should (= len (buffer-size)))
            (should (= (point) mr-x/docs--full-shown))))
        (kill-buffer "*docs*")))))

(ert-deftest mr-x-docs-test-open-uses-agent-open ()
  (let (called)
    (cl-letf (((symbol-function 'start-process)
               (lambda (&rest args) (setq called args) nil)))
      (with-temp-buffer
        (mr-x/docs-mode)
        (setq mr-x/docs--entry '(:slug "go" :path "strings/index" :anchor "Fields"))
        (mr-x/docs-open)
        (should (equal called '("agent-open" nil "agent-open"
                                "https://devdocs.io/go/strings/index#Fields")))))))

(ert-deftest mr-x-docs-test-read-with-nil-initial ()
  (mr-x-docs-test--with-data
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest args) (ignore args) "alpha")))
      (should (equal (plist-get (mr-x/docs--read nil) :name) "alpha")))))

(ert-deftest mr-x-docs-test-render-fills-long-blurb ()
  (let ((out (mr-x-docs-test--render
              (list :title "t" :docset "d"
                    :blurb (mapconcat #'identity (make-list 30 "word") " ")))))
    (should (string-match-p "^  word\\( word\\)+\n  word" out))
    (should-not (seq-some (lambda (l) (> (length l) 72)) (split-string out "\n")))))

(ert-deftest mr-x-docs-test-extract-mdn-blurb-outside-content-section ()
  "DOM and HTML pages have no section.content-section: the blurb is the
first paragraph outside the Baseline details and the notecards."
  (let ((pl (mr-x/docs--extract-mdn (mr-x-docs-test--fixture "dom-abort.html") nil nil)))
    (should (string-prefix-p "The abort() method of the AbortController" (plist-get pl :blurb)))))

(ert-deftest mr-x-docs-test-extract-python-section-anchor ()
  "A Python anchor on a <section> is prose, not a signature: title and
first paragraph only, no synopsis."
  (let* ((dom (mr-x-docs-test--fixture "python-venv.html"))
         (pl (mr-x/docs--extract-python dom (mr-x/docs--by-id dom "managing-packages-with-pip")
                                        '(:name "12.3. Managing Packages with pip"))))
    (should (null (plist-get pl :synopsis)))
    (should (string-prefix-p "You can install" (plist-get pl :blurb)))))

(ert-deftest mr-x-docs-test-wrap-synopsis-caps-indent ()
  (let* ((line (concat (make-string 60 ?x) "(" (make-string 30 ?a) ", " (make-string 30 ?b) ")"))
         (pieces (mr-x/docs--wrap-synopsis line 76)))
    (should (> (length pieces) 1))
    (should (<= (length (car (split-string (nth 1 pieces) "[^ ]" t))) 38))))

;;; MEMBERS, RETURNS, example cap

(ert-deftest mr-x-docs-test-members-mdn ()
  (let* ((pl (mr-x/docs--extract-mdn (mr-x-docs-test--fixture "mdn-intl.html") nil nil))
         (members (plist-get pl :members)))
    (should (equal (mapcar #'car members) '("Static properties" "Static methods")))
    (should (equal (car (car (cdr (nth 1 members)))) "Intl.getCanonicalLocales()"))
    (should (equal (cdr (car (cdr (nth 1 members)))) "Returns canonical locale names."))))

(ert-deftest mr-x-docs-test-members-python-module ()
  (let* ((pl (mr-x/docs--extract-python (mr-x-docs-test--fixture "python-json-module.html") nil
                                        '(:name "json"))))
    (should (string-prefix-p "JSON (JavaScript Object Notation)" (plist-get pl :blurb)))
    (should (equal (car (car (plist-get pl :members))) "Functions"))
    (should (equal (car (car (cdr (car (plist-get pl :members))))) "json.dump()"))))

(ert-deftest mr-x-docs-test-members-go-package ()
  (let* ((pl (mr-x/docs--extract-go (mr-x-docs-test--fixture "go-strings-index.html") nil
                                    '(:name "strings"))))
    (should (string-prefix-p "Package strings implements" (plist-get pl :blurb)))
    (should (equal (car (car (plist-get pl :members))) "Index"))
    (should (equal (car (car (cdr (car (plist-get pl :members))))) "func Clone(s string) string"))))

(ert-deftest mr-x-docs-test-members-html-attributes ()
  (let* ((pl (mr-x/docs--extract-mdn (mr-x-docs-test--fixture "html-input.html") nil nil))
         (group (car (plist-get pl :members))))
    (should (equal (car group) "Attributes"))
    (should (equal (car (car (cdr group))) "accept"))))

(ert-deftest mr-x-docs-test-returns-mdn ()
  (let ((pl (mr-x/docs--extract-mdn (mr-x-docs-test--fixture "mdn-array-map.html") nil nil)))
    (should (string-prefix-p "A new array with each element" (plist-get pl :returns)))))

(ert-deftest mr-x-docs-test-render-members-and-returns ()
  (let ((out (mr-x-docs-test--render
              (list :title "T" :docset "d" :blurb "b" :synopsis "f(x)"
                    :returns "A thing."
                    :members (list (cons "Static methods"
                                         (cl-loop for i from 1 to 25
                                                  collect (cons (format "m%d()" i) "Does m."))))))))
    (should (string-match-p "SYNOPSIS\n  f(x)\n\nRETURNS\n  A thing.\n\nMEMBERS\n  Static methods:\n  m1()    Does m.\n" out))
    (should (string-match-p "\n  ... 5 more (m)\n" out))
    (should-not (string-match-p "m21()" out))))

(ert-deftest mr-x-docs-test-render-caps-example-lines ()
  (let ((out (mr-x-docs-test--render
              (list :title "T" :docset "d" :blurb "b"
                    :examples (list (cons "Long" (mapconcat (lambda (i) (format "line%d" i))
                                                            (number-sequence 1 30) "\n")))))))
    (should (string-match-p "    line12\n    ...\n" out))
    (should-not (string-match-p "line13" out))))

(ert-deftest mr-x-docs-test-follow-member-resolves-name-variants ()
  "RET on a member row finds the entry whether the index name has () or not,
and maps a Go index line to pkg.Name()."
  (let ((entries '((:name "Intl.getCanonicalLocales" :slug "javascript" :path "x")
                   (:name "strings.Clone()" :slug "go" :path "strings/index" :anchor "Clone"))))
    (cl-letf (((symbol-function 'mr-x/docs--entries) (lambda () entries)))
      (should (equal (plist-get (mr-x/docs--member-entry "Intl.getCanonicalLocales()" "javascript" "Intl") :name)
                     "Intl.getCanonicalLocales"))
      (should (equal (plist-get (mr-x/docs--member-entry "func Clone(s string) string" "go" "Package strings") :name)
                     "strings.Clone()"))
      (should (null (mr-x/docs--member-entry "nothing" "go" "x"))))))

(ert-deftest mr-x-docs-test-members-strip-read-only-and-truncate ()
  (let ((out (mr-x-docs-test--render
              (list :title "T" :docset "d" :blurb "b"
                    :members (list (cons "Instance properties"
                                         (list (cons "origin" (make-string 200 ?x))
                                               (cons "hash" "short"))))))))
    (should (string-match-p "\n  origin   x+…\n" out))
    (should-not (seq-some (lambda (l) (> (length l) 80)) (split-string out "\n")))))

(ert-deftest mr-x-docs-test-dl-pairs-strip-badges ()
  (let* ((dom (with-temp-buffer
                (insert "<dl><dt><code>origin</code> <span>Read only</span></dt><dd><p>A.</p></dd>"
                        "<dt><code>x</code> Optional Deprecated</dt><dd><p>B.</p></dd></dl>")
                (libxml-parse-html-region (point-min) (point-max))))
         (pairs (mr-x/docs--dl-pairs (car (dom-by-tag dom 'dl)))))
    (should (equal (mapcar #'car pairs) '("origin" "x")))))

(ert-deftest mr-x-docs-test-symbol-at-point-keeps-qualifier-when-indexed ()
  (cl-letf (((symbol-function 'mr-x/docs--candidates)
             (lambda () '(("os.Open()" . (:name "os.Open()")) ("Array.map" . (:name "Array.map"))))))
    (with-temp-buffer
      (insert "file, err := os.Open(path)")
      (search-backward "Open")
      (should (equal (mr-x/docs--symbol-at-point) "os.Open")))
    (with-temp-buffer
      (insert "const ids = rows.map((r) => r.id)")
      (search-backward "map")
      ;; rows.map matches no entry, so the bare symbol is used
      (should (equal (mr-x/docs--symbol-at-point) "map")))
    (with-temp-buffer
      (insert "   ")
      (should (null (mr-x/docs--symbol-at-point))))))

(ert-deftest mr-x-docs-test-sort-preferred-then-shorter ()
  (let ((sorted (mr-x/docs--sort-candidates
                 '("elf.Open()" "os.Open()" "Window.open" "macho.Open()")
                 (lambda (s) (if (string-prefix-p "Window" s) "dom" "go"))
                 '("go"))))
    (should (equal sorted '("os.Open()" "elf.Open()" "macho.Open()" "Window.open")))))

(ert-deftest mr-x-docs-test-fontify-uses-language-mode ()
  "Code is fontified with the docset's major mode, so keywords carry font-lock faces."
  (let ((out (mr-x/docs--fontify "func Open(name string) (*File, error)" "go")))
    (should (equal (substring-no-properties out) "func Open(name string) (*File, error)"))
    (should (memq (get-text-property 0 'face out) '(font-lock-keyword-face))))
  ;; unknown docset: plain string, no error
  (should (equal (mr-x/docs--fontify "x" "nope") "x")))

(ert-deftest mr-x-docs-test-render-synopsis-keeps-fontification ()
  (let ((buf (with-temp-buffer
               (mr-x/docs--render '(:title "t" :docset "go" :blurb "b" :synopsis "func F() int"))
               (buffer-string))))
    (let ((i (string-search "func F" buf))
          (j (string-search "()" buf)))
      (should (memq 'font-lock-keyword-face (ensure-list (get-text-property i 'face buf))))
      ;; punctuation stays default, not the flat synopsis colour
      (should-not (memq 'mr-x/docs-synopsis (ensure-list (get-text-property j 'face buf)))))))

(ert-deftest mr-x-docs-test-render-usage-section ()
  (let ((out (with-temp-buffer
               (mr-x/docs--render-usage '(:count 14 :files 6
                                          :hits (("web/src/api.ts" 42 "const ids = rows.map((r) => r.id);")
                                                 ("web/src/store.ts" 118 "return items.map(normalize);")))
                                        "acp-mobile")
               (buffer-string))))
    (should (string-match-p "\nUSAGE  14 hits in 6 files (project: acp-mobile)\n  web/src/api.ts:42     const ids = rows.map((r) => r.id);\n  web/src/store.ts:118  return items.map(normalize);\n" out))
    (should (equal (get-text-property (string-search "web/src/api" out) 'mr-x/docs-usage out)
                   '("web/src/api.ts" 42)))))

(ert-deftest mr-x-docs-test-render-usage-omits-when-empty ()
  (should (equal "" (with-temp-buffer (mr-x/docs--render-usage '(:count 0 :files 0 :hits nil) "p")
                                      (buffer-string))))
  (should (equal "" (with-temp-buffer (mr-x/docs--render-usage nil "p") (buffer-string)))))

(provide 'mr-x-docs-test)
;;; mr-x-docs-test.el ends here
