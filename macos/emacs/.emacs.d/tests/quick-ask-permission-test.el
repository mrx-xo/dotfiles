;;; quick-ask-permission-test.el --- Quick Ask answers its agent's permission requests -*- lexical-binding: t; -*-
(require 'ert)
(require 'map)
(require 'review-panel)

;; The config defines these; a focused run stands them in first.
(defvar agent-shell-permission-responder-function nil)
(require 'quick-ask-permission)
;; The config makes the package map the parent of the box's waiting map.
(defvar mr-x/quick-ask-waiting-map
  (let ((map (make-sparse-keymap))) (set-keymap-parent map quick-ask-permission-map) map))

(defvar mr-x/quick-ask--shell-buffer nil)
(defvar-local mr-x/quick-ask--session-root nil)
(defvar-local mr-x/quick-ask--phase nil)

(defun qap-test--permission (kind &optional raw-input)
  "A permission request of KIND; its answer lands in the returned cell's car."
  (let ((answer (list nil)))
    (list (list (cons :tool-call (list (cons :title "Inspect the eval cases")
                                       (cons :kind kind)
                                       (cons :raw-input raw-input)))
                (cons :options (list (list (cons :kind "allow_once") (cons :option-id "allow"))
                                     (list (cons :kind "reject_once") (cons :option-id "reject"))
                                     (list (cons :kind "allow_always") (cons :option-id "always"))))
                (cons :respond (lambda (id) (setcar answer id) t)))
          answer)))

(defmacro qap-test--with-session (&rest body)
  "Run BODY with `shell' a Quick Ask session and `popup' its waiting box."
  (declare (indent 0))
  `(let* ((shell (generate-new-buffer " *qap-shell*"))
          (popup (get-buffer-create "*quick-ask*"))
          (mr-x/quick-ask--shell-buffer shell))
     (unwind-protect
         (progn
           (with-current-buffer shell (setq mr-x/quick-ask--session-root "/tmp/"))
           (with-current-buffer popup
             (let ((inhibit-read-only t)) (erase-buffer))
             (setq mr-x/quick-ask--phase 'waiting)
             (insert "ASK origin\nquestion\n"
                     (propertize "*" 'review-ask-anim t) " thinking\n"
                     "footer\n"))
           ,@body)
       (let ((kill-buffer-query-functions nil))
         (kill-buffer shell) (kill-buffer popup)))))

(ert-deftest quick-ask-permission-allows-reads-on-its-own ()
  (qap-test--with-session
    (dolist (kind '("read" "search" "think"))
      (pcase-let ((`(,permission ,answer) (qap-test--permission kind)))
        (let ((quick-ask-permission--shell-buffer shell))
          (should (quick-ask-permission-respond permission)))
        (should (equal (car answer) "allow"))))
    ;; Nothing was put in the box for them.
    (with-current-buffer popup (should-not quick-ask-permission--pending))))

(ert-deftest quick-ask-permission-leaves-other-agents-alone ()
  ;; A normal agent-shell buffer keeps the usual prompt: nil, nothing answered.
  (let ((other (generate-new-buffer " *qap-other*")))
    (unwind-protect
        (pcase-let ((`(,permission ,answer) (qap-test--permission "read")))
          (let ((quick-ask-permission--shell-buffer other))
            (should-not (quick-ask-permission-respond permission)))
          (should-not (car answer)))
      (kill-buffer other))))

(ert-deftest quick-ask-permission-asks-in-the-box-and-answers ()
  (qap-test--with-session
    (pcase-let ((`(,permission ,answer)
                 (qap-test--permission "execute" '((command . "git show HEAD:cases.yaml | grep phone")))))
      (let ((quick-ask-permission--shell-buffer shell))
        (should (quick-ask-permission-respond permission)))
      (should-not (car answer))
      (with-current-buffer popup
        (let ((text (buffer-string)))
          (should (string-match-p "Allow tool?" text))
          (should (string-match-p "Inspect the eval cases" text))
          (should (string-match-p "git show HEAD:cases.yaml" text))
          ;; Below the thinking line, above the footer.
          (should (< (string-search "thinking" text) (string-search "Allow tool?" text)
                     (string-search "footer" text))))
        ;; Defaults stay out of evil's way: C-c is free in every state.
        (should (eq (lookup-key mr-x/quick-ask-waiting-map (kbd "C-c 1")) #'quick-ask-permission-allow))
        (should (eq (lookup-key mr-x/quick-ask-waiting-map (kbd "C-c 3")) #'quick-ask-permission-always))
        ;; The prompt labels its keys from the map, so a rebinding shows.
        (should (string-match-p "C-c 1 *allow" (buffer-string)))
        (quick-ask-permission-allow)
        (should (equal (car answer) "allow"))
        (should-not quick-ask-permission--pending)
        (should-not (string-match-p "Allow tool?" (buffer-string)))
        (should (string-match-p "thinking" (buffer-string)))))))

(ert-deftest quick-ask-permission-queues-and-denies ()
  (qap-test--with-session
    (pcase-let ((`(,first ,first-answer) (qap-test--permission "execute" '((command . "one"))))
                (`(,second ,second-answer) (qap-test--permission "edit" '((file_path . "/tmp/x")))))
      (let ((quick-ask-permission--shell-buffer shell))
        (quick-ask-permission-respond first)
        (quick-ask-permission-respond second))
      (with-current-buffer popup
        (should (string-match-p "1 more waiting" (buffer-string)))
        (quick-ask-permission-deny)
        (should (equal (car first-answer) "reject"))
        (should (string-match-p "/tmp/x" (buffer-string)))
        (should-not (string-match-p "more waiting" (buffer-string)))
        (quick-ask-permission-always)
        (should (equal (car second-answer) "always"))
        (should-not (string-match-p "Allow tool?" (buffer-string)))))))

(ert-deftest quick-ask-permission-offers-queued-requests-and-drops-answered-ones ()
  ;; Another answer path (the config's SPC c queue) learns of each request
  ;; and can take it out of the box once it answered.
  (qap-test--with-session
    (let (seen)
      (pcase-let ((`(,permission ,answer) (qap-test--permission "execute" '((command . "ls")))))
        (let ((quick-ask-permission-queued-functions (list (lambda (p) (push p seen))))
              (quick-ask-permission--shell-buffer shell))
          (quick-ask-permission-respond permission))
        (should (equal seen (list permission)))
        (quick-ask-permission-drop permission)
        (with-current-buffer popup
          (should-not quick-ask-permission--pending)
          (should-not (string-match-p "Allow tool?" (buffer-string))))
        (should-not (car answer))))))

(ert-deftest quick-ask-permission-without-a-waiting-box-falls-back ()
  ;; The box was dismissed: the request goes to the normal prompt.
  (qap-test--with-session
    (with-current-buffer popup (setq mr-x/quick-ask--phase 'response))
    (pcase-let ((`(,permission ,answer) (qap-test--permission "execute" '((command . "ls")))))
      (let ((quick-ask-permission--shell-buffer shell))
        (should-not (quick-ask-permission-respond permission)))
      (should-not (car answer)))))

(ert-deftest quick-ask-permission-wraps-the-configured-responder ()
  ;; The configured responder still sees every request Quick Ask leaves.
  (let* ((seen nil)
         (agent-shell-permission-responder-function (lambda (p) (push p seen) nil))
         (wrapped (quick-ask-permission--wrap agent-shell-permission-responder-function)))
    (pcase-let ((`(,permission ,_) (qap-test--permission "execute")))
      (let ((quick-ask-permission--shell-buffer nil))
        (should-not (funcall wrapped permission)))
      (should (equal seen (list permission))))))

(provide 'quick-ask-permission-test)
