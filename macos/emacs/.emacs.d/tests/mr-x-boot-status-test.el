;;; mr-x-boot-status-test.el --- Tests for the sketchybar boot status -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/mr-x-boot-status"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)
(defvar elpaca-after-init-time)
(defvar mr-x-boot-status-test--ran nil)

(ert-deftest mr-x-boot-status-label-plain ()
  "Without the voice the label names the Elpaca step, the count and the time."
  (let ((mr-x/boot-status-voice nil))
    (should (equal (mr-x/boot-status--label
                    '(:phase packages :package magit :step byte-compilation :done 34 :total 120)
                    18)
                   "byte-compilation magit · 34/120 · 18s"))
    (should (equal (mr-x/boot-status--label '(:phase init) 0) "loading init · 0s"))
    (should (equal (mr-x/boot-status--label '(:phase restore :done 3 :total 12) 50)
                   "restoring chats · 3/12 · 50s"))))

(ert-deftest mr-x-boot-status-label-voice-keeps-facts ()
  "The cacodemon voice swaps the verb but keeps the package, count and time."
  (let ((mr-x/boot-status-voice t)
        (mr-x/boot-status--verb "devouring")
        (mr-x/boot-status--verb-subject "magit"))
    (should (equal (mr-x/boot-status--label
                    '(:phase packages :package magit :step activation :done 34 :total 120)
                    18)
                   "devouring magit · 34/120 · 18s"))))

(ert-deftest mr-x-boot-status-verb-changes-with-subject ()
  "A new verb is drawn only when the subject changes, so the label does not flicker."
  (let ((mr-x/boot-status--verb nil)
        (mr-x/boot-status--verb-subject nil))
    (let ((first (mr-x/boot-status--verb-for 'magit)))
      (should (member first mr-x/boot-status-verbs))
      (dotimes (_ 10) (should (equal (mr-x/boot-status--verb-for 'magit) first))))))

(ert-deftest mr-x-boot-status-phase-prefers-restore-then-packages ()
  "Phase: init before after-init, then packages while Elpaca works, then restore."
  (cl-letf (((symbol-function 'mr-x/boot-status--elpaca-progress)
             (lambda () '(:done 3 :total 5 :package vterm :step building)))
            ((symbol-function 'mr-x/boot-status--restore-progress) (lambda () nil)))
    (let ((after-init-time nil))
      (should (eq (plist-get (mr-x/boot-status--phase) :phase) 'init)))
    (let ((after-init-time (current-time)) (elpaca-after-init-time nil))
      (should (equal (mr-x/boot-status--phase)
                     '(:phase packages :done 3 :total 5 :package vterm :step building))))
    (let ((after-init-time (current-time)) (elpaca-after-init-time (current-time)))
      (should-not (mr-x/boot-status--phase))))
  (cl-letf (((symbol-function 'mr-x/boot-status--restore-progress)
             (lambda () '(:done 1 :total 4))))
    (let ((after-init-time (current-time)) (elpaca-after-init-time (current-time)))
      (should (equal (mr-x/boot-status--phase) '(:phase restore :done 1 :total 4))))))

(ert-deftest mr-x-boot-status-tick-pushes-progress-then-ready ()
  "A tick pushes the live label; the first idle tick pushes ready and stops."
  (let (pushed phase (mr-x/boot-status-voice nil) (mr-x/boot-status--timer 'fake)
        (mr-x/boot-status--booting t)
        (mr-x/boot-status--summary-file (make-temp-file "boot-status")))
    (unwind-protect
        (cl-letf (((symbol-function 'mr-x/boot-status--phase) (lambda () phase))
                  ((symbol-function 'mr-x/boot-status--elapsed) (lambda () 42))
                  ((symbol-function 'mr-x/boot-status--push)
                   (lambda (state label) (push (list state label) pushed)))
                  ((symbol-function 'cancel-timer) #'ignore))
          (setq phase '(:phase init))
          (mr-x/boot-status--tick)
          (should (equal (car pushed) '("booting" "loading init · 42s")))
          (setq phase nil)
          (mr-x/boot-status--tick)
          (should (equal (car pushed) '("ready" "ready in 42s")))
          (should-not mr-x/boot-status--timer)
          (should (string-match-p "^EMACS_BOOT_TOTAL=42$"
                                  (with-temp-buffer
                                    (insert-file-contents mr-x/boot-status--summary-file)
                                    (buffer-string)))))
      (delete-file mr-x/boot-status--summary-file))))

(ert-deftest mr-x-boot-status-instrumented-configs-report-progress ()
  "Queued config bodies announce themselves in run order and still run."
  (let* ((steps nil)
         ;; Elpaca stores queue forms newest first and runs them after nreverse.
         (forms (list (cons 'magit `((push 'magit-config mr-x-boot-status-test--ran)))
                      (cons 'vterm `((push 'vterm-config mr-x-boot-status-test--ran)))))
         (mr-x/boot-status--durations nil))
    (setq mr-x-boot-status-test--ran nil)
    (cl-letf (((symbol-function 'mr-x/boot-status--config-step)
               (lambda (id i n) (push (list id i n) steps))))
      (mr-x/boot-status--instrument-forms forms)
      (dolist (form (nreverse forms))
        (eval `(progn ,@(cdr form)) t)))
    (should (equal (reverse steps) '((vterm 1 2) (magit 2 2))))
    (should (equal mr-x-boot-status-test--ran '(magit-config vterm-config)))))

(ert-deftest mr-x-boot-status-config-phase-and-slowest ()
  "While configs run the phase names the package; durations rank the slowest."
  (let ((mr-x/boot-status--config '(:package magit :done 34 :total 127))
        (after-init-time (current-time))
        (elpaca-after-init-time nil)
        (mr-x/boot-status-voice nil))
    (cl-letf (((symbol-function 'mr-x/boot-status--restore-progress) (lambda () nil)))
      (should (equal (mr-x/boot-status--label (mr-x/boot-status--phase) 18)
                     "configuring magit · 34/127 · 18s"))))
  (let ((mr-x/boot-status--durations '((a . 0.2) (b . 20.4) (c . 3.0) (d . 5.6))))
    (should (equal (mr-x/boot-status--slowest 3) "b 20s, d 6s, c 3s"))))

(ert-deftest mr-x-boot-status-disabled-outside-main-daemon ()
  "Batch runs and the sandbox daemon never touch the bar."
  (let (called)
    (cl-letf (((symbol-function 'start-process) (lambda (&rest _) (setq called t))))
      (mr-x/boot-status--push "booting" "x")
      (should-not called))))

;;; mr-x-boot-status-test.el ends here
