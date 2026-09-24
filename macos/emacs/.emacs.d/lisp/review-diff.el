;;; review-diff.el --- Aligned rows and hunks from two texts -*- lexical-binding: t; -*-
;;; Commentary:
;; Pure functions.  `review-diff-ops' shells out to `diff' in normal
;; format because its "12,14c20,22" headers carry both line numbers, which
;; unified output makes you count back.  Everything else is list work.
;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defcustom review-diff-program "diff"
  "The diff program used to compare two texts."
  :type 'string :group 'review)

(defun review-diff--lines (text)
  "Split TEXT into lines; a trailing newline does not add an empty line."
  (if (string-empty-p text) nil
    (let ((lines (split-string text "\n")))
      (if (string-empty-p (car (last lines))) (butlast lines) lines))))

(defun review-diff--range (spec)
  "Parse a normal-diff range SPEC like \"12,14\" or \"5\" into (START . END)."
  (if (string-match "\\`\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?\\'" spec)
      (let ((a (string-to-number (match-string 1 spec))))
        (cons a (if (match-string 2 spec) (string-to-number (match-string 2 spec)) a)))
    (error "Bad diff range %S" spec)))

(defun review-diff--run (old new)
  "Return `diff' normal output comparing OLD and NEW texts."
  (let ((a (make-temp-file "review-old")) (b (make-temp-file "review-new")))
    (unwind-protect
        (progn
          (with-temp-file a (insert old))
          (with-temp-file b (insert new))
          (with-temp-buffer
            (let ((status (call-process review-diff-program nil t nil "--" a b)))
              (unless (memq status '(0 1))
                (error "diff failed (%s): %s" status (buffer-string))))
            (buffer-string)))
      (delete-file a) (delete-file b))))

(defun review-diff-ops (old new)
  "Return the line ops that turn OLD into NEW, in row order.
Each op is (:kind ctx|del|add :old N :new N :text STRING)."
  (let* ((old-lines (vconcat (review-diff--lines old)))
         (new-lines (vconcat (review-diff--lines new)))
         (out nil) (o 1) (n 1))
    (cl-flet ((ctx-until (old-stop)
                (while (< o old-stop)
                  (push (list :kind 'ctx :old o :new n :text (aref old-lines (1- o))) out)
                  (cl-incf o) (cl-incf n)))
              (dels (from to)
                (cl-loop for i from from to to
                         do (push (list :kind 'del :old i :new nil :text (aref old-lines (1- i))) out))
                (setq o (1+ to)))
              (adds (from to)
                (cl-loop for i from from to to
                         do (push (list :kind 'add :old nil :new i :text (aref new-lines (1- i))) out))
                (setq n (1+ to))))
      (dolist (line (split-string (review-diff--run old new) "\n" t))
        (when (string-match "\\`\\([0-9,]+\\)\\([acd]\\)\\([0-9,]+\\)\\'" line)
          ;; Read all three groups before `review-diff--range' runs its own
          ;; `string-match' and clobbers the match data.
          (let* ((lhs-spec (match-string 1 line))
                 (op (match-string 2 line))
                 (rhs-spec (match-string 3 line))
                 (lhs (review-diff--range lhs-spec))
                 (rhs (review-diff--range rhs-spec)))
            (pcase op
              ("a" (ctx-until (1+ (car lhs))) (adds (car rhs) (cdr rhs)))
              ("d" (ctx-until (car lhs)) (dels (car lhs) (cdr lhs)))
              ("c" (ctx-until (car lhs)) (dels (car lhs) (cdr lhs)) (adds (car rhs) (cdr rhs)))))))
      (ctx-until (1+ (length old-lines))))
    (nreverse out)))

(defun review-diff-rows (ops)
  "Pair OPS into aligned rows.
A run of dels followed by a run of adds is zipped: shared rows are `both',
the longer tail keeps its own kind with a blank partner."
  (let ((rows nil) (ops (copy-sequence ops)))
    (while ops
      (let ((op (car ops)))
        (if (eq (plist-get op :kind) 'ctx)
            (progn (push (list :kind 'ctx :old-no (plist-get op :old) :new-no (plist-get op :new)
                               :old (plist-get op :text) :new (plist-get op :text)) rows)
                   (setq ops (cdr ops)))
          (let (dels adds)
            (while (and ops (eq (plist-get (car ops) :kind) 'del)) (push (pop ops) dels))
            (while (and ops (eq (plist-get (car ops) :kind) 'add)) (push (pop ops) adds))
            (setq dels (nreverse dels) adds (nreverse adds))
            (while (or dels adds)
              (let ((d (pop dels)) (a (pop adds)))
                (push (list :kind (cond ((and d a) 'both) (d 'del) (t 'add))
                            :old-no (and d (plist-get d :old)) :new-no (and a (plist-get a :new))
                            :old (and d (plist-get d :text)) :new (and a (plist-get a :text)))
                      rows)))))))
    (nreverse rows)))

(defcustom review-diff-label-regexp
  (concat "\\`\\(?:"
          "(\\(?:cl-\\|ert-\\)?def[a-z-]*[[:space:]]"          ; lisp defun/defvar/defcustom
          "\\|(\\(?:define-\\|transient-define-\\)[a-z-]+[[:space:]]"
          "\\|\\(?:async[[:space:]]+\\)?\\(?:def\\|class\\|function\\|fn\\|func\\|impl\\|struct\\|enum\\|trait\\|interface\\|type\\|module\\)[[:space:]]"
          "\\|\\(?:export\\|pub\\|public\\|private\\|protected\\|static\\)[[:space:]]"
          "\\|#+[[:space:]]"                                    ; markdown heading
          "\\|\\*+[[:space:]]"                                  ; org heading
          "\\)")
  "A column-0 line matching this is a definition or heading for hunk labels."
  :type 'regexp :group 'review)

(defun review-diff-label (lines index)
  "Return the nearest definition or heading line at or above INDEX in LINES.
Only lines matching `review-diff-label-regexp' count, so prose and plain
statements at column 0 do not become labels."
  (let ((i (min index (1- (length lines)))) (found ""))
    (while (and (>= i 0) (string-empty-p found))
      (let ((l (nth i lines)))
        (when (string-match-p review-diff-label-regexp l)
          (setq found l)))
      (cl-decf i))
    found))

(defun review-diff-hunks (rows &optional context)
  "Group changed ROWS into hunks, merging changes within CONTEXT rows (3)."
  (let* ((context (or context 3)) (rows (vconcat rows))
         (n (length rows)) (hunks nil) (i 0)
         (old-counts (make-vector (1+ n) 0))
         (new-counts (make-vector (1+ n) 0))
         (new-labels (make-vector (1+ n) ""))
         (label ""))
    ;; Prefix counts give source positions and hunk sizes without rescanning
    ;; full files.  Cache nearest definition labels once in source order.
    (dotimes (row-index n)
      (let* ((row (aref rows row-index))
             (old (plist-get row :old-no)) (new (plist-get row :new-no)))
        (aset old-counts (1+ row-index) (+ (aref old-counts row-index) (if old 1 0)))
        (aset new-counts (1+ row-index) (+ (aref new-counts row-index) (if new 1 0)))
        (when new
          (when (string-match-p review-diff-label-regexp (plist-get row :new))
            (setq label (plist-get row :new)))
          (aset new-labels new label))))
    (while (< i n)
      (if (eq (plist-get (aref rows i) :kind) 'ctx)
          (cl-incf i)
        (let ((start i) (end i) (j i))
          (while (< j n)
            (if (eq (plist-get (aref rows j) :kind) 'ctx)
                (if (> (- j end) context) (setq j n) (cl-incf j))
              (setq end j) (cl-incf j)))
          (let* ((first (aref rows start)) (last (aref rows end))
                 (label-line (or (plist-get last :new-no) (plist-get first :new-no) 1)))
            (push (list :start start :end end
                        :old-start (1+ (aref old-counts start))
                        :old-count (- (aref old-counts (1+ end)) (aref old-counts start))
                        :new-start (1+ (aref new-counts start))
                        :new-count (- (aref new-counts (1+ end)) (aref new-counts start))
                        :label (aref new-labels (min n label-line)))
                  hunks))
          (setq i (1+ end)))))
    (nreverse hunks)))

(provide 'review-diff)
;;; review-diff.el ends here
