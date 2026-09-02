;;; syzygy-recall-test.el --- Tests for syzygy-recall -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)

(defvar agent-recall--index nil)

;; `syzygy-recall' only needs these agent-recall entry points.  Supplying the
;; feature keeps this unit test independent from the user's installed package.
(provide 'agent-recall)

(load (expand-file-name "syzygy-recall.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun syzygy-recall-test--decode (encoded)
  "Decode ENCODED JSON returned by `syzygy-recall-transcripts-json'."
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist
   :array-type 'list))

(ert-deftest syzygy-recall-transcripts-json-includes-durable-label ()
  "A missing label field would make archived labels unsearchable on phone."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (file (make-temp-file "syzygy-recall-" nil ".md")))
    (unwind-protect
        (progn
          (puthash file
                   '(:project "syzygy" :timestamp "2026-09-01-12-00-00"
                     :preview "Search the archive" :session-id "session-1")
                   agent-recall--index)
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall-session-label)
                     (lambda (session-id)
                       (and (equal session-id "session-1") "Recall UX")))
                    ((symbol-function 'syzygy-recall--agent)
                     (lambda (_file) "Codex")))
            (let* ((rows (syzygy-recall-test--decode
                          (syzygy-recall-transcripts-json 1)))
                   (row (car rows)))
              (should (equal (alist-get 'label row) "Recall UX")))))
      (delete-file file))))

(ert-deftest syzygy-recall-transcripts-json-zero-limit-means-all ()
  "A zero LIMIT must export the complete index used by global search."
  (let ((agent-recall--index (make-hash-table :test #'equal))
        (files (list (make-temp-file "syzygy-recall-a-" nil ".md")
                     (make-temp-file "syzygy-recall-b-" nil ".md"))))
    (unwind-protect
        (progn
          (cl-loop for file in files
                   for n from 1
                   do (puthash file
                               `(:project "syzygy"
                                 :timestamp ,(format "2026-09-01-12-00-0%d" n)
                                 :preview "Conversation"
                                 :session-id ,(format "session-%d" n))
                               agent-recall--index))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall-session-label)
                     (lambda (_session-id) nil))
                    ((symbol-function 'syzygy-recall--agent)
                     (lambda (_file) "Codex")))
            (should (= (length (syzygy-recall-test--decode
                                (syzygy-recall-transcripts-json 0)))
                       2))))
      (mapc #'delete-file files))))

(ert-deftest syzygy-recall-sidecar-label-put-preserves-clear-tombstone ()
  "A live clear must override an older durable agent-recall label immediately."
  (let ((labels (make-hash-table :test #'equal)))
    (syzygy-recall-sidecar-label-put labels "session-1" nil)
    (should (equal (gethash "session-1" labels 'missing) ""))))

(provide 'syzygy-recall-test)
;;; syzygy-recall-test.el ends here
