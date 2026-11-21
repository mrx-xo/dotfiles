;;; casa-agenda-test.el --- Task tree export and posting checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'casa-agenda)

(defconst casa-agenda-test--org "#+title: tasks
#+category: arca
* TODO [#A] Cancel the trial                                          :money:
DEADLINE: <2026-11-16 Mon>
:PROPERTIES:
:ID:       AAA
:END:
* DONE water the plants
:PROPERTIES:
:ID:       DDD
:END:
* Project
:PROPERTIES:
:ID:       GGG
:CATEGORY: proj
:END:
** NEXT Finish the [[https://example.invalid][page]]
SCHEDULED: <2026-11-21 Sat 09:30>
:PROPERTIES:
:ID:       BBB
:END:
** DONE shipped
** Sub
*** TODO deep one
** DONE finished parent
*** TODO still open under it
* Empty group
** DONE nothing left
* TODO no id yet
")

(defmacro casa-agenda-test--with-org (&rest body)
  "Run BODY in an Org buffer holding the fixture."
  (declare (indent 0))
  `(with-temp-buffer
     (let ((org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d)")))
           (org-inhibit-startup t))
       (insert casa-agenda-test--org)
       (org-mode)
       ,@body)))

(defun casa-agenda-test--titles (nodes)
  (cl-loop for n across nodes
           collect (alist-get 'title n)
           append (casa-agenda-test--titles (alist-get 'children n))))

(ert-deftest casa-agenda-test-tree-keeps-open-work-in-file-order ()
  (casa-agenda-test--with-org
    (let* ((payload (casa-agenda-export-buffer))
           (nodes (alist-get 'nodes payload)))
      (should (= 1 (alist-get 'version payload)))
      (should (equal (casa-agenda-test--titles nodes)
                     '("Cancel the trial" "Project" "Finish the page" "Sub"
                       "deep one" "finished parent" "still open under it"
                       "no id yet")))
      (should (equal (cl-loop for n across nodes collect (alist-get 'title n))
                     '("Cancel the trial" "Project" "no id yet"))))))

(ert-deftest casa-agenda-test-task-fields ()
  (casa-agenda-test--with-org
    (let* ((nodes (alist-get 'nodes (casa-agenda-export-buffer)))
           (first (aref nodes 0))
           (project (aref nodes 1))
           (next (aref (alist-get 'children project) 0))
           (last (aref nodes 2)))
      (should (equal (alist-get 'id first) "AAA"))
      (should (equal (alist-get 'todo first) "TODO"))
      (should (equal (alist-get 'priority first) "A"))
      (should (equal (alist-get 'tags first) ["money"]))
      (should (equal (alist-get 'deadline first) "2026-11-16"))
      (should (eq (alist-get 'scheduled first) :null))
      (should (equal (alist-get 'category first) "arca"))
      ;; A plain heading is a group; its category reaches the tasks under it.
      (should (eq (alist-get 'todo project) :null))
      (should (equal (alist-get 'category next) "proj"))
      (should (equal (alist-get 'todo next) "NEXT"))
      (should (eq (alist-get 'priority next) :null))
      (should (string-match-p "\\`2026-11-21T09:30:00[-+][0-9][0-9]:[0-9][0-9]\\'"
                              (alist-get 'scheduled next)))
      (should (eq (alist-get 'id last) :null)))))

(ert-deftest casa-agenda-test-done-parent-with-open-child-is-a-container ()
  (casa-agenda-test--with-org
    (let* ((project (aref (alist-get 'nodes (casa-agenda-export-buffer)) 1))
           (parent (aref (alist-get 'children project) 2)))
      (should (equal (alist-get 'title parent) "finished parent"))
      (should (eq (alist-get 'todo parent) :null)))))

(ert-deftest casa-agenda-test-known-ids-include-done-headings ()
  (casa-agenda-test--with-org
    (should (equal (alist-get 'known_ids (casa-agenda-export-buffer))
                   ["AAA" "DDD" "GGG" "BBB"]))))

(ert-deftest casa-agenda-test-payload-serializes ()
  (casa-agenda-test--with-org
    (let ((back (json-parse-string (json-serialize (casa-agenda-export-buffer))
                                   :object-type 'alist)))
      (should (= 3 (length (alist-get 'nodes back)))))
    (erase-buffer)
    (should (equal (json-serialize (casa-agenda-export-buffer))
                   "{\"version\":1,\"file\":\"\",\"known_ids\":[],\"nodes\":[]}"))))

(defmacro casa-agenda-test--with-files (&rest body)
  "Run BODY with a temp task file and URL file bound, state reset."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "casa-agenda-test-" t))
          (casa-agenda-file (expand-file-name "tasks.org" dir))
          (casa-agenda-url-file (expand-file-name "url" dir))
          (casa-agenda-enabled-function #'always)
          (casa-agenda--last-sent nil)
          (casa-agenda--last-error nil)
          (casa-agenda--process nil)
          (casa-agenda--again nil)
          (org-inhibit-startup t))
     (unwind-protect
         (progn
           (with-temp-file casa-agenda-file (insert "* TODO one\n"))
           ,@body)
       (let ((b (find-buffer-visiting casa-agenda-file)))
         (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest casa-agenda-test-no-url-file-no-post ()
  (casa-agenda-test--with-files
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "must not start a process"))))
      (should-not (casa-agenda-url))
      (should-not (casa-agenda-post))
      (with-temp-file casa-agenda-url-file (insert "  \n"))
      (should-not (casa-agenda-post))
      (with-temp-file casa-agenda-url-file (insert "https://example.invalid/api/agenda\n"))
      (should (equal (casa-agenda-url) "https://example.invalid/api/agenda"))
      (let ((casa-agenda-enabled-function #'ignore))
        (should-not (casa-agenda-post))))))

(ert-deftest casa-agenda-test-unchanged-tree-is-not-posted-again ()
  (casa-agenda-test--with-files
    (with-temp-file casa-agenda-url-file (insert "https://example.invalid/api/agenda\n"))
    (setq casa-agenda--last-sent (json-serialize (casa-agenda-export)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "must not start a process"))))
      (should-not (casa-agenda-post)))))

(ert-deftest casa-agenda-test-token-never-on-a-command-line ()
  (casa-agenda-test--with-files
    (with-temp-file casa-agenda-url-file (insert "https://example.invalid/api/agenda\n"))
    (let ((casa-agenda-token-command "printf not-a-real-token")
          (real (symbol-function 'make-process))
          seen)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq seen (list (plist-get args :command) process-environment))
                   (funcall real :name "casa-agenda-test" :command '("true")))))
        (should (casa-agenda-post))
        (should (equal (car (car seen)) "sh"))
        (should-not (string-match-p "not-a-real-token" (mapconcat #'identity (car seen) " ")))
        (should (member "CASA_AGENDA_URL=https://example.invalid/api/agenda" (cadr seen)))))))

(ert-deftest casa-agenda-test-posts-for-real-to-a-local-listener ()
  "The child shell sends the token and body; a 200 records the tree as sent."
  (skip-unless (and (executable-find "curl") (executable-find "python3")))
  (casa-agenda-test--with-files
    (let* ((dir (file-name-directory casa-agenda-file))
           (seen (expand-file-name "seen.json" dir))
           (port-file (expand-file-name "port" dir))
           (server (start-process
                    "casa-agenda-test-server" nil "python3" "-c"
                    "import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers['content-length']))
        json.dump({'auth': self.headers.get('authorization'), 'body': json.loads(body)}, open(sys.argv[1], 'w'))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[2], 'w').write(str(s.server_address[1]))
s.handle_request()" seen port-file))
           (casa-agenda-token-command "printf not-a-real-token"))
      (unwind-protect
          (progn
            (with-timeout (10 (error "listener did not start"))
              (while (not (and (file-exists-p port-file)
                               (> (file-attribute-size (file-attributes port-file)) 0)))
                (sleep-for 0.05)))
            (with-temp-file casa-agenda-url-file
              (insert (format "http://127.0.0.1:%s/api/agenda\n"
                              (with-temp-buffer (insert-file-contents port-file) (buffer-string)))))
            (let ((process (casa-agenda-post)))
              (should process)
              (with-timeout (15 (error "post did not finish"))
                (while (or (process-live-p process) casa-agenda--process)
                  (accept-process-output nil 0.05))))
            (should casa-agenda--last-sent)
            (should-not casa-agenda--last-error)
            (let ((got (json-parse-string
                        (with-temp-buffer (insert-file-contents seen) (buffer-string))
                        :object-type 'alist)))
              (should (equal (alist-get 'auth got) "Bearer not-a-real-token"))
              (should (equal (alist-get 'title (aref (alist-get 'nodes (alist-get 'body got)) 0))
                             "one"))
              (should (stringp (alist-get 'exported_at (alist-get 'body got)))))
            ;; Same tree again: nothing is sent.
            (should-not (casa-agenda-post)))
        (when (process-live-p server) (delete-process server))))))

(ert-deftest casa-agenda-test-refused-post-is-reported-once-and-not-recorded ()
  (casa-agenda-test--with-files
    (with-temp-file casa-agenda-url-file (insert "http://127.0.0.1:1/api/agenda\n"))
    (let ((casa-agenda-token-command "printf not-a-real-token") (said 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when (string-prefix-p "casa-agenda" (apply #'format fmt args))
                     (cl-incf said)))))
        (dotimes (_ 2)
          (let ((process (casa-agenda-post)))
            (should process)
            (with-timeout (30 (error "post did not finish"))
              (while (or (process-live-p process) casa-agenda--process)
                (accept-process-output nil 0.05))))))
      (should-not casa-agenda--last-sent)
      (should (= said 1)))))

(ert-deftest casa-agenda-test-mode-hooks-only-the-task-file ()
  (casa-agenda-test--with-files
    (let (posts)
      (cl-letf (((symbol-function 'casa-agenda-post)
                 (lambda (&rest _) (push buffer-file-name posts) nil)))
        (unwind-protect
            (progn
              (casa-agenda-mode 1)
              (with-current-buffer (find-file-noselect casa-agenda-file)
                (goto-char (point-max)) (insert "* TODO two\n") (save-buffer))
              (let ((other (expand-file-name "other.org" (file-name-directory casa-agenda-file))))
                (with-current-buffer (find-file-noselect other)
                  (insert "* TODO x\n") (save-buffer) (kill-buffer)))
              (should (= 1 (length posts))))
          (casa-agenda-mode -1)))
      (should-not (memq #'casa-agenda--after-save after-save-hook)))))

(provide 'casa-agenda-test)
;;; casa-agenda-test.el ends here
