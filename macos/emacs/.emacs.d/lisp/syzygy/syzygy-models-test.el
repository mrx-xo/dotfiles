;;; syzygy-models-test.el --- Tests for syzygy-models -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load-file (expand-file-name "syzygy-bridge.el" dir))
  (load-file (expand-file-name "syzygy-models.el" dir)))

(defun syzygy-models-test--decode (encoded)
  "Decode ENCODED base64 JSON into alists and lists."
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist :array-type 'list :false-object :false))

(defmacro syzygy-models-test--with-session (&rest body)
  "Run BODY with a real buffer and stubbed agent-shell helpers.
Bind name, state, current, and models for BODY to inspect or change."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq major-mode 'agent-shell-mode)
     (let ((name (buffer-name))
           (state '((:session . ((:id . "session-1")))))
           (current "one")
           (models '(((:model-id . "one") (:name . "One")
                      (:description . "First model"))
                     ((:model-id . "two") (:name . "Two")
                      (:description . nil)))))
       (cl-letf (((symbol-function 'agent-shell--state)
                  (lambda ()
                    (should (equal (buffer-name) name))
                    state))
                 ((symbol-function 'agent-shell--current-model-id)
                  (lambda (arg)
                    (should (equal (buffer-name) name))
                    (should (eq arg state))
                    current))
                 ((symbol-function 'agent-shell--get-available-models)
                  (lambda (arg)
                    (should (equal (buffer-name) name))
                    (should (eq arg state))
                    models))
                 ((symbol-function 'agent-shell--config-option-set-model-id)
                  (lambda (&rest _args)
                    (ert-fail "Unexpected model setter call"))))
         ,@body))))

(ert-deftest syzygy-models-json-lists-current-and-models ()
  (syzygy-models-test--with-session
    ;; Call from another buffer to exercise the buffer-name lookup.
    (with-temp-buffer
      (should
       (equal (syzygy-models-test--decode (syzygy-models-json name))
              '((current . "one")
                (models . (((id . "one") (name . "One")
                            (description . "First model"))
                           ((id . "two") (name . "Two")
                            (description . ""))))))))))

(ert-deftest syzygy-models-json-empty-models-is-an-array ()
  (syzygy-models-test--with-session
    (setq current nil models nil)
    (let ((got (json-parse-string
                (syzygy-bridge-decode-base64 (syzygy-models-json name))
                :object-type 'alist)))
      (should (equal (alist-get 'current got) ""))
      (should (equal (alist-get 'models got) [])))))

(ert-deftest syzygy-models-missing-buffer-is-nil ()
  (let ((name (generate-new-buffer-name " *syzygy-models-missing*")))
    (should-not (syzygy-models-json name))
    (should-not (syzygy-model-set-json name "two"))))

(ert-deftest syzygy-models-non-agent-buffer-is-nil ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-shell--state)
               (lambda () (ert-fail "State read outside agent-shell"))))
      (should-not (syzygy-models-json (buffer-name)))
      (should-not (syzygy-model-set-json (buffer-name) "two")))))

(ert-deftest syzygy-models-session-without-id-is-nil ()
  (syzygy-models-test--with-session
    (setq state '((:session . nil)))
    (should-not (syzygy-models-json name))
    (should-not (syzygy-model-set-json name "two"))))

(ert-deftest syzygy-models-uninitialized-state-is-nil ()
  (syzygy-models-test--with-session
    (cl-letf (((symbol-function 'agent-shell--state)
               (lambda () (error "No shell state available"))))
      (should-not (syzygy-models-json name))
      (should-not (syzygy-model-set-json name "two")))))

(ert-deftest syzygy-model-set-unknown-model-is-rejected ()
  (syzygy-models-test--with-session
    (let ((got (syzygy-models-test--decode
                (syzygy-model-set-json name "unknown"))))
      (should (eq (alist-get 'ok got) :false))
      (should (equal (alist-get 'error got) "Unknown model id")))))

(ert-deftest syzygy-model-set-current-is-a-no-op ()
  (syzygy-models-test--with-session
    (should (equal (syzygy-models-test--decode
                    (syzygy-model-set-json name "one"))
                   '((ok . t) (current . "one"))))))

(ert-deftest syzygy-model-set-success ()
  (syzygy-models-test--with-session
    (let ((calls 0))
      (cl-letf (((symbol-function 'agent-shell--config-option-set-model-id)
                 (cl-function
                  (lambda (&key model-id on-success on-failure)
                    (should (equal (buffer-name) name))
                    (should (equal model-id "two"))
                    (should (functionp on-failure))
                    (cl-incf calls)
                    (funcall on-success)))))
        (with-temp-buffer
          (should (equal (syzygy-models-test--decode
                          (syzygy-model-set-json name "two"))
                         '((ok . t) (current . "two")))))
        (should (= calls 1))))))

(ert-deftest syzygy-model-set-failure-callback ()
  (syzygy-models-test--with-session
    (cl-letf (((symbol-function 'agent-shell--config-option-set-model-id)
               (cl-function
                (lambda (&key model-id on-success on-failure)
                  (should (equal model-id "two"))
                  (should (functionp on-success))
                  (funcall on-failure "Model unavailable" nil)))))
      (should (equal (syzygy-models-test--decode
                      (syzygy-model-set-json name "two"))
                     '((ok . :false) (error . "Model unavailable")))))))

(ert-deftest syzygy-model-set-synchronous-error ()
  (syzygy-models-test--with-session
    (cl-letf (((symbol-function 'agent-shell--config-option-set-model-id)
               (lambda (&rest _args) (error "Disconnected"))))
      (should (equal (syzygy-models-test--decode
                      (syzygy-model-set-json name "two"))
                     '((ok . :false) (error . "Disconnected")))))))

(ert-deftest syzygy-model-set-waits-for-success ()
  (syzygy-models-test--with-session
    (let (callback)
      (cl-letf (((symbol-function 'agent-shell--config-option-set-model-id)
                 (lambda (&rest args)
                   (setq callback (plist-get args :on-success))))
                ((symbol-function 'accept-process-output)
                 (lambda (process seconds)
                   (should-not process)
                   (should (= seconds 0.1))
                   (funcall callback))))
        (should (equal (syzygy-models-test--decode
                        (syzygy-model-set-json name "two"))
                       '((ok . t) (current . "two"))))))))

(ert-deftest syzygy-model-set-times-out-without-sleeping ()
  (syzygy-models-test--with-session
    (let ((now 0.0) (waits 0))
      (cl-letf (((symbol-function 'agent-shell--config-option-set-model-id)
                 (lambda (&rest _args) nil))
                ((symbol-function 'float-time) (lambda () now))
                ((symbol-function 'accept-process-output)
                 (lambda (process seconds)
                   (should-not process)
                   (should (= seconds 0.1))
                   (cl-incf waits)
                   (cl-incf now 5.0))))
        (should (equal (syzygy-models-test--decode
                        (syzygy-model-set-json name "two"))
                       '((ok . :false) (error . "Model switch timed out"))))
        (should (= waits 3))))))

(provide 'syzygy-models-test)
;;; syzygy-models-test.el ends here
