;;; mr-x-frames-test.el --- Main-frame lifecycle regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'mr-x-frames)

(defmacro mr-x-frames-test--with-frames (&rest body)
  "Run BODY with a controlled graphical-frame backend.
Batch Emacs cannot create Cocoa frames; keep registration and decoration real."
  (declare (indent 0))
  `(let ((mr-x/main-frame nil)
         (major-pane-home-frame nil)
         (mr-x/frame-counter 0)
         (frames '(child main tty))
         (selected 'main)
         (parameters '((main (graphic . t) (minibuffer . t))
                       (client (graphic . t) (minibuffer . t))
                       (child (graphic . t) (parent-frame . main))
                       (mini (graphic . t) (minibuffer . only))
                       (tooltip (graphic . t) (tooltip . t))
                       (helper (graphic . t) (minibuffer . t)
                               (mr-x-auxiliary-frame . t))
                       (review (graphic . t) (minibuffer . t)
                               (name . "Review diff") (title . "Review diff"))
                       (manager (graphic . t) (minibuffer . t)
                                (name . "Agent Shell Manager"))
                       (tty (graphic . nil)))))
     (cl-letf (((symbol-function 'frame-list) (lambda () frames))
               ((symbol-function 'selected-frame) (lambda () selected))
               ((symbol-function 'frame-live-p)
                (lambda (frame) (and (memq frame frames) t)))
               ((symbol-function 'frame-parameter)
                (lambda (frame parameter)
                  (alist-get parameter
                             (cdr (assq (or frame selected) parameters)))))
               ((symbol-function 'set-frame-parameter)
                (lambda (frame parameter value)
                  (setf (alist-get parameter
                                   (cdr (assq (or frame selected) parameters)))
                        value)))
               ((symbol-function 'display-graphic-p)
                (lambda (&optional frame)
                  (frame-parameter frame 'graphic)))
               ((symbol-function 'frame-parent)
                (lambda (&optional frame)
                  (frame-parameter frame 'parent-frame))))
       ,@body)))

(ert-deftest mr-x-frames-first-gui-ignores-corfu-and-pins-pane ()
  "A completion child must not prevent the original editor becoming main."
  (mr-x-frames-test--with-frames
    (mr-x/decorate-secondary-frame)
    (should (eq major-pane-home-frame 'main))
    (should (eq mr-x/main-frame 'main))
    (should (frame-parameter 'main 'mr-x-main-frame))
    (should-not (frame-parameter 'child 'mr-x-main-frame))))

(ert-deftest mr-x-frames-bootstrap-chooses-oldest-editor ()
  "Loading into an existing session must choose age, not current focus."
  (mr-x-frames-test--with-frames
    (setq frames '(client child main tty) selected 'client)
    (mr-x/initialize-main-frame)
    (should (eq mr-x/main-frame 'main))
    (should (eq major-pane-home-frame 'main))
    (should (eq selected 'client))
    (should-not (frame-parameter 'client 'mr-x-main-frame))))

(ert-deftest mr-x-frames-secondary-client-preserves-main-and-home ()
  "New client frames must not steal main identity or the pane's home."
  (mr-x-frames-test--with-frames
    (mr-x/initialize-main-frame)
    (push 'client frames)
    (setq selected 'client)
    (mr-x/register-frame 'client)
    (mr-x/decorate-secondary-frame)
    (should (eq mr-x/main-frame 'main))
    (should (eq major-pane-home-frame 'main))
    (should (frame-parameter 'main 'mr-x-main-frame))
    (should-not (frame-parameter 'client 'mr-x-main-frame))
    (should (equal (frame-parameter 'client 'title) "Emacs #1"))))

(ert-deftest mr-x-frames-client-decoration-is-idempotent ()
  "Reusing a server frame must not renumber it on every client visit."
  (mr-x-frames-test--with-frames
    (mr-x/initialize-main-frame)
    (push 'client frames)
    (setq selected 'client)
    (mr-x/decorate-secondary-frame)
    (mr-x/decorate-secondary-frame)
    (should (equal (frame-parameter 'client 'title) "Emacs #1"))
    (should (= mr-x/frame-counter 1))))

(ert-deftest mr-x-frames-non-editor-frames-never-claim-main ()
  "Terminal, child, tooltip and minibuffer-only frames cannot become main."
  (mr-x-frames-test--with-frames
    (setq frames '(child mini tooltip tty))
    (dolist (frame frames)
      (setq selected frame)
      (mr-x/register-frame frame)
      (mr-x/decorate-secondary-frame))
    (should-not mr-x/main-frame)
    (should-not major-pane-home-frame)
    (dolist (frame frames)
      (should-not (frame-parameter frame 'mr-x-main-frame)))))

(ert-deftest mr-x-frames-registration-preserves-explicit-pane-unlock ()
  "A secondary client must not override an intentional pane-home unlock."
  (mr-x-frames-test--with-frames
    (mr-x/initialize-main-frame)
    (setq major-pane-home-frame nil)
    (push 'client frames)
    (mr-x/register-frame 'client)
    (should (eq mr-x/main-frame 'main))
    (should-not major-pane-home-frame)))

(ert-deftest mr-x-frames-reinitialization-keeps-main-and-clears-stale-markers ()
  "Live reload must keep the registered frame and leave exactly one marker."
  (mr-x-frames-test--with-frames
    (setq frames '(client child main tty) mr-x/main-frame 'client)
    (set-frame-parameter 'main 'mr-x-main-frame t)
    (set-frame-parameter 'child 'mr-x-main-frame t)
    (mr-x/initialize-main-frame)
    (should (eq mr-x/main-frame 'client))
    (should (eq major-pane-home-frame 'client))
    (should-not (frame-parameter 'main 'mr-x-main-frame))
    (should-not (frame-parameter 'child 'mr-x-main-frame))
    (should (frame-parameter 'client 'mr-x-main-frame))))

(ert-deftest mr-x-frames-main-deletion-promotes-oldest-survivor ()
  "The deletion hook runs before removal, so it must exclude the dying frame."
  (mr-x-frames-test--with-frames
    (setq frames '(client child main tty))
    (mr-x/initialize-main-frame)
    (mr-x/main-frame-deleted 'main)
    (should (eq mr-x/main-frame 'client))
    (should (eq major-pane-home-frame 'client))
    (should-not (frame-parameter 'main 'mr-x-main-frame))
    (should (frame-parameter 'client 'mr-x-main-frame))
    (should (frame-parameter 'client 'undecorated-round))
    (should-not (frame-parameter 'client 'title))))

(ert-deftest mr-x-frames-last-editor-deletion-allows-a-new-main ()
  "Closing the last editor clears its identity; a later editor replaces it."
  (mr-x-frames-test--with-frames
    (mr-x/initialize-main-frame)
    (mr-x/main-frame-deleted 'main)
    (should-not mr-x/main-frame)
    (should-not major-pane-home-frame)
    (setq frames '(client child tty))
    (mr-x/register-frame 'client)
    (should (eq mr-x/main-frame 'client))
    (should (eq major-pane-home-frame 'client))))

(ert-deftest mr-x-frames-secondary-deletion-leaves-main-alone ()
  "Deleting a secondary frame must not change main or a manual home choice."
  (mr-x-frames-test--with-frames
    (setq frames '(client child main tty))
    (mr-x/initialize-main-frame)
    (setq major-pane-home-frame 'client)
    (mr-x/main-frame-deleted 'client)
    (should (eq mr-x/main-frame 'main))
    (should (eq major-pane-home-frame 'client))))

(ert-deftest mr-x-frames-main-deletion-never-promotes-dedicated-helpers ()
  "Review, manager and explicitly auxiliary frames keep their roles and titles."
  (mr-x-frames-test--with-frames
    (setq frames '(manager helper review child main tty))
    (mr-x/initialize-main-frame)
    (mr-x/main-frame-deleted 'main)
    (should-not mr-x/main-frame)
    (should-not major-pane-home-frame)
    (should (equal (frame-parameter 'review 'title) "Review diff"))
    (dolist (frame '(manager helper review))
      (should-not (frame-parameter frame 'mr-x-main-frame)))
    (setq frames '(client manager helper review child tty))
    (mr-x/register-frame 'client)
    (should (eq mr-x/main-frame 'client))
    (should (eq major-pane-home-frame 'client))))

(defmacro mr-x-frames-test--with-pane (&rest body)
  "Run BODY with real windows and an isolated active conversation."
  (declare (indent 0))
  `(progn
     (require 'face-remap)
     (require 'major-pane)
     (save-window-excursion
       (let* ((chat (generate-new-buffer " *main-frame-chat*"))
              (work (generate-new-buffer " *main-frame-work*"))
              (mr-x/main-frame (selected-frame))
              (major-pane-home-frame mr-x/main-frame)
              (major-pane--state
               (major-pane--make-state :mode 'hidden
                                      :active chat :conversations (list chat)))
              (major-pane-direction 'left)
              (display-buffer-alist nil)
              (display-buffer-overriding-action nil)
              (display-buffer-base-action nil))
         (unwind-protect
             (progn
               (delete-other-windows)
               (set-window-dedicated-p (selected-window) nil)
               (set-window-parameter (selected-window) 'major-pane nil)
               (set-window-buffer (selected-window) work)
               ;; Only the graphical capability is external to batch Emacs.
               (cl-letf (((symbol-function 'display-graphic-p)
                          (lambda (&optional _) t)))
                 ,@body))
           (dolist (window (window-list nil 'nomini))
             (set-window-dedicated-p window nil)
             (set-window-parameter window 'major-pane nil))
           (mapc #'kill-buffer (list chat work)))))))

(ert-deftest mr-x-frames-focus-opens-active-chat-independent-of-project ()
  "A splash buffer's directory must not replace the existing active chat."
  (mr-x-frames-test--with-pane
    (let ((default-directory temporary-file-directory))
      (mr-x/focus-ai-window))
    (should (eq (window-buffer (selected-window)) chat))
    (should (eq (major-pane-state-active major-pane--state) chat))
    (should (get-buffer-window work))))

(ert-deftest mr-x-frames-focus-never-hides-a-visible-pane ()
  "Repeated focus requests must keep the conversation and pane displayed."
  (mr-x-frames-test--with-pane
    (let ((pane (major-pane-display-buffer-action chat nil)))
      (select-window (get-buffer-window work))
      (mr-x/focus-ai-window)
      (mr-x/focus-ai-window)
      (should (window-live-p pane))
      (should (eq (selected-window) pane))
      (should (eq (window-buffer pane) chat))
      (should (eq (major-pane-state-mode major-pane--state) 'side)))))

(ert-deftest mr-x-frames-focus-restores-conversation-in-reused-pane ()
  "A marked pane showing a work buffer must return to its active conversation."
  (mr-x-frames-test--with-pane
    (let ((pane (major-pane-display-buffer-action chat nil)))
      (major-pane-capture-buffer work)
      ;; A restored layout can retain the pane marker before chrome refresh.
      (set-window-parameter pane 'major-pane t)
      (mr-x/focus-ai-window)
      (should (eq (window-buffer (selected-window)) chat))
      (should (eq (major-pane-state-active major-pane--state) chat)))))

(ert-deftest mr-x-frames-focus-keeps-an-empty-launcher-open ()
  "Focusing with no conversations shows the launcher and never toggles it off."
  (mr-x-frames-test--with-pane
    (let ((major-pane--state (major-pane--make-state))
          (major-pane-launcher-buffer-name " *main-frame-test-launcher*"))
      (unwind-protect
          (progn
            (mr-x/focus-ai-window)
            (let ((launcher (selected-window)))
              (mr-x/focus-ai-window)
              (should (window-live-p launcher))
              (should (eq (selected-window) launcher))
              (should (eq (buffer-local-value
                           'major-mode (window-buffer launcher))
                          'major-pane-launcher-mode))))
        (when-let ((buffer (get-buffer major-pane-launcher-buffer-name)))
          (dolist (window (get-buffer-window-list buffer nil t))
            (set-window-dedicated-p window nil))
          (kill-buffer buffer))))))

(ert-deftest mr-x-frames-gui-lifecycle-and-cross-frame-focus ()
  "Real Cocoa frames preserve main, raise it for AI focus and replace it on close."
  :tags '(gui)
  (skip-unless (display-graphic-p))
  (require 'major-pane)
  (let* ((original-frame (selected-frame))
         (real-frame-list (symbol-function 'frame-list))
         (real-input-focus (symbol-function 'select-frame-set-input-focus))
         (mr-x/main-frame nil)
         (major-pane-home-frame nil)
         (major-pane-direction 'left)
         (chat (generate-new-buffer " *main-frame-gui-chat*"))
         (work (generate-new-buffer " *main-frame-gui-work*"))
         (major-pane--state
          (major-pane--make-state :mode 'hidden
                                 :active chat :conversations (list chat)))
         (display-buffer-alist nil)
         (display-buffer-overriding-action nil)
         (display-buffer-base-action nil)
         first client newest child focused)
    (unwind-protect
        ;; Restrict discovery to this test's frames; preserve every existing
        ;; sandbox frame and pane.  Creation, windows, deletion and focus are real.
        (cl-letf (((symbol-function 'frame-list)
                   (lambda ()
                     (seq-filter
                      (lambda (frame)
                        (frame-parameter frame 'mr-x-frame-test))
                      (funcall real-frame-list)))))
          (setq first (make-frame '((name . "Main frame test")
                                    (mr-x-frame-test . t)
                                    (visibility . nil) (no-focus-on-map . t)
                                    (width . 100) (height . 35))))
          (should (eq mr-x/main-frame first))
          (should (eq major-pane-home-frame first))
          (setq child (make-frame `((parent-frame . ,first)
                                    (mr-x-frame-test . t) (minibuffer . nil)
                                    (visibility . nil) (no-focus-on-map . t)
                                    (width . 20) (height . 5)))
                client (make-frame '((name . "Client frame test")
                                     (mr-x-frame-test . t)
                                     (visibility . nil) (no-focus-on-map . t)
                                     (width . 100) (height . 35)))
                newest (make-frame '((name . "Newest frame test")
                                     (mr-x-frame-test . t)
                                     (visibility . nil) (no-focus-on-map . t)
                                     (width . 100) (height . 35))))
          (should (eq mr-x/main-frame first))
          (should-not (frame-parameter child 'mr-x-main-frame))
          (with-selected-frame first
            (let ((ignore-window-parameters t))
              (set-window-dedicated-p (selected-window) nil)
              (delete-other-windows))
            (set-window-buffer (selected-window) work)
            (major-pane-display-buffer-action chat nil))
          (select-frame client)
          (let ((ignore-window-parameters t))
            (set-window-dedicated-p (selected-window) nil)
            (delete-other-windows))
          (set-window-buffer (selected-window) work)
          (cl-letf (((symbol-function 'select-frame-set-input-focus)
                     (lambda (frame &rest args)
                       (push frame focused)
                       (apply real-input-focus frame args))))
            (mr-x/focus-ai-window)
            (mr-x/focus-ai-window))
          (should (equal focused (list first)))
          (should (eq (selected-frame) first))
          (should (eq (window-buffer (selected-window)) chat))
          (should (eq (major-pane-state-active major-pane--state) chat))
          (should (get-buffer-window work client))
          (delete-frame first t)
          (should (eq mr-x/main-frame client))
          (should (eq major-pane-home-frame client))
          (should (frame-parameter client 'mr-x-main-frame))
          (should-not (frame-parameter newest 'mr-x-main-frame))
          ;; Cleanup still runs through the real deletion hook and is scoped
          ;; to the frames created above.
          (dolist (frame (list child newest client))
            (when (frame-live-p frame) (delete-frame frame t))))
      (dolist (frame (list child newest client first))
        (when (frame-live-p frame) (delete-frame frame t)))
      (when (frame-live-p original-frame)
        (select-frame-set-input-focus original-frame))
      (mapc #'kill-buffer (list chat work)))))

(provide 'mr-x-frames-test)
;;; mr-x-frames-test.el ends here
