;;; calliope-notes-test.el --- Tests for calliope-notes -*- lexical-binding: t; -*-

(require 'ert)
(require 'calliope-notes)

(defmacro calliope-notes-test--with-tree (&rest body)
  "Run BODY with `dir' bound to a temporary export tree and `cache' to a render dir."
  `(let* ((dir (make-temp-file "calliope-notes-" t))
          (cache (make-temp-file "calliope-png-" t))
          (calliope-notes-render-directory cache))
     (unwind-protect (progn ,@body)
       (delete-directory dir t)
       (delete-directory cache t))))

(defun calliope-notes-test--touch (path seconds-ago)
  "Create PATH (and its parent) with an mtime SECONDS-AGO in the past."
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert "x"))
  (set-file-times path (time-subtract (current-time) (seconds-to-time seconds-ago)))
  path)

(ert-deftest calliope-notes-newest-picks-latest-mtime-across-notebooks ()
  (calliope-notes-test--with-tree
   (calliope-notes-test--touch (expand-file-name "old/old.pdf" dir) 300)
   (let ((new (calliope-notes-test--touch (expand-file-name "Notepad7/Notepad7.pdf" dir) 10)))
     (calliope-notes-test--touch (expand-file-name "mid/mid.png" dir) 100)
     (should (equal (calliope-notes-newest dir) new))
     (should (equal (mapcar #'file-name-nondirectory (calliope-notes-files dir))
                    '("Notepad7.pdf" "mid.png" "old.pdf"))))))

(ert-deftest calliope-notes-newest-ignores-syncthing-internals-and-junk ()
  (calliope-notes-test--with-tree
   (calliope-notes-test--touch (expand-file-name ".stfolder/syncthing-folder-1.txt" dir) 1)
   (calliope-notes-test--touch (expand-file-name ".stversions/x/x.pdf" dir) 1)
   (calliope-notes-test--touch (expand-file-name "x/.syncthing.x.pdf.tmp" dir) 1)
   (calliope-notes-test--touch (expand-file-name "x/notes.db" dir) 1)
   (should-not (calliope-notes-newest dir))
   (let ((real (calliope-notes-test--touch (expand-file-name "x/x.pdf" dir) 50)))
     (should (equal (calliope-notes-newest dir) real)))))

(ert-deftest calliope-notes-newest-is-nil-for-missing-directory ()
  (should-not (calliope-notes-newest "/nonexistent/calliope")))

(ert-deftest calliope-notes-render-copies-images-under-a-safe-name ()
  (calliope-notes-test--with-tree
   (let* ((src (calliope-notes-test--touch (expand-file-name "OP sketch/OP sketch.png" dir) 5))
          (out (calliope-notes-render src)))
     (should (file-exists-p out))
     (should (string-prefix-p cache out))
     (should-not (string-match-p " " (file-name-nondirectory out)))
     (should (string-match-p "\\`OP-sketch-[0-9]\\{8\\}-[0-9]\\{6\\}\\.png\\'"
                             (file-name-nondirectory out))))))

(ert-deftest calliope-notes-render-pdf-produces-png-and-caches ()
  (skip-unless (executable-find "sips"))
  (calliope-notes-test--with-tree
   (let ((src (expand-file-name "Notepad7/Notepad7.pdf" dir)))
     (make-directory (file-name-directory src) t)
     ;; Minimal one-page PDF, enough for sips to rasterise.
     (with-temp-file src
       (insert "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
               "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
               "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n"
               "trailer<</Root 1 0 R>>\n%%EOF\n"))
     (let* ((out (calliope-notes-render src))
            (first-mtime (file-attribute-modification-time (file-attributes out))))
       (should (string-suffix-p ".png" out))
       (should (file-exists-p out))
       (should (> (file-attribute-size (file-attributes out)) 0))
       ;; Same source version renders once.
       (sleep-for 1.1)
       (should (equal (calliope-notes-render src) out))
       (should (equal (file-attribute-modification-time (file-attributes out)) first-mtime))
       ;; A re-export (new mtime) gets a fresh render.
       (set-file-times src (time-add (current-time) 5))
       (should-not (equal (calliope-notes-render src) out))))))

(ert-deftest calliope-notes-chat-buffer-errors-without-a-chat ()
  (with-temp-buffer
    (should-error (calliope-notes--chat-buffer) :type 'user-error)))

(ert-deftest calliope-notes-send-newest-inserts-into-given-buffer ()
  (calliope-notes-test--with-tree
   (let* ((calliope-notes-directory dir)
          (src (calliope-notes-test--touch (expand-file-name "n/n.png" dir) 5))
          (inserted nil))
     (cl-letf (((symbol-function 'agent-shell-insert)
                (lambda (&rest args) (setq inserted args))))
       (with-temp-buffer
         (calliope-notes-send-newest (current-buffer))
         (should inserted)
         (should (string-prefix-p "@" (plist-get inserted :text)))
         (should (string-match-p "/n-[0-9-]+\\.png\\'" (plist-get inserted :text)))
         (should (eq (plist-get inserted :shell-buffer) (current-buffer))))))))

(provide 'calliope-notes-test)
;;; calliope-notes-test.el ends here
