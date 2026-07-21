;;; -*- lexical-binding: t -*-

      (use-package agent-shell
        :ensure (:host github :repo "xenodium/agent-shell")
        :demand t
        :after (acp shell-maker)
        :hook ((agent-shell-mode . orgtbl-mode)  ;; Auto-align org tables
               (agent-shell-mode . display-line-numbers-mode)  ;; Show line numbers
               (agent-shell-mode . (lambda ()
                                     ;; Make sent input text green like strings
                                     (face-remap-add-relative 'comint-highlight-input
                                                              :foreground "#b8bb26")))
               (agent-shell-mode . (lambda ()
                                     ;; Make prompt symbol gruvbox yellow
                                     (face-remap-add-relative 'comint-highlight-prompt
                                                              :foreground "#fabd2f")))
    )
        :config
        ;; Rebind: S-<tab> cycles mode, C-<tab> is free for popper
        (define-key agent-shell-mode-map (kbd "<backtab>") #'agent-shell-cycle-session-mode)
        (define-key agent-shell-mode-map (kbd "C-<tab>") nil)
        
        ;; CMD+Enter to submit prompt from normal mode (lazy mode)
        (evil-define-key 'normal agent-shell-mode-map (kbd "s-<return>") #'shell-maker-submit)

        ;; Smart insert/append - jump to prompt if in history area
        (defun mr-x/agent-shell-smart-insert ()
          "Enter insert mode, jumping to prompt if not already there."
          (interactive)
          (cond
           ((shell-maker-point-at-last-prompt-p)
            (evil-insert-state))
           (t
            (goto-char (point-max))
            (if (shell-maker-point-at-last-prompt-p)
                (evil-insert-state)
              (message "Shell is busy — can't insert yet")))))

        (defun mr-x/agent-shell-smart-append ()
          "Enter append mode, jumping to prompt if not already there."
          (interactive)
          (cond
           ((shell-maker-point-at-last-prompt-p)
            (evil-append 1))
           (t
            (goto-char (point-max))
            (if (shell-maker-point-at-last-prompt-p)
                (evil-append 1)
              (message "Shell is busy — can't insert yet")))))

        (defun mr-x/agent-shell-smart-paste ()
          "Paste text or image from clipboard, jumping to prompt if not already there."
          (interactive)
          (unless (shell-maker-point-at-last-prompt-p)
            (goto-char (point-max)))
          (if (shell-maker-point-at-last-prompt-p)
              (call-interactively #'agent-shell-yank-dwim)
            (message "Shell is busy — can't paste yet")))

        (evil-define-key 'normal agent-shell-mode-map
          (kbd "i") #'mr-x/agent-shell-smart-insert
          (kbd "a") #'mr-x/agent-shell-smart-append
          (kbd "A") #'mr-x/agent-shell-smart-append
          (kbd "o") #'mr-x/agent-shell-smart-append
          (kbd "O") #'mr-x/agent-shell-smart-append
          (kbd "p") #'mr-x/agent-shell-smart-paste)

        ;; Context-sensitive permission keys in normal mode
        ;; When permission pending: respond directly
        ;; When no permission: pass to evil's digit-argument for motion counts
        (defun mr-x/agent-shell-permission-or-digit (key action)
          "If permission pending in current buffer, run ACTION. Otherwise pass KEY as digit-argument."
          (if (and mr-x/pending-permissions-queue
                   (cl-some (lambda (p) (eq (current-buffer) (plist-get p :buffer)))
                            mr-x/pending-permissions-queue))
              (funcall action)
            ;; No permission pending - let evil handle as count prefix
            (let ((last-command-event (string-to-char key)))
              (call-interactively #'digit-argument))))

        (evil-define-key 'normal agent-shell-mode-map (kbd "1")
          (lambda () (interactive) (mr-x/agent-shell-permission-or-digit "1" #'mr-x/agent-shell-allow)))
        (evil-define-key 'normal agent-shell-mode-map (kbd "2")
          (lambda () (interactive) (mr-x/agent-shell-permission-or-digit "2" #'mr-x/agent-shell-deny)))
        (evil-define-key 'normal agent-shell-mode-map (kbd "3")
          (lambda () (interactive) (mr-x/agent-shell-permission-or-digit "3" #'mr-x/agent-shell-allow-always)))
        (evil-define-key 'normal agent-shell-mode-map (kbd "0")
          (lambda () (interactive)
            (cond
             ;; Permission pending - view diff
             ((and mr-x/pending-permissions-queue
                   (cl-some (lambda (p) (eq (current-buffer) (plist-get p :buffer)))
                            mr-x/pending-permissions-queue))
              (mr-x/agent-shell-view-diff))
             ;; Count prefix in progress (e.g. 10j) - append 0
             (current-prefix-arg
              (let ((last-command-event ?0))
                (call-interactively #'digit-argument)))
             ;; Default - beginning of line
             (t (call-interactively #'evil-beginning-of-line)))))

        ;; Clear prompt with CMD+backspace
        (defun mr-x/agent-shell-clear-prompt ()
          "Clear the current prompt input in agent-shell."
          (interactive)
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (delete-region (comint-line-beginning-position) (point-max))))

        (evil-define-key 'normal agent-shell-mode-map (kbd "s-<backspace>") #'mr-x/agent-shell-clear-prompt)
        (evil-define-key 'insert agent-shell-mode-map (kbd "s-<backspace>") #'mr-x/agent-shell-clear-prompt)

      ;; Global CMD+backspace - kill to beginning of line
      (defun mr-x/kill-to-line-beginning ()
        "Kill from point to beginning of line."
        (interactive)
        (kill-line 0))

      (global-set-key (kbd "s-<backspace>") #'mr-x/kill-to-line-beginning)

        ;; TODO: Fix buffer rename - causes "Wrong type argument: stringp, nil" error
        ;; Remove "Agent" from buffer name: "Claude Agent @ dir" -> "Claude @ dir"
        ;; Runs after shell-maker--initialize so markers are set up
        ;; (defun mr-x/agent-shell-rename-buffer (&rest _)
        ;;   "Remove Agent from agent-shell buffer names."
        ;;   (when (and (derived-mode-p 'agent-shell-mode)
        ;;              (string-match "\\(.*\\) Agent @ \\(.*\\)" (buffer-name)))
        ;;     (let* ((base-name (format "*%s @ %s*"
        ;;                               (match-string 1 (buffer-name))
        ;;                               (match-string 2 (buffer-name))))
        ;;            ;; rename-buffer returns actual name (includes <N> suffix if needed)
        ;;            (actual-name (rename-buffer base-name t)))
        ;;       ;; Use actual-name so shell-maker can find the buffer
        ;;       (setq-local shell-maker--buffer-name-override actual-name))))
        ;; (advice-add 'shell-maker--initialize :after #'mr-x/agent-shell-rename-buffer)

        ;; Use text header style - shows initialization status
        ;; (nil header + nil modeline = no feedback when session is initializing = errors)
        (setq agent-shell-header-style 'text)
        (setq agent-shell-show-welcome-message nil)
        
        ;; Enable @ and / completion (file paths and slash commands)
        (setq agent-shell-file-completion-enabled t)
        
        ;; Disable modeline info (header is enough for init feedback)
        (defun agent-shell--mode-line-format () nil)

        ;; Enable syntax highlighting in code blocks
        (setq agent-shell-highlight-blocks t)
        
        ;; Map language names to tree-sitter modes for syntax highlighting
        (add-to-list 'markdown-overlays-language-mapping '("typescript" . "typescript-ts"))
        (add-to-list 'markdown-overlays-language-mapping '("tsx" . "tsx-ts"))
        (add-to-list 'markdown-overlays-language-mapping '("javascript" . "js-ts"))
        (add-to-list 'markdown-overlays-language-mapping '("js" . "js-ts"))
        
        ;; Random icons for code block copy button + language box styling
        (defvar mr-x/code-block-icons
          '("🔥" "🚀" "💀" "👾" "🤖" "⚡" "✨" "🎯" "🧠" "💅" "🦄" "👀" "🍕" "🌶️" "🎸" "🎮"
            "💎" "🌈" "🌙" "⭐" "🍄" "🎪" "🎨" "🎵" "🎲" "🃏" "🎭" "🎬" "📡" "🔮" "💣" "🧨"
            "🏴‍☠️" "👻" "💀" "🎃" "🦇" "🕷️" "🐉" "🦖" "🦑" "🐙" "🦈" "🐺" "🦊" "🐸" "🐍" "🦎"
            "⚔️" "🗡️" "🏹" "🛡️" "💊" "🧪" "🔬" "🧬" "💻" "🖥️" "⌨️" "🕹️" "📟" "📺" "📀" "💾"
            "🌀" "🌊" "🔱" "⚓" "☠️" "🏁" "🚩" "🎌" "⛳" "🧿" "🪬" "♠️" "♣️" "♥️" "♦️"
            "🀄" "🎴" "🔔" "🎺" "🥁" "🪘" "🎻" "🪕" "🎷" "🪗" "🎹"
            "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" ""
            "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
          "Random icons for code block copy button.")
        
        (defun mr-x/random-code-icon ()
          "Return a random icon from the list."
          (nth (random (length mr-x/code-block-icons)) mr-x/code-block-icons))
        
        (defun mr-x/agent-shell-style-code-block-header (quotes1-start quotes1-end lang lang-start lang-end body-start body-end quotes2-start quotes2-end)
          "Customize copy icon and language box styling."
          (dolist (ov (overlays-in quotes1-start quotes1-end))
            (when (overlay-get ov 'display)
              (overlay-put ov 'display
                           (propertize (concat (mr-x/random-code-icon) " ")
                                       'pointer 'hand
                                       'keymap (overlay-get ov 'keymap)))))
          (unless (eq lang-start lang-end)
            (dolist (ov (overlays-in lang-start lang-end))
              (when (equal (overlay-get ov 'face) '(:box t))
                (overlay-put ov 'face
                             '(:background "#689d6a" :foreground "#1d2021" :box nil :weight bold))))))
        
        (advice-add 'markdown-overlays--fontify-source-block :after #'mr-x/agent-shell-style-code-block-header)

        ;; DISABLED: Testing upstream indent-text (v0.42.1 uses display properties
        ;; instead of manual text insertion — better for copy/paste behavior).
        ;; Re-enable if upstream breaks syntax-highlighted code block formatting.
        ;; (with-eval-after-load 'agent-shell-ui
        ;;   (defun agent-shell-ui--indent-text (text &optional indent-string)
        ;;     "Indent TEXT preserving text properties."
        ;;     (when text
        ;;       (let ((indent (or indent-string "  "))
        ;;             (result (copy-sequence text))
        ;;             (offset 0))
        ;;         (unless (string-empty-p result)
        ;;           (setq result (concat indent result))
        ;;           (setq offset (length indent)))
        ;;         (let ((pos 0))
        ;;           (while (setq pos (string-match "\n" result pos))
        ;;             (setq pos (1+ pos))
        ;;             (when (and (< pos (length result))
        ;;                        (not (eq (aref result pos) ?\n)))
        ;;               (setq result (concat (substring result 0 pos)
        ;;                                    indent
        ;;                                    (substring result pos)))
        ;;               (setq pos (+ pos (length indent))))))
        ;;         result))))

        ;; Custom icons
        (setq agent-shell-permission-icon "\uf259")
        (setq agent-shell-thought-process-icon "\uf29d")
        (setq agent-shell-prefer-session-resume nil)

        ;; Fix keybindings in agent-shell diff view (evil-mode conflicts)
        ;; The diff view uses buttons - we need to make sure evil doesn't intercept keys
        (defun mr-x/agent-shell-diff-mode-setup ()
          "Setup keybindings for agent-shell diff buffers.
    Uses evil normal state for full vim navigation (j/k/C-d/C-u/visual mode)
    with diff actions bound as evil local keys."
          (when (string-match-p "\\*agent-shell.*diff\\*" (buffer-name))
            (evil-normal-state)
            ;; Diff navigation and actions in normal state
            (evil-local-set-key 'normal (kbd "n") #'diff-hunk-next)
            (evil-local-set-key 'normal (kbd "p") #'diff-hunk-prev)
            (evil-local-set-key 'normal (kbd "q") #'kill-current-buffer)))
        (add-hook 'diff-mode-hook #'mr-x/agent-shell-diff-mode-setup)

        (defun mr-x/agent-shell-send-region-no-switch ()
          "Send region to agent-shell without switching windows."
          (interactive)
          (let ((shell-buffer (agent-shell--shell-buffer)))
            (agent-shell-insert
             :text (agent-shell--get-region-context
                    :deactivate t
                    :agent-cwd (with-current-buffer shell-buffer
                                 (agent-shell-cwd)))
             :shell-buffer shell-buffer
             :no-focus t)))

        (defun mr-x/agent-panel-spawn-test-env ()
          "Spawn test agent-shell buffers for picker testing.
Resolves agent config once, overrides session strategy to skip
the session picker, then spawns shells staggered 3s apart."
          (interactive)
          (let ((config (or (agent-shell--resolve-preferred-config)
                            (agent-shell-select-config :prompt "Agent for test shells: ")
                            (error "No agent config")))
                (dirs '("~/.dotfiles/" "~/roaming/" "~/roaming/projects/major-pane/")))
            (cl-loop for dir in dirs
                     for delay from 0 by 3
                     do (run-at-time delay nil
                          (lambda (d c)
                            (let ((default-directory (expand-file-name d))
                                  (agent-shell-session-strategy 'new))
                              (agent-shell--start :config c :no-focus t :new-session t)))
                          dir config))
            (message "Spawning %d test shells (3s apart)..." (length dirs))))

        ;; DEPRECATED: Replaced by upstream agent-shell-yank-dwim in v0.42.1
        ;; Kept as reference — remove once upstream is confirmed working
        ;; (defun mr-x/agent-shell-send-clipboard ()
        ;;   "Send clipboard contents to agent-shell (text or image)."
        ;;   (interactive)
        ;;   (let* ((screenshots-dir (expand-file-name ".agent-shell/screenshots"
        ;;                                             (agent-shell-cwd)))
        ;;          (screenshot-path (expand-file-name
        ;;                            (format-time-string "clipboard-%Y%m%d-%H%M%S.png")
        ;;                            screenshots-dir)))
        ;;     (make-directory screenshots-dir t)
        ;;     (if (and (executable-find "pngpaste")
        ;;              (zerop (call-process "pngpaste" nil nil nil screenshot-path)))
        ;;         (agent-shell-insert
        ;;          :text (agent-shell--processed-files :files (list screenshot-path)))
        ;;       (let ((clipboard (gui-get-selection 'CLIPBOARD)))
        ;;         (if (and clipboard (not (string-empty-p clipboard)))
        ;;             (agent-shell-insert :text clipboard)
        ;;           (user-error "Clipboard is empty (no image or text)"))))))

        (defun mr-x/agent-shell-toggle ()
          "Toggle agent shell display (fixed to find project shells)."
          (interactive)
          (let ((shell-buffer (cond
                               (agent-shell-prefer-viewport-interaction
                                (agent-shell-viewport--buffer))
                               ((derived-mode-p 'agent-shell-mode)
                                (current-buffer))
                               ((or (derived-mode-p 'agent-shell-viewport-view-mode)
                                    (derived-mode-p 'agent-shell-viewport-edit-mode))
                                (agent-shell--current-shell))
                               (t (seq-first (agent-shell-project-buffers))))))
            (unless shell-buffer
              (user-error "No agent shell buffers available for current project"))
            (if-let ((window (get-buffer-window shell-buffer)))
                (if (and (> (count-windows) 1)
                         (not (bound-and-true-p transient--prefix)))
                    (delete-window window)
                  (switch-to-prev-buffer))
              (agent-shell--display-buffer shell-buffer))))

        (defun mr-x/focus-ai-window ()
          "Focus the agent-shell window if visible, otherwise show a message."
          (interactive)
          (let ((ai-window nil))
            (walk-windows
             (lambda (w)
               (when (and (not ai-window)
                          (eq (buffer-local-value 'major-mode (window-buffer w))
                              'agent-shell-mode))
                 (setq ai-window w))))
            (if ai-window
                (select-window ai-window)
              (mr-x/agent-shell-toggle))))

        (defun mr-x/taskmaster-next-task ()
          "Ask agent-shell for the next taskmaster task."
          (interactive)
          (mr-x/focus-ai-window)
          (goto-char (point-max))
          (insert "What's the next task?")
          (shell-maker-submit))

        (defun mr-x/taskmaster-summary ()
          "Ask for a summary of taskmaster tags and status."
          (interactive)
          (mr-x/focus-ai-window)
          (goto-char (point-max))
          (insert "Please provide a succinct summary of the current taskmaster tags and their corresponding status.")
          (shell-maker-submit))

        (defun mr-x/taskmaster-get-project-root ()
          "Get project root, prompting if detection fails."
          (let ((root (projectile-project-root)))
            (if (and root (not (string-match-p "roaming/$\\|roaming/projects/$" root)))
                root
              (read-directory-name "Select project root: "))))

        (defun mr-x/taskmaster-get-tags (project-root)
          "Get list of Task Master tags for PROJECT-ROOT.
    Parses tasks.json directly instead of using CLI."
          (let ((tasks-file (expand-file-name ".taskmaster/tasks/tasks.json" project-root)))
            (if (file-exists-p tasks-file)
                (condition-case nil
                    (let* ((json-object-type 'alist)
                           (json-key-type 'symbol)
                           (data (json-read-file tasks-file)))
                      (or (mapcar (lambda (entry) (symbol-name (car entry))) data)
                          '("master")))
                  (error '("master")))
              '("master"))))

        (defun mr-x/get-agent-shell-for-project (project-root)
          "Get agent-shell buffer for PROJECT-ROOT, or prompt to select."
          (let* ((all-shells (seq-filter
                              (lambda (b)
                                (with-current-buffer b (eq major-mode 'agent-shell-mode)))
                              (buffer-list)))
                 (project-shell (seq-find
                                 (lambda (b)
                                   (string-prefix-p project-root
                                                    (buffer-local-value 'default-directory b)))
                                 all-shells)))
            (cond
             (project-shell project-shell)
             ((= (length all-shells) 1) (car all-shells))
             ((> (length all-shells) 1)
              (get-buffer (completing-read "Select agent-shell: " (mapcar #'buffer-name all-shells))))
             (t (error "No agent-shell buffers found. Start one first.")))))

        (defun mr-x/taskmaster-add-task ()
          "Add a new task to Task Master via agent-shell."
          (interactive)
          (let* ((project-root (mr-x/taskmaster-get-project-root))
                 (tags (mr-x/taskmaster-get-tags project-root))
                 (selected-tag (completing-read "Select tag: " tags))
                 (task-description (condition-case nil
                                       (mr-x/ask-user-popup
                                        "Task description"
                                        (format "Adding task to **%s** tag in `%s`"
                                                selected-tag (file-name-nondirectory
                                                              (directory-file-name project-root))))
                                     (error nil)))
                 (shell-buffer (when task-description
                                 (mr-x/get-agent-shell-for-project project-root))))
            (when shell-buffer
              (with-current-buffer shell-buffer
                (goto-char (point-max))
                (insert (format "Use mcp__task-master-ai__add_task with tag=\"%s\" to add this task: %s"
                                selected-tag task-description))
                (shell-maker-submit))
              (message "Task submitted to %s" (buffer-name shell-buffer)))))


        (defun mr-x/agent-shell-test-prompt ()
          "Send a random test prompt to exercise agent-shell functionality."
          (interactive)
          (mr-x/focus-ai-window)
          (goto-char (point-max))
          (insert "I am testing the functionality of agent-shell and the Emacs application. Modify random code files in this project - the actual code changes don't matter, just make some edits to test the tool calling flow.")
          (shell-maker-submit))

        ;; ============================================
        ;; Bash Command Watcher
        ;; ============================================

        (defvar mr-x/bash-watcher-buffer "*Bash Watcher*"
          "Buffer name for watching Bash commands.")

        (defun mr-x/bash-watcher-log (type &rest args)
          "Log to bash watcher buffer. TYPE is 'command, 'output, or 'separator."
          (let ((buf (get-buffer-create mr-x/bash-watcher-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (let ((inhibit-read-only t))
                (pcase type
                  ('command
                   (insert (propertize (format "\n[%s] " (format-time-string "%H:%M:%S"))
                                       'face 'font-lock-comment-face))
                   (insert (propertize "$ " 'face 'font-lock-keyword-face))
                   (insert (propertize (car args) 'face 'font-lock-string-face))
                   (insert "\n"))
                  ('output
                   (insert (car args))
                   (unless (string-suffix-p "\n" (car args))
                     (insert "\n")))
                  ('separator
                   (insert (propertize (make-string 60 ?─) 'face 'font-lock-comment-face))
                   (insert "\n"))))
              (unless (derived-mode-p 'special-mode)
                (special-mode)))))

        (defun mr-x/bash-watcher-toggle ()
          "Toggle the Bash watcher buffer."
          (interactive)
          (if-let ((win (get-buffer-window mr-x/bash-watcher-buffer)))
              (delete-window win)
            (display-buffer (get-buffer-create mr-x/bash-watcher-buffer)
                            '((display-buffer-in-side-window)
                              (side . bottom)
                              (window-height . 0.3)))))

        ;; ============================================
        ;; Custom Permission System (v0.42.1+ hook-based)
        ;; Uses agent-shell-permission-responder-function to stash
        ;; the respond callback, then SPC c 1/2/3 calls it directly.
        ;; Supports stacked permissions via a queue.
        ;; ============================================

        (defvar mr-x/pending-permissions-queue nil
          "Queue of pending permissions, most recent first.
    Each entry is a plist with :respond, :options, :tool-call, :buffer, :tool-call-id.")

        ;; Legacy aliases for backward compat with context-sensitive keys
        (defvar mr-x/pending-permission nil)
        (defvar mr-x/pending-permissions nil)

        (defun mr-x/pending-permissions-update-legacy ()
          "Sync legacy variables from queue head."
          (if mr-x/pending-permissions-queue
              (let ((head (car mr-x/pending-permissions-queue)))
                (setq mr-x/pending-permission head)
                (setq mr-x/pending-permissions
                      (list (cons (plist-get head :tool-call-id)
                                  (list :buffer (plist-get head :buffer)
                                        :state nil :request nil)))))
            (setq mr-x/pending-permission nil)
            (setq mr-x/pending-permissions nil)))

        (defun mr-x/pending-permissions-remove (tool-call-id)
          "Remove the permission with TOOL-CALL-ID from the queue."
          (setq mr-x/pending-permissions-queue
                (cl-remove-if (lambda (p) (equal (plist-get p :tool-call-id) tool-call-id))
                              mr-x/pending-permissions-queue))
          (mr-x/pending-permissions-update-legacy))

        (setq agent-shell-permission-responder-function
              (lambda (permission)
                ;; Stash the respond function and options for SPC c 1/2/3
                (let* ((tool-call (map-elt permission :tool-call))
                       (tool-call-id (map-elt tool-call :tool-call-id))
                       (has-diff (map-elt tool-call :diff))
                       (shell-buf (or (and (derived-mode-p 'agent-shell-mode) (current-buffer))
                                      (seq-first (agent-shell-project-buffers)))))
                  ;; Push onto queue (most recent first)
                  (push (list :respond (map-elt permission :respond)
                              :options (map-elt permission :options)
                              :tool-call tool-call
                              :tool-call-id tool-call-id
                              :buffer shell-buf)
                        mr-x/pending-permissions-queue)
                  (mr-x/pending-permissions-update-legacy)
                  (message "Permission: %s [1=allow 2=deny 3=always%s]%s"
                           (map-elt tool-call :title)
                           (if has-diff " 0=view" "")
                           (if (> (length mr-x/pending-permissions-queue) 1)
                               (format " (%d queued)" (length mr-x/pending-permissions-queue))
                             "")))
                ;; Return nil so the button UI still renders as fallback
                nil))

        ;; Auto-remove from queue when permission is resolved (by any mechanism)
        (advice-add 'agent-shell--send-permission-response :after
                    (lambda (&rest args)
                      (let ((tool-call-id (plist-get args :tool-call-id)))
                        (when tool-call-id
                          (mr-x/pending-permissions-remove tool-call-id)))))

        (defun mr-x/respond-to-permission (kind)
          "Respond to the most recent pending permission with KIND.
    KIND should be \"allow_once\", \"reject_once\", or \"allow_always\"."
          (unless mr-x/pending-permissions-queue
            (user-error "No pending permission request"))
          (let* ((pending (car mr-x/pending-permissions-queue))
                 (respond-fn (plist-get pending :respond))
                 (options (plist-get pending :options))
                 (option (seq-find (lambda (o) (equal (map-elt o :kind) kind))
                                   options))
                 (option-id (map-elt option :option-id)))
            (unless option
              (user-error "No '%s' option available" kind))
            (condition-case err
                (funcall respond-fn option-id)
              (error
               ;; Remove stale permission and report
               (mr-x/pending-permissions-remove (plist-get pending :tool-call-id))
               (user-error "Permission response failed (process may have exited): %s"
                           (error-message-string err))))
            ;; Queue cleanup happens via the advice on agent-shell--send-permission-response
            (let ((remaining (length mr-x/pending-permissions-queue)))
              (message "Permission %s%s"
                       (pcase kind
                         ("allow_once" "allowed")
                         ("reject_once" "denied")
                         ("allow_always" "always allowed"))
                       (if (> remaining 0)
                           (format " (%d remaining)" remaining)
                         "")))))

        (defun mr-x/agent-shell-allow ()
          "Allow the current permission request."
          (interactive)
          (mr-x/respond-to-permission "allow_once"))

        (defun mr-x/agent-shell-deny ()
          "Deny the current permission request."
          (interactive)
          (mr-x/respond-to-permission "reject_once"))

        (defun mr-x/agent-shell-allow-always ()
          "Allow always the current permission request."
          (interactive)
          (mr-x/respond-to-permission "allow_always"))

        (defun mr-x/fontify-diff-with-language (mode-fn)
          "Apply MODE-FN syntax highlighting to diff hunks in current buffer.
    Highlights the actual code content, not just +/- markers."
          (save-excursion
            (goto-char (point-min))
            (let ((inhibit-read-only t))
              (while (not (eobp))
                (let ((line-start (point))
                      (line-end (line-end-position)))
                  ;; Only process +/- lines (actual code changes)
                  (when (and (< line-start line-end)
                             (memq (char-after line-start) '(?+ ?-)))
                    (let* ((code-start (1+ line-start))  ; skip the +/- marker
                           (code-text (buffer-substring-no-properties code-start line-end))
                           (fontified-text (with-temp-buffer
                                             (insert code-text)
                                             (funcall mode-fn)
                                             (font-lock-ensure)
                                             (buffer-string))))
                      ;; Apply the fontified properties to the original
                      (when (> (length fontified-text) 0)
                        (let ((pos 0))
                          (while (< pos (length fontified-text))
                            (let ((face (get-text-property pos 'face fontified-text)))
                              (when face
                                (add-face-text-property 
                                 (+ code-start pos) 
                                 (+ code-start pos 1)
                                 face t)))
                            (setq pos (1+ pos))))))))
                (forward-line 1)))))

        (defun mr-x/agent-shell-view-diff ()
          "View the diff for the current pending permission with syntax highlighting."
          (interactive)
          (if-let* ((pending (car mr-x/pending-permissions-queue))
                    (tool-call (plist-get pending :tool-call))
                    (diff (map-elt tool-call :diff))
                    (shell-buf (plist-get pending :buffer)))
              (let* ((filename (map-elt diff :file))
                     (mode-fn (assoc-default filename auto-mode-alist 'string-match)))
                (agent-shell-diff
                 :old (map-elt diff :old)
                 :new (map-elt diff :new)
                 :file filename
                 :title (file-name-nondirectory filename))
                ;; Apply language-specific syntax highlighting to diff content
                (with-current-buffer "*agent-shell-diff*"
                  (when (and mode-fn (fboundp mode-fn))
                    (mr-x/fontify-diff-with-language mode-fn)))
                ;; Re-add our keybindings since we called agent-shell-diff without them
                (with-current-buffer "*agent-shell-diff*"
                  (let ((map (make-sparse-keymap)))
                    (set-keymap-parent map (current-local-map))
                    (define-key map (kbd "n") 'diff-hunk-next)
                    (define-key map (kbd "p") 'diff-hunk-prev)
                    (define-key map (kbd "y") (lambda ()
                                                (interactive)
                                                (kill-current-buffer)
                                                (mr-x/agent-shell-allow)
                                                (when (buffer-live-p shell-buf)
                                                  (pop-to-buffer shell-buf))))
                    (define-key map (kbd "!") (lambda ()
                                                (interactive)
                                                (kill-current-buffer)
                                                (mr-x/agent-shell-allow-always)
                                                (when (buffer-live-p shell-buf)
                                                  (pop-to-buffer shell-buf))))
                    (define-key map (kbd "r") (lambda ()
                                                (interactive)
                                                (kill-current-buffer)
                                                (mr-x/agent-shell-deny)
                                                (when (buffer-live-p shell-buf)
                                                  (pop-to-buffer shell-buf))))
                    (define-key map (kbd "q") (lambda ()
                                                (interactive)
                                                ;; Disable on-exit to prevent "Accept changes?" prompt
                                                (setq agent-shell-on-exit nil)
                                                (kill-current-buffer)
                                                (when (buffer-live-p shell-buf)
                                                  (pop-to-buffer shell-buf))))
                    (use-local-map map))
                  (setq header-line-format
                        (concat "  "
                                (propertize (file-name-nondirectory filename) 'face 'mode-line-emphasis)
                                " "
                                (propertize "n" 'face 'help-key-binding) " next "
                                (propertize "p" 'face 'help-key-binding) " prev "
                                (propertize "y" 'face 'help-key-binding) " accept "
                                (propertize "!" 'face 'help-key-binding) " always "
                                (propertize "r" 'face 'help-key-binding) " reject "
                                (propertize "q" 'face 'help-key-binding) " exit"))))
            (message "No diff available for current permission")))


        ;; Auto-close diff buffer when permission is accepted/rejected
        (advice-add 'agent-shell--send-permission-response :after
                    (lambda (&rest _)
                      (dolist (buf (buffer-list))
                        (when (string-match-p "\\*agent-shell.*diff\\*" (buffer-name buf))
                          ;; Disable on-exit before killing to prevent prompt
                          (with-current-buffer buf
                            (setq agent-shell-on-exit nil))
                          (kill-buffer buf)))))
        
        ;; Fix: Override keys in agent-shell diff buffers to exit cleanly and return to shell
        (defun mr-x/agent-shell-diff-clean-exit ()
          "Exit diff buffer cleanly and return to agent-shell."
          (interactive)
          (let ((shell-buf (when (car mr-x/pending-permissions-queue)
                             (plist-get (car mr-x/pending-permissions-queue) :buffer))))
            (setq agent-shell-on-exit nil)
            (kill-current-buffer)
            (when (and shell-buf (buffer-live-p shell-buf))
              (pop-to-buffer shell-buf))))
        
        ;; Apply clean exit and action keys to all agent-shell diff buffers
        (add-hook 'diff-mode-hook
                  (lambda ()
                    (when (string-match-p "\\*agent-shell.*diff\\*" (buffer-name))
                      (local-set-key (kbd "q") #'mr-x/agent-shell-diff-clean-exit)
                      (local-set-key (kbd "y") (lambda () (interactive)
                                                 (let ((shell-buf (when (car mr-x/pending-permissions-queue)
                                                                    (plist-get (car mr-x/pending-permissions-queue) :buffer))))
                                                   (setq agent-shell-on-exit nil)
                                                   (kill-current-buffer)
                                                   (mr-x/agent-shell-allow)
                                                   (when (and shell-buf (buffer-live-p shell-buf))
                                                     (pop-to-buffer shell-buf)))))
                      (local-set-key (kbd "!") (lambda () (interactive)
                                                 (let ((shell-buf (when (car mr-x/pending-permissions-queue)
                                                                    (plist-get (car mr-x/pending-permissions-queue) :buffer))))
                                                   (setq agent-shell-on-exit nil)
                                                   (kill-current-buffer)
                                                   (mr-x/agent-shell-allow-always)
                                                   (when (and shell-buf (buffer-live-p shell-buf))
                                                     (pop-to-buffer shell-buf)))))
                      (local-set-key (kbd "r") (lambda () (interactive)
                                                 (let ((shell-buf (when (car mr-x/pending-permissions-queue)
                                                                    (plist-get (car mr-x/pending-permissions-queue) :buffer))))
                                                   (setq agent-shell-on-exit nil)
                                                   (kill-current-buffer)
                                                   (mr-x/agent-shell-deny)
                                                   (when (and shell-buf (buffer-live-p shell-buf))
                                                     (pop-to-buffer shell-buf))))))))
        ;; Use existing Claude CLI login
        ;; Value must be the config-option *id* the agent advertises under
        ;; "Available models", NOT the underlying model string. Valid ids:
        ;;   default      -> Opus 4.6 (1M context) · most capable  <-- this one
        ;;   sonnet       -> Sonnet 4.6
        ;;   sonnet[1m]   -> Sonnet 4.6 (1M context)
        ;;   haiku        -> Haiku 4.5
        ;; (nil also works: the agent falls back to "default" = Opus 4.6 1M.)
        (setq agent-shell-anthropic-default-model-id "default")
        (setq agent-shell-anthropic-authentication
              (agent-shell-anthropic-make-authentication :login t))
        ;; Inherit environment (gets PATH, ANTHROPIC_API_KEY, etc.)
        (setq agent-shell-anthropic-claude-environment
              (agent-shell-make-environment-variables :inherit-env t))
        ;; Launch the agent through acp-multiplex so this agent-shell session
        ;; becomes the multiplex PRIMARY: the proxy exposes a Unix socket that
        ;; acp-mobile discovers, letting the phone/Air attach to the same live
        ;; session over Tailscale (see ~/.dotfiles/docs/prd-remote-agent-access.md).
        ;; NOTE: use @agentclientprotocol/claude-agent-acp (0.54.x) — the official
        ;; ACP package (continuation of the ACP spin-out from Zed).
        ;; Do NOT use @zed-industries/claude-agent-acp (0.23.x): it streams
        ;; agent_message_chunk out-of-turn after a cancel, desyncing C-c C-c
        ;; interrupts (empty prompt, then the PRIOR turn's reply lands next).
        ;; And NOT the ancient claude-code-acp (0.12.x) — it lacks session/list,
        ;; which agent-shell calls after every turn, spamming "Notices" errors.
        ;; See ~/shared/agent-shell-interrupt-bug.md for the full diagnosis.
        ;; Guarded so machines without the multiplex built (e.g. the Air)
        ;; fall back to agent-shell's default direct claude-agent-acp.
        (when (executable-find "acp-multiplex")
          (setq agent-shell-anthropic-claude-acp-command
                '("acp-multiplex" "claude-agent-acp")))

        ;; ── Goose (local Ollama agent) ──────────────────────────
        ;; Goose talks to a local model (qwen3.5:9b) on the M2 Air
        ;; (mrx2:11434) over Ollama — a fully private, no-cloud agent.
        ;; Full write-up: ~/.dotfiles/docs/goose-ollama-setup.md
        ;; Launch with  M-x mr-x/goose-local-start
        (require 'agent-shell-goose)
        ;; Provider is Ollama (set in ~/.config/goose/config.yaml), so disable
        ;; Goose's default xAI/OpenAI auth entirely — no API key needed.
        (setq agent-shell-goose-authentication
              (agent-shell-make-goose-authentication :none t))
        ;; `goose acp' (unlike `goose run') does NOT auto-load the extensions
        ;; enabled in config.yaml, so pass the developer builtin explicitly —
        ;; otherwise the session has zero file/shell tools and the model just
        ;; hallucinates ones that aren't there.
        (setq agent-shell-goose-acp-command
              '("goose" "acp" "--with-builtin" "developer"))
        ;; qwen3.5 is a reasoning model; Ollama's thinking+tools path returns
        ;; empty responses (ollama#10976). GOOSE_TOOLSHIM makes the model emit
        ;; tool calls as TEXT, then a small parser model reformats them to JSON
        ;; via constrained decoding. The parser MUST be tiny: llama3.1:8b
        ;; (4.9GB) can't coexist with qwen (5.6GB) on the 16GB Air and hangs
        ;; forever waiting to load; llama3.2:3b (2GB) fits alongside and is far
        ;; faster. NOTE: GOOSE_TOOLSHIM_OLLAMA_MODEL is IGNORED in config.yaml —
        ;; it only takes effect as an env var, here.
        ;; OLLAMA_HOST points at the local goose-scope proxy (see goose-scope.el
        ;; below), which forwards to Ollama on the Air and logs every call for
        ;; the *goose-scope* observability panel. Proxy auto-starts with the panel.
        (setq agent-shell-goose-environment
              (agent-shell-make-environment-variables
               "OLLAMA_HOST" "http://127.0.0.1:11435"
               "GOOSE_TOOLSHIM" "1"
               "GOOSE_TOOLSHIM_OLLAMA_MODEL" "llama3.2:3b"))

        ;; Start Goose with a CLEAN, minimal toolset. agent-shell injects the
        ;; global `agent-shell-mcp-servers' (task-master-ai & friends = 30+
        ;; tools) into every session; small models drown in a big tool list and
        ;; pick the wrong tool. Suppress it so qwen sees only the ~5 developer
        ;; tools (shell/read/write/edit/tree).
        (defun mr-x/goose-local-start ()
          "Start a local Goose session (Ollama) with MCP servers suppressed."
          (interactive)
          (let ((agent-shell-mcp-servers nil))
            (agent-shell-goose-start-agent)))

        ;; goose-scope: live observability panel for the local agent stack.
        ;; M-x goose-scope (or SPC c g) opens a *goose-scope* buffer that tails
        ;; the proxy's NDJSON log and renders each turn as a timeline. Opening it
        ;; auto-starts the proxy. See macos/scripts/goose-scope-proxy.py.
        (load (expand-file-name "goose-scope" user-emacs-directory) t)





        ;; MCP Servers - taskmaster for task management
        ;; Stdio transport requires: name, command, args, env
        ;; env must be a vector [] for proper JSON array serialization
        (setq agent-shell-mcp-servers
              `(((name . "task-master-ai")
                 (command . "npx")
                 (args . ["-y" "--package=task-master-ai" "task-master-ai"])
                 (env . [((name . "TASK_MASTER_TOOLS") (value . "all"))]))


    	    ((name . "ask-user")
    	     (command . "node")
    	     (args . ["/Users/marcosandrade/roaming/projects/MCP servers/ask-user-mcp/build/index.js"])
    	     (env . []))

                ((name . "chrome-devtools")
                 (command . "npx")
                 (args . ["-y" "chrome-devtools-mcp@latest"])
                 (env . []))

                ;; axiom disabled: mcp-remote triggers an OAuth browser
                ;; pop-up on every new agent-shell session. Re-enable by
                ;; uncommenting this block.
                ;; ((name . "axiom")
                ;;  (command . "npx")
                ;;  (args . ["-y" "mcp-remote" "https://mcp.axiom.co/mcp"])
                ;;  (env . []))
                ))



        ;; Custom prompt config
        (setq agent-shell-preferred-agent-config
              (agent-shell-make-agent-config
               :identifier 'claude-code
               :mode-line-name "Claude"
               :buffer-name "Claude"
               :shell-prompt "𐆖 "
               :shell-prompt-regexp "𐆖 "
               :icon-name "anthropic.png"
               :welcome-function #'agent-shell-anthropic--claude-code-welcome-message
               :client-maker (lambda (buffer)
                               (agent-shell-anthropic-make-claude-client :buffer buffer))
               :default-model-id (lambda () agent-shell-anthropic-default-model-id)))


      ;; Local slash commands for agent-shell
      (defun mr-x/agent-shell-clear-context ()
        "Start a fresh agent-shell session reusing the current config, no picker."
        (interactive)
        (let* ((config (map-elt agent-shell--state :agent-config))
               (shell-buffer (agent-shell--start :config config
                                                 :no-focus t
                                                 :new-session t)))
          (if (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                              'agent-shell-viewport-edit-mode)
              (if agent-shell-prefer-viewport-interaction
                  (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
                (switch-to-buffer shell-buffer))
            (if agent-shell-prefer-viewport-interaction
                (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
              (pop-to-buffer shell-buffer)))))

      (defvar mr-x/agent-shell-local-commands
        '(("new" . mr-x/agent-shell-new-smart)
          ("clear" . mr-x/agent-shell-clear-context))
        "Local slash commands. Keys are names (without /), values are functions.")

      ;; Inject local commands into / completion
      (defun mr-x/agent-shell-inject-local-commands (orig-fun)
        "Add local commands to / completion."
        (when-let ((result (funcall orig-fun)))
          (let* ((start (nth 0 result))
                 (end (nth 1 result))
                 (candidates (nth 2 result))
                 (local-names (mapcar #'car mr-x/agent-shell-local-commands))
                 (all-candidates (append local-names candidates)))
            (list start end all-candidates
                  :exclusive t
                  :exit-function (lambda (_s _status) (insert " "))))))

      (advice-add 'agent-shell--command-completion-at-point
                  :around #'mr-x/agent-shell-inject-local-commands)

      ;; Intercept local commands on submit
      (defun mr-x/agent-shell-intercept-local-commands (orig-fun &rest args)
        "Run local command instead of sending to Claude."
        (let* ((prompt-start (save-excursion
                               (goto-char (point-max))
                               (re-search-backward comint-prompt-regexp nil t)
                               (match-end 0)))
               (input (buffer-substring-no-properties prompt-start (point-max))))
          (if (and (string-prefix-p "/" input)
                   (let* ((cmd (cadr (split-string input "/")))
                          (cmd-name (car (split-string cmd " ")))
                          (handler (cdr (assoc cmd-name mr-x/agent-shell-local-commands))))
                     (when handler
                       (delete-region prompt-start (point-max))
                       (funcall handler)
                       t)))
              nil
            (apply orig-fun args))))

      (advice-add 'shell-maker-submit :around #'mr-x/agent-shell-intercept-local-commands))

      ;; Delta-powered syntax highlighting for agent-shell diffs
      (with-eval-after-load 'agent-shell-diff
        (require 'ansi-color)

        ;; Dynamic var to pass filename for delta syntax detection
        (defvar my/agent-shell-diff-filename nil
          "Current filename being diffed, for delta syntax detection.")

        ;; Use delta instead of plain diff, with proper file extension for syntax
        (defun my/agent-shell-diff-with-delta-insert (old new file _buf)
          "Insert delta-formatted diff of OLD and NEW into current buffer.
    FILE is used for syntax detection. _BUF is ignored (we insert at point)."
          (let* ((ext (or (and file (file-name-extension file))
                          (and my/agent-shell-diff-filename
                               (file-name-extension my/agent-shell-diff-filename))))
                 (suffix (if ext (concat "." ext) ""))
                 (old-file (make-temp-file "old" nil suffix))
                 (new-file (make-temp-file "new" nil suffix)))
            (unwind-protect
                (progn
                  (with-temp-file old-file (insert old))
                  (with-temp-file new-file (insert new))
                  (let ((process-environment (cons "FORCE_COLOR=1" process-environment)))
                    (call-process "delta" nil t nil
                                  "--syntax-theme" "gruvbox-dark"
                                  "--paging" "never"
                                  "--color-only"
                                  old-file new-file)))
              (delete-file old-file)
              (delete-file new-file))))

        ;; Capture filename from :title and apply ANSI colors after
        (defun my/agent-shell-diff-apply-ansi (orig-fun &rest args)
          "Run agent-shell-diff then apply ANSI colors to the result buffer."
          ;; Extract filename from :title arg
          (let ((my/agent-shell-diff-filename (plist-get args :title)))
            ;; Replace agent-shell-diff-mode with a minimal version that doesn't
            ;; clobber delta colors but runs the hook for evil setup
            (cl-letf (((symbol-function 'agent-shell-diff-mode)
                       (lambda ()
                         (kill-all-local-variables)
                         (setq major-mode 'agent-shell-diff-mode)
                         (setq mode-name "Agent-Diff")
                         ;; Don't run font-lock (preserves delta colors)
                         (setq font-lock-defaults nil)
                         (setq buffer-read-only t)
                         ;; Run diff-mode-hook so mr-x/agent-shell-diff-mode-setup fires
                         (run-mode-hooks 'diff-mode-hook))))
              (apply orig-fun args)))
          ;; Now find the diff buffer and apply colors
          (when-let ((buf (get-buffer "*agent-shell-diff*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (ansi-color-apply-on-region (point-min) (point-max))))))

        (advice-add 'agent-shell-diff--insert-diff :override #'my/agent-shell-diff-with-delta-insert)
        (advice-add 'agent-shell-diff :around #'my/agent-shell-diff-apply-ansi))


      ;; Agent Shell Sidebar - Project-isolated sidebar for agent-shell
      (use-package agent-shell-sidebar
        :ensure (:host github :repo "cmacrae/agent-shell-sidebar")
        :after agent-shell
        :config
        ;; Use the same config as agent-shell-preferred-agent-config
        (setq agent-shell-sidebar-default-config agent-shell-preferred-agent-config)
        ;; Position sidebar on the left (options: left, right)
        (setq agent-shell-sidebar-side 'left)
        (setq agent-shell-sidebar-locked nil)
        ;; Width as percentage of frame
        (setq agent-shell-sidebar-width "5%"))


      ;; Agent Shell Attention - Mode-line indicator for pending agent buffers
      (use-package agent-shell-attention
        :ensure (:host github :repo "ultronozm/agent-shell-attention.el")
        :after agent-shell
        :config
        ;; Define a custom face for the indicator
        (defface agent-shell-attention-face
          '((t :foreground "#fb4934" :weight bold))  ;; gruvbox red
          "Face for agent-shell-attention mode-line indicator.")

        ;; Override the render function to use our face
        (defun mr-x/agent-shell-attention-render (pending _active)
          "Render with custom face. PENDING is count, _ACTIVE ignored."
          (when (or agent-shell-attention-show-zeros (not (zerop pending)))
            (propertize (format agent-shell-attention-lighter pending)
                        'face 'agent-shell-attention-face
                        'mouse-face 'mode-line-highlight
                        'local-map agent-shell-attention--mode-line-map)))

        (setq agent-shell-attention-render-function #'mr-x/agent-shell-attention-render)

        ;; macOS notifications via AppleScript
        (defun mr-x/agent-shell-notify (_buffer title body)
          "Send macOS notification via AppleScript."
          (start-process "notify" nil "osascript"
                         "-e" (format "display notification %S with title %S"
                                      body title)))

        (setq agent-shell-attention-notify-function #'mr-x/agent-shell-notify)
        (agent-shell-attention-mode 1))


      ;; Agent Shell Inbox - phone screenshots land in an armed buffer's prompt
      ;; (daemon: macos/scripts/agent-inbox-daemon.py; design doc:
      ;;  docs/phone-screenshot-ez-send.md)
      (require 'agent-shell-inbox)

      ;; Agent Shell Refs - Select text from responses to attach as context
      (require 'agent-shell-refs)
      (with-eval-after-load 'agent-shell
        (agent-shell-refs-setup)
        ;; Visual mode: capture selection as a ref
        (evil-define-key 'visual agent-shell-mode-map
          (kbd "C-c r") #'agent-shell-refs-capture)
        ;; Normal mode: manage refs
        (evil-define-key 'normal agent-shell-mode-map
          (kbd "C-c r") #'agent-shell-refs-preview
          (kbd "C-c R") #'agent-shell-refs-clear))

      ;; Leader key refs bindings — defer until general is loaded so init.el
      ;; doesn't error out on top-level general-define-key calls.
      (with-eval-after-load 'general
        (general-define-key
         :states '(normal visual)
         :prefix "SPC"
         "c x r" '(agent-shell-refs-capture :wk "Capture ref")
         "c x c" '(agent-shell-refs-clear :wk "Clear refs")
         "c x p" '(agent-shell-refs-preview :wk "Preview refs")
         "c x d" '(agent-shell-refs-remove :wk "Remove ref")
         "c g" '(goose-scope :wk "Goose scope panel")))


      ;; Agent Shell Tool Group - Collapse consecutive tool calls under foldable headers
      (use-package agent-shell-tool-group
        :ensure (:host github :repo "Gleek/agent-shell-tool-group")
        :after agent-shell
        :config
        (agent-shell-tool-group-mode 1))


      ;; Agent Shell Manager - Dashboard for managing multiple agent sessions
      (use-package agent-shell-manager
        :ensure (:host github :repo "Marx-A00/agent-shell-manager")
        :after agent-shell
        :config
        ;; Position manager window (options: left, right, top, bottom, nil for no auto-display)
        (setq agent-shell-manager-side nil)
        ;; Evil keybindings — preview, filter, and navigation all built-in now
        (evil-define-key 'normal agent-shell-manager-mode-map
          (kbd "p") #'agent-shell-manager-enter-preview
          (kbd "o") #'agent-shell-manager-peek
          (kbd "RET") #'agent-shell-manager-select
          (kbd "q") #'agent-shell-manager-quit
          (kbd "f") #'agent-shell-manager-cycle-filter
          (kbd "C-n") #'next-line
          (kbd "C-p") #'previous-line
          (kbd "gr") #'agent-shell-manager-refresh
          (kbd "K") #'agent-shell-manager-kill
          (kbd "c") #'agent-shell-manager-new
          (kbd "r") #'agent-shell-manager-restart
          (kbd "D") #'agent-shell-manager-delete-killed
          (kbd "m") #'agent-shell-manager-set-mode
          (kbd "M") #'agent-shell-manager-set-model
          (kbd "C-c C-c") #'agent-shell-manager-interrupt
          (kbd "t") #'agent-shell-manager-view-traffic
          (kbd "l") #'agent-shell-manager-toggle-logging))

      (use-package deadgrep
        :ensure t
        :commands (deadgrep)
        :custom
        (deadgrep-display-buffer-function
         (lambda (buf)
           (select-window
            (display-buffer buf '(display-buffer-at-bottom (window-height . 0.35))))))
        :config
        (set-face-attribute 'deadgrep-filename-face nil
                            :foreground "#fabd2f" :inherit 'bold)

        (defvar mr-x/deadgrep--hl-overlay nil
          "Overlay for highlighting the current deadgrep result.")

        (defun mr-x/deadgrep--highlight-current ()
          "Highlight the current result line in deadgrep."
          (when (eq major-mode 'deadgrep-mode)
            (when mr-x/deadgrep--hl-overlay
              (delete-overlay mr-x/deadgrep--hl-overlay))
            (setq mr-x/deadgrep--hl-overlay
                  (make-overlay (line-beginning-position) (1+ (line-end-position))))
            (overlay-put mr-x/deadgrep--hl-overlay 'face 'hl-line)))

        (defun mr-x/deadgrep-forward-and-highlight ()
          "Move to next match and highlight."
          (interactive)
          (deadgrep-forward-match)
          (mr-x/deadgrep--highlight-current))

        (defun mr-x/deadgrep-backward-and-highlight ()
          "Move to previous match and highlight."
          (interactive)
          (deadgrep-backward-match)
          (mr-x/deadgrep--highlight-current))

        (defun mr-x/deadgrep-forward-file-and-highlight ()
          "Move to next file header and highlight."
          (interactive)
          (deadgrep-forward-filename)
          (mr-x/deadgrep--highlight-current))

        (defun mr-x/deadgrep-backward-file-and-highlight ()
          "Move to previous file header and highlight."
          (interactive)
          (deadgrep-backward-filename)
          (mr-x/deadgrep--highlight-current))

        (evil-define-key '(normal motion) deadgrep-mode-map
          (kbd "C-n") #'mr-x/deadgrep-forward-and-highlight
          (kbd "C-p") #'mr-x/deadgrep-backward-and-highlight
          (kbd "j") #'mr-x/deadgrep-forward-and-highlight
          (kbd "k") #'mr-x/deadgrep-backward-and-highlight
          (kbd "J") #'mr-x/deadgrep-forward-file-and-highlight
          (kbd "K") #'mr-x/deadgrep-backward-file-and-highlight
          (kbd "RET") #'deadgrep-visit-result-other-window))


      (use-package agent-recall
        :ensure nil
        ;; local project under ~/roaming (Syncthing) — skip entirely when absent
        :if (file-directory-p "~/roaming/projects/agent-recall")
        :load-path "~/roaming/projects/agent-recall"
        :after agent-shell
        :init
        ;; Ensure load-path is set up early so :commands autoloads can
        ;; find the file even before agent-shell triggers :after.
        (add-to-list 'load-path (expand-file-name "~/roaming/projects/agent-recall"))
        ;; consult-search lives in agent-recall-consult.el, not the main file,
        ;; so it needs its own autoload rather than going through :commands.
        (autoload 'agent-recall-consult-search "agent-recall-consult" nil t)
        :commands (agent-recall-search
                   agent-recall-browse agent-recall-browse-project
                   agent-recall-resume
                   agent-recall-backfill agent-recall-stats)
        :custom
        (agent-recall-search-paths '("~"))
        (agent-recall-search-function 'deadgrep)
        (agent-recall-browse-sort 'modified-desc)
        (agent-recall-browse-preview t)
        :hook (agent-shell-mode . agent-recall-track-sessions))
        ;; Resume/browse placement needs no advice: agent-recall funnels
        ;; display through `agent-recall--display-buffer' (a plain
        ;; pop-to-buffer), which the "Claude Agent @" display-buffer-alist
        ;; entry routes into the major-pane.

      (use-package major-pane
        :ensure nil
        ;; No :after — that would defer :init (the global-set-key) behind
        ;; (eval-after-load 'agent-shell), leaving s-i unbound until agent-shell
        ;; loads. :commands autoloads the command, which pulls in agent-shell on
        ;; first use, so s-i can bind unconditionally at startup.
        :init
        (global-set-key (kbd "s-i") #'major-pane-toggle)
        (global-set-key (kbd "s-M-<right>") #'major-pane-next-tab)
        (global-set-key (kbd "s-M-<left>") #'major-pane-prev-tab)
        ;; Not a command, so it can't go in :commands — autoloaded by hand
        ;; so the display-buffer-alist entry (set early in init) can route
        ;; agent buffers into the pane before major-pane loads.
        (autoload 'major-pane-display-buffer-action "major-pane")
        :commands (major-pane-toggle
                   major-pane-next-tab
                   major-pane-prev-tab
                   major-pane-new-chat
                   major-pane-close-conversation
                   major-pane-close-all-conversations
                   major-pane-exclude-buffer
                   major-pane-swap-buffer
                   major-pane-set-label
                   major-pane-pick-buffer
                   major-pane-send-region
                   major-pane-send-region-no-switch
                   major-pane-send-file
                   major-pane-send-other-file
                   major-pane-send-screenshot))

      (use-package agent-shell-macext
        :ensure (:host github :repo "cxa/agent-shell-macext")
        :hook (agent-shell-mode . agent-shell-macext-setup)
        :custom
        (agent-shell-macext-file-copy-policy 'auto)
        (agent-shell-macext-notifications t)
        (agent-shell-macext-notify-current-buffer nil))

      ;; Permission UI Override - Hybrid Style (cleaner vertical layout)
      (defvar mr-x/permission-ui-style 'hybrid
        "Style for permission UI. Options:
    - 'minimal    - Basic vertical layout
    - 'spaced     - More padding/alignment  
    - 'separator  - Line between diff and actions
    - 'highlighted - Colored keybindings
    - 'icons      - Icons for each action
    - 'hybrid     - Highlighted keys + separator (recommended)")

      (with-eval-after-load 'agent-shell
        (defun mr-x/permission-format-line (char label keymap &optional is-diff)
          "Format a single permission line based on current style."
          (let* ((style mr-x/permission-ui-style)
                 (icon (when (eq style 'icons)
                         (cond (is-diff "👁 ")
                               ((string= char "y") "✓ ")
                               ((string= char "n") "✗ ")
                               ((string= char "!") "⚡ ")
                               (t ""))))
                 (key-face (if (memq style '(highlighted hybrid))
                               '(:foreground "#fabd2f" :weight bold)  ; gruvbox yellow
                             'link))
                 (padding (if (memq style '(spaced separator icons hybrid)) "   " "  "))
                 (formatted-char (propertize char 'font-lock-face key-face))
                 (formatted-label (propertize (concat (or icon "") label) 'font-lock-face 'default)))
            (propertize
             (concat padding formatted-char "   " formatted-label)
             'keymap keymap
             'mouse-face 'highlight
             'help-echo (format "Press %s to %s" char label)
             'agent-shell-permission-button t
             'cursor-sensor-functions
             (list (lambda (_window _old-pos sensor-action)
                     (when (eq sensor-action 'entered)
                       (message "Press RET or %s to %s" char label)))))))

        (defun mr-x/agent-shell--make-tool-call-permission-text (&rest args)
          "Minimal vertical permission UI override with multiple styles."
          (let* ((request (plist-get args :acp-request))
                 (client (plist-get args :client))
                 (state (plist-get args :state))
                 (tool-call-id (map-nested-elt request '(params toolCall toolCallId)))
                 (tool-title (map-nested-elt request '(params toolCall title)))
                 (tool-kind (map-nested-elt request '(params toolCall kind)))
                 (tool-name (or tool-title tool-kind "tool"))
                 (diff (map-nested-elt state `(:tool-calls ,tool-call-id :diff)))
                 (diff-available diff)
                 (style mr-x/permission-ui-style)
                 (request-id (map-elt request 'id))
                 (shell-buffer (map-elt state :buffer))
                 (actions (agent-shell--make-permission-actions
                           (map-nested-elt request '(params options))))
                 ;; Helper to make a respond function for a given action kind
                 (make-respond
                  (lambda (kind)
                    (when-let ((action (seq-find (lambda (a) (equal (map-elt a :kind) kind)) actions)))
                      (lambda ()
                        (interactive)
                        (agent-shell--send-permission-response
                         :client client
                         :request-id request-id
                         :option-id (map-elt action :option-id)
                         :state state
                         :tool-call-id tool-call-id
                         :message-text (map-elt action :option))
                        (when (equal kind "reject_once")
                          (with-current-buffer shell-buffer
                            (agent-shell-interrupt t)))))))
                 (allow-fn (funcall make-respond "allow_once"))
                 (deny-fn (funcall make-respond "reject_once"))
                 (always-fn (funcall make-respond "allow_always"))
                 ;; Build keymaps using closures
                 (yes-map (let ((map (make-sparse-keymap)))
                            (when allow-fn
                              (define-key map [mouse-1] allow-fn)
                              (define-key map (kbd "RET") allow-fn))
                            map))
                 (no-map (let ((map (make-sparse-keymap)))
                           (when deny-fn
                             (define-key map [mouse-1] deny-fn)
                             (define-key map (kbd "RET") deny-fn))
                           map))
                 (always-map (let ((map (make-sparse-keymap)))
                               (when always-fn
                                 (define-key map [mouse-1] always-fn)
                                 (define-key map (kbd "RET") always-fn))
                               map))
                 (diff-map (when diff-available
                             (let ((map (make-sparse-keymap))
                                   (view-fn (agent-shell--make-diff-viewing-function
                                             :diff diff :actions actions
                                             :client client :request-id request-id
                                             :state state :tool-call-id tool-call-id)))
                               (define-key map [mouse-1] view-fn)
                               (define-key map (kbd "RET") view-fn)
                               map)))
                 ;; Separator line for hybrid/separator styles
                 (separator (when (memq style '(separator hybrid))
                              (propertize "\n   ─────────────────────────────\n"
                                          'font-lock-face '(:foreground "#fe8019")))))
            ;; Build the permission text
            (concat
             ;; Header
             (propertize (format "\n   Allow %s?" tool-name) 'font-lock-face 'bold)
             "\n"
             ;; Diff option (if available)
             (when diff-available
               (concat
                (mr-x/permission-format-line "0" "View diff" diff-map t)
                (or separator "\n")))
             ;; When no diff, still add separator if style calls for it
             (when (and (not diff-available) separator)
               separator)
             ;; Action buttons (keys match SPC c bindings)
             (mr-x/permission-format-line "1" "Allow once" yes-map)
             "\n"
             (mr-x/permission-format-line "2" "Deny" no-map)
             "\n"
             (mr-x/permission-format-line "3" "Always allow" always-map)
             "\n")))

        ;; Apply the override
        (advice-add 'agent-shell--make-tool-call-permission-text
                    :override #'mr-x/agent-shell--make-tool-call-permission-text))


      ;; (use-package claude-code
      ;;   :ensure (:host github :repo "stevemolitor/claude-code.el")
      ;;   :after general
      ;;   :config
      ;;   ;; Use vterm as the terminal backend (since you already have it)
      ;;   (setq claude-code-terminal-backend 'vterm)
        
      ;;   ;; Enable claude-code-mode
      ;;   (claude-code-mode 1)
        
      ;;   ;; Key binding for the command map - using a different prefix since you use C-c c for org-capture
      ;;   :bind-keymap
      ;;   ("C-c C-l" . claude-code-command-map)  ; or choose your preferred prefix
        
      ;;   ;; Optional: Set up repeat map for mode cycling
      ;;   :bind
      ;;   (:repeat-map my-claude-code-repeat-map 
      ;;                ("M" . claude-code-cycle-mode)))

      ;; (add-hook 'claude-code-process-environment-functions #'monet-start-server-function)





      ;; Adjust frame transparency for focused reading/viewing
      ;; DISABLED - using consistent transparency (80 80) instead
      ;; (defun mr-x/adjust-frame-alpha-for-focus ()
      ;;   "Make frame opaque when viewing focused content (Claude, PDF, markdown preview), transparent otherwise."
      ;;   (let ((should-be-opaque nil))
      ;;     ;; Check all windows in the current frame
      ;;     (walk-windows
      ;;      (lambda (win)
      ;;        (let ((buf (window-buffer win)))
      ;;          (when (or (string-match-p "\\*claude" (buffer-name buf))
      ;;                    (with-current-buffer buf (eq major-mode 'pdf-view-mode))
      ;;                    (with-current-buffer buf (eq major-mode 'xwidget-webkit-mode)))
      ;;            (setq should-be-opaque t))))
      ;;      nil 'visible)
      ;;     ;; Set alpha based on whether Claude or book is showing
      ;;     (if should-be-opaque
      ;;         (set-frame-parameter nil 'alpha '(100 100))   ;; opaque when reading
      ;;       (set-frame-parameter nil 'alpha '(80 50)))))    ;; transparent otherwise
      ;;
      ;; (add-hook 'window-configuration-change-hook #'mr-x/adjust-frame-alpha-for-focus)


      ;;; GPTel - Quick AI queries without launching a full agent

      (use-package gptel
        :ensure t
        :config
        ;; Use Ollama (local, free)
        (setq gptel-backend (gptel-make-ollama "Ollama"
                              :host "localhost:11434"
                              :stream t
                              :models '(llama3.2)))
        (setq gptel-model 'llama3.2))

      ;; GPTel-Quick - Instant word/region lookup in popup or echo area
      (use-package gptel-quick
        :ensure (:host github :repo "karthink/gptel-quick")
        :after gptel
        :config
        (setq gptel-quick-timeout 15)
        (setq gptel-quick-word-count 50))

      ;; Ensure Ollama is running before making requests
      (defun mr-x/ensure-ollama ()
        "Start Ollama if it's not already running. Returns t when ready."
        (unless (ignore-errors
                  (let ((proc (open-network-stream "ollama-check" nil "localhost" 11434)))
                    (delete-process proc)
                    t))
          (message "Starting Ollama...")
          (start-process "ollama" nil "ollama" "serve")
          (sleep-for 2)
          (unless (ignore-errors
                    (let ((proc (open-network-stream "ollama-check" nil "localhost" 11434)))
                      (delete-process proc)
                      t))
            (user-error "Ollama failed to start")))
        t)

      ;;; Quick Ask - context-aware AI popup powered by agent-shell

      ;; Session manager — hidden persistent agent-shell buffer
      (defvar mr-x/quick-ask--shell-buffer nil
        "The hidden agent-shell buffer used by Quick Ask.")

      (defun mr-x/quick-ask--session-healthy-p (buf)
        "Return non-nil if BUF is a healthy agent-shell session."
        (and buf
             (buffer-live-p buf)
             (with-current-buffer buf
               (and (boundp 'shell-maker--config)
                    shell-maker--config
                    (let ((proc (get-buffer-process (current-buffer))))
                      (and proc (process-live-p proc)))))))

      (defun mr-x/quick-ask--kill-zombie (buf)
        "Kill zombie agent-shell buffer BUF and reset state."
        (when (and buf (buffer-live-p buf))
          (message "Quick Ask: killing zombie session %s" buf)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf)))
        (setq mr-x/quick-ask--shell-buffer nil))

      (defun mr-x/quick-ask--ensure-session ()
        "Return a healthy agent-shell buffer, creating one if needed."
        (let ((buf mr-x/quick-ask--shell-buffer))
          (if (mr-x/quick-ask--session-healthy-p buf)
              buf
            (mr-x/quick-ask--kill-zombie buf)
            (mr-x/quick-ask--start-session))))

      (defun mr-x/quick-ask--start-session ()
        "Create the hidden agent-shell session. Returns the buffer."
        (let ((default-directory (expand-file-name "~")))
          (condition-case err
              (setq mr-x/quick-ask--shell-buffer
                    (agent-shell--start
                     :config agent-shell-preferred-agent-config
                     :no-focus t
                     :new-session t
                     :session-strategy 'new))
            (error
             (message "Quick Ask: agent-shell--start failed: %s" (error-message-string err))
             (setq mr-x/quick-ask--shell-buffer nil)
             nil))
          (when mr-x/quick-ask--shell-buffer
            (with-current-buffer mr-x/quick-ask--shell-buffer
              ;; DON'T rename — shell-maker-buffer looks up by name internally,
              ;; renaming breaks shell-maker--process lookup
              ;; Hide this background session from the agent panel buffer list.
              (major-pane-exclude-buffer)
              (add-hook 'kill-buffer-hook
                        (lambda () (setq mr-x/quick-ask--shell-buffer nil))
                        nil t)))
          mr-x/quick-ask--shell-buffer))

      ;; Pre-warm session on startup for instant first response
      (add-hook 'elpaca-after-init-hook #'mr-x/quick-ask--start-session)

      (defun mr-x/quick-ask--reset-session ()
        "Kill the hidden Quick Ask session. Next question starts fresh."
        (interactive)
        (when (and mr-x/quick-ask--shell-buffer
                   (buffer-live-p mr-x/quick-ask--shell-buffer))
          (kill-buffer mr-x/quick-ask--shell-buffer))
        (setq mr-x/quick-ask--shell-buffer nil)
        (message "Quick Ask session reset"))

      ;; Popup buffer-local variables
      (defvar-local mr-x/quick-ask--input-start nil
        "Marker for start of editable text region.")
      (defvar-local mr-x/quick-ask--input-end nil
        "Marker for end of editable text region.")
      (defvar-local mr-x/quick-ask--phase 'input
        "Current phase: input or response.")
      (defvar-local mr-x/quick-ask--field-overlay nil
        "Overlay for the text input field.")
      (defvar-local mr-x/quick-ask--question nil
        "The question that was asked (saved for piping).")
      (defvar-local mr-x/quick-ask--response nil
        "The raw response text (saved for piping).")
      (defvar-local mr-x/quick-ask--thinking-timer nil
        "Timer for the thinking animation.")
      (defvar-local mr-x/quick-ask--turn-subscription nil
        "Subscription token for turn-complete events.")

      ;; Context picker
      (defvar-local mr-x/quick-ask--context-items nil
        "List of context plists: ((:type TYPE :label LABEL :content CONTENT) ...)")
      (defvar-local mr-x/quick-ask--source-buffer nil
        "The buffer that was current when Quick Ask was invoked.")
      (defvar-local mr-x/quick-ask--source-region nil
        "Cons of (BEG . END) if region was active, nil otherwise.")

      (defun mr-x/quick-ask--attach-file ()
        "Attach a file's contents as context."
        (interactive)
        (let* ((file (read-file-name "Attach file: "))
               (size (file-attribute-size (file-attributes file))))
          (when (> size 102400)
            (unless (y-or-n-p (format "File is %dKB — attach truncated (100KB max)? " (/ size 1024)))
              (user-error "Cancelled")))
          (let ((content (with-temp-buffer
                           (insert-file-contents file nil 0 (min size 102400))
                           (when (> size 102400)
                             (goto-char (point-max))
                             (insert "\n... [truncated at 100KB]"))
                           (buffer-string))))
            (push (list :type 'file
                        :label (abbreviate-file-name file)
                        :content content)
                  mr-x/quick-ask--context-items)
            (mr-x/quick-ask--update-context-display))))

      (defun mr-x/quick-ask--attach-buffer ()
        "Attach the source buffer's contents as context."
        (interactive)
        (unless (and mr-x/quick-ask--source-buffer
                     (buffer-live-p mr-x/quick-ask--source-buffer))
          (user-error "Source buffer no longer exists"))
        (let* ((buf mr-x/quick-ask--source-buffer)
               (name (buffer-name buf))
               (content (with-current-buffer buf
                          (let ((lines (count-lines (point-min) (point-max))))
                            (if (> lines 500)
                                (concat (buffer-substring-no-properties
                                         (point-min)
                                         (save-excursion
                                           (goto-char (point-min))
                                           (forward-line 500)
                                           (point)))
                                        "\n... [truncated at 500 lines]")
                              (buffer-substring-no-properties (point-min) (point-max)))))))
          (push (list :type 'buffer :label name :content content)
                mr-x/quick-ask--context-items)
          (mr-x/quick-ask--update-context-display)))

      (defun mr-x/quick-ask--attach-region ()
        "Attach the region that was active when Quick Ask was invoked."
        (interactive)
        (unless mr-x/quick-ask--source-region
          (user-error "No region was active when Quick Ask was invoked"))
        (unless (and mr-x/quick-ask--source-buffer
                     (buffer-live-p mr-x/quick-ask--source-buffer))
          (user-error "Source buffer no longer exists"))
        (let* ((buf mr-x/quick-ask--source-buffer)
               (beg (car mr-x/quick-ask--source-region))
               (end (cdr mr-x/quick-ask--source-region))
               (content (with-current-buffer buf
                          (buffer-substring-no-properties beg end)))
               (line-beg (with-current-buffer buf
                           (line-number-at-pos beg)))
               (line-end (with-current-buffer buf
                           (line-number-at-pos end)))
               (label (format "%s (lines %d-%d)"
                              (buffer-name buf) line-beg line-end)))
          (push (list :type 'region :label label :content content)
                mr-x/quick-ask--context-items)
          (mr-x/quick-ask--update-context-display)))

      (defun mr-x/quick-ask--attach-recall ()
        "Attach an agent-recall transcript as context."
        (interactive)
        (unless (fboundp 'agent-recall--list-transcripts)
          (user-error "agent-recall not loaded"))
        (let* ((transcripts (agent-recall--list-transcripts))
               (selection (completing-read "Attach transcript: "
                                           (mapcar #'car transcripts) nil t))
               (file (cdr (assoc selection transcripts)))
               (content (with-temp-buffer
                          (insert-file-contents file)
                          (let ((str (buffer-string)))
                            (if (> (length str) 5000)
                                (concat (substring str 0 5000)
                                        "\n... [truncated at 5000 chars]")
                              str)))))
          (push (list :type 'recall :label selection :content content)
                mr-x/quick-ask--context-items)
          (mr-x/quick-ask--update-context-display)))

      (defun mr-x/quick-ask--detach-all ()
        "Remove all attached context."
        (interactive)
        (setq mr-x/quick-ask--context-items nil)
        (mr-x/quick-ask--update-context-display)
        (message "All context detached"))

      (defun mr-x/quick-ask--update-context-display ()
        "Update header line to reflect attached context."
        (let* ((count (length mr-x/quick-ask--context-items))
               (base (if (> count 0)
                         (format " Quick Question  [%d attached]  (RET send · C-c d detach · C-g cancel)"
                                 count)
                       " Quick Question  (RET send · C-c f file · C-c b buffer · C-g cancel)")))
          (setq-local header-line-format
                      (propertize base 'face '(:weight bold)))))

      (defun mr-x/quick-ask--format-context-preamble ()
        "Build context string from attached items."
        (if (null mr-x/quick-ask--context-items)
            ""
          (concat "<context>\n"
                  (mapconcat
                   (lambda (item)
                     (let ((type (plist-get item :type))
                           (label (plist-get item :label))
                           (content (plist-get item :content)))
                       (format "## %s: %s\n%s\n"
                               (capitalize (symbol-name type))
                               label content)))
                   (reverse mr-x/quick-ask--context-items)
                   "\n")
                  "</context>\n\n")))

      ;; Input phase keymap
      (defvar mr-x/quick-ask-input-map
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd "RET") #'mr-x/quick-ask--submit)
          (define-key map (kbd "<return>") #'mr-x/quick-ask--submit)
          (define-key map (kbd "C-c C-c") #'mr-x/quick-ask--submit)
          (define-key map (kbd "C-j") #'newline)
          (define-key map (kbd "S-RET") #'newline)
          (define-key map (kbd "S-<return>") #'newline)
          (define-key map (kbd "C-g") #'mr-x/quick-ask--cancel)
          ;; Context picker
          (define-key map (kbd "C-c f") #'mr-x/quick-ask--attach-file)
          (define-key map (kbd "C-c b") #'mr-x/quick-ask--attach-buffer)
          (define-key map (kbd "C-c r") #'mr-x/quick-ask--attach-region)
          (define-key map (kbd "C-c h") #'mr-x/quick-ask--attach-recall)
          (define-key map (kbd "C-c d") #'mr-x/quick-ask--detach-all)
          map)
        "Keymap for the text input field.")

      ;; Waiting phase keymap (active during "Waiting for Claude...")
      (defvar mr-x/quick-ask-waiting-map
        (let ((map (make-keymap)))
          (suppress-keymap map t)
          (define-key map (kbd "C-g") #'mr-x/quick-ask--abort)
          (define-key map (kbd "q") #'mr-x/quick-ask--abort)
          (define-key map (kbd "C-c C-c") #'mr-x/quick-ask--abort)
          (define-key map (kbd "<escape>") #'mr-x/quick-ask--abort)
          map)
        "Keymap active while waiting for Claude response. All keys abort.")

      ;; Response phase keymap
      (defvar mr-x/quick-ask-response-map
        (let ((map (make-keymap)))
          (suppress-keymap map t)
          (define-key map (kbd "q") #'mr-x/quick-ask--dismiss)
          (define-key map (kbd "RET") #'mr-x/quick-ask--dismiss)
          (define-key map (kbd "<return>") #'mr-x/quick-ask--dismiss)
          (define-key map (kbd "<escape>") #'mr-x/quick-ask--dismiss)
          (define-key map (kbd "C-g") #'mr-x/quick-ask--dismiss)
          (define-key map (kbd "j") #'next-line)
          (define-key map (kbd "k") #'previous-line)
          (define-key map (kbd "G") #'end-of-buffer)
          (define-key map (kbd "gg") #'beginning-of-buffer)
          (define-key map (kbd "C-n") #'next-line)
          (define-key map (kbd "C-p") #'previous-line)
          ;; New question (same session — keeps conversation memory)
          (define-key map (kbd "r") #'mr-x/quick-ask--restart)
          ;; New question with fresh session
          (define-key map (kbd "R") #'mr-x/quick-ask--reset-and-restart)
          ;; Surface hidden agent-shell buffer
          (define-key map (kbd "C") #'mr-x/quick-ask--surface-session)
          map)
        "Keymap for response viewing. q dismiss, r again, R reset+again, C surface agent-shell.")

      ;; Major mode
      (define-derived-mode mr-x/quick-ask-mode fundamental-mode "QuickAsk"
        "Major mode for Quick Ask popup."
        (setq-local mode-line-format nil)
        (setq-local cursor-type 'bar)
        (visual-line-mode 1)
        (setq-local word-wrap t)
        (setq-local wrap-prefix "  "))

      ;; Evil integration
      (with-eval-after-load 'evil
        (evil-set-initial-state 'mr-x/quick-ask-mode 'insert)
        (evil-define-key 'normal mr-x/quick-ask-response-map
          (kbd "q") #'mr-x/quick-ask--dismiss
          (kbd "RET") #'mr-x/quick-ask--dismiss
          (kbd "r") #'mr-x/quick-ask--restart
          (kbd "R") #'mr-x/quick-ask--reset-and-restart
          (kbd "C") #'mr-x/quick-ask--surface-session
          (kbd "j") #'next-line
          (kbd "k") #'previous-line
          (kbd "G") #'end-of-buffer
          (kbd "gg") #'beginning-of-buffer))

      ;; Markdown rendering (borrowed from ask-user-popup pattern)
      (defun mr-x/quick-ask--render-markdown ()
        "Apply basic markdown styling to the current buffer."
        (save-excursion
          ;; Bold: **text**
          (goto-char (point-min))
          (while (re-search-forward "\\*\\*\\(.+?\\)\\*\\*" nil t)
            (let ((content (match-string 1))
                  (start (match-beginning 0)))
              (replace-match content t t)
              (put-text-property start (+ start (length content))
                                 'face '(:weight bold))))
          ;; Inline code: `text`
          (goto-char (point-min))
          (while (re-search-forward "`\\([^`\n]+?\\)`" nil t)
            (let ((content (match-string 1))
                  (start (match-beginning 0)))
              (replace-match content t t)
              (put-text-property start (+ start (length content))
                                 'face '(:family "monospace" :background "#2a2a2a"))))
          ;; Headers: # text → bold
          (goto-char (point-min))
          (while (re-search-forward "^#{1,3} \\(.+\\)$" nil t)
            (let ((content (match-string 1))
                  (start (match-beginning 0)))
              (replace-match content t t)
              (put-text-property start (+ start (length content))
                                 'face '(:weight bold :height 1.1))))
          ;; Bullet points: - text → •
          (goto-char (point-min))
          (while (re-search-forward "^\\([ \t]*\\)- " nil t)
            (replace-match (concat (match-string 1) "• ")))))

      ;; Thinking animation
      (defvar-local mr-x/quick-ask--anim-tick 0
        "Frame counter for thinking animation.")

      (defconst mr-x/quick-ask--anim-frames
        ["⋅" "˖" "+" "⟡" "✧" "⟡" "+" "˖"]
        "Pulsing star frames for thinking animation.")

      (defun mr-x/quick-ask--start-thinking-animation ()
        "Start a pulsing star animation in the header line. Returns the timer."
        (when (buffer-live-p (get-buffer "*quick-ask*"))
          (with-current-buffer "*quick-ask*"
            (setq mr-x/quick-ask--anim-tick 0)))
        (run-at-time 0 0.12
                     (lambda ()
                       (when (buffer-live-p (get-buffer "*quick-ask*"))
                         (with-current-buffer "*quick-ask*"
                           (setq mr-x/quick-ask--anim-tick (mod (1+ mr-x/quick-ask--anim-tick) 8))
                           (setq-local header-line-format
                                       (concat (propertize (format " %s " (aref mr-x/quick-ask--anim-frames mr-x/quick-ask--anim-tick))
                                                           'face '(:weight bold))
                                               (propertize "Thinking (Claude)"
                                                           'face '(:weight bold)))))))))

      ;; Commands
      (defun mr-x/quick-ask--cancel ()
        "Cancel and close the popup."
        (interactive)
        (when mr-x/quick-ask--thinking-timer
          (cancel-timer mr-x/quick-ask--thinking-timer))
        (let ((win (get-buffer-window "*quick-ask*")))
          (when win (quit-window t win)))
        (when (buffer-live-p (get-buffer "*quick-ask*"))
          (kill-buffer "*quick-ask*"))
        (message "Cancelled"))

      (defun mr-x/quick-ask--abort ()
        "Abort waiting for Claude and close the popup.
  Cleans up the subscription, timer, and optionally interrupts the shell process."
        (interactive)
        (message "Quick Ask: aborting...")
        ;; Cancel thinking animation
        (when mr-x/quick-ask--thinking-timer
          (cancel-timer mr-x/quick-ask--thinking-timer)
          (setq mr-x/quick-ask--thinking-timer nil))
        ;; Unsubscribe from turn-complete
        (when mr-x/quick-ask--turn-subscription
          (ignore-errors
            (agent-shell-unsubscribe :subscription mr-x/quick-ask--turn-subscription))
          (setq mr-x/quick-ask--turn-subscription nil))
        ;; Interrupt the shell-maker process if it's running
        (when (and mr-x/quick-ask--shell-buffer
                   (buffer-live-p mr-x/quick-ask--shell-buffer))
          (let ((proc (get-buffer-process mr-x/quick-ask--shell-buffer)))
            (when (and proc (process-live-p proc))
              (ignore-errors (interrupt-process proc))
              (message "Quick Ask: interrupted agent-shell process"))))
        ;; Kill popup
        (let ((win (get-buffer-window "*quick-ask*")))
          (when win (quit-window t win)))
        (when (buffer-live-p (get-buffer "*quick-ask*"))
          (kill-buffer "*quick-ask*"))
        (message "Quick Ask: aborted"))

      (defun mr-x/quick-ask--dismiss ()
        "Close the response popup."
        (interactive)
        (when mr-x/quick-ask--thinking-timer
          (cancel-timer mr-x/quick-ask--thinking-timer))
        (let ((win (get-buffer-window "*quick-ask*")))
          (when win (quit-window t win)))
        (when (buffer-live-p (get-buffer "*quick-ask*"))
          (kill-buffer "*quick-ask*")))

      (defun mr-x/quick-ask--restart ()
        "Start a new question (same session — conversation memory preserved)."
        (interactive)
        (mr-x/quick-ask--dismiss)
        (mr-x/quick-ask))

      (defun mr-x/quick-ask--reset-and-restart ()
        "Reset session and start fresh."
        (interactive)
        (mr-x/quick-ask--dismiss)
        (mr-x/quick-ask--reset-session)
        (mr-x/quick-ask))

      (defun mr-x/quick-ask--surface-session ()
        "Surface the hidden agent-shell buffer as a visible window."
        (interactive)
        (let ((shell-buf mr-x/quick-ask--shell-buffer))
          (mr-x/quick-ask--dismiss)
          (if (and shell-buf (buffer-live-p shell-buf))
              (progn
                (setq mr-x/quick-ask--shell-buffer nil)
                (pop-to-buffer shell-buf))
            (message "No active Quick Ask session to surface"))))

      ;; Submit flow — sends to hidden agent-shell
      (defun mr-x/quick-ask--submit ()
        "Submit the question to the hidden agent-shell session."
        (interactive)
        (let ((question (string-trim
                         (buffer-substring-no-properties
                          mr-x/quick-ask--input-start
                          mr-x/quick-ask--input-end))))
          (when (string-empty-p question)
            (user-error "No question provided"))
          ;; Build full prompt with context
          (let* ((preamble (mr-x/quick-ask--format-context-preamble))
                 (full-prompt (concat preamble question))
                 (popup-buf (current-buffer))
                 (shell-buf (mr-x/quick-ask--ensure-session)))
            ;; Check if shell is busy
            (when (with-current-buffer shell-buf (shell-maker-busy))
              (user-error "Claude is still thinking about the previous question"))
            ;; Show thinking state
            (let ((inhibit-read-only t))
              (erase-buffer)
              (remove-overlays)
              (insert (propertize question 'face '(:weight bold :foreground "#88c0d0")))
              (insert "\n\n")
              (insert (propertize "Waiting for Claude...  (q / C-g / C-c C-c to abort)" 'face 'shadow)))
            (setq buffer-read-only t)
            ;; Activate waiting keymap so user can abort
            (setq mr-x/quick-ask--phase 'waiting)
            (use-local-map mr-x/quick-ask-waiting-map)
            (setq mr-x/quick-ask--thinking-timer
                  (mr-x/quick-ask--start-thinking-animation))
            ;; Subscribe to turn-complete BEFORE sending (avoid race condition)
            (let ((sub-token nil))
              (setq sub-token
                    (agent-shell-subscribe-to
                     :shell-buffer shell-buf
                     :event 'turn-complete
                     :on-event
                     (lambda (_event)
                       ;; One-shot: unsubscribe immediately
                       (agent-shell-unsubscribe :subscription sub-token)
                       ;; Extract response and render in popup
                       (when (buffer-live-p popup-buf)
                         (let ((response (with-current-buffer shell-buf
                                           (shell-maker-last-output))))
                           (with-current-buffer popup-buf
                             (mr-x/quick-ask--show-response question response)))))))
              (setq mr-x/quick-ask--turn-subscription sub-token))
            ;; Send the prompt
            (agent-shell--insert-to-shell-buffer
             :shell-buffer shell-buf
             :text full-prompt
             :submit t
             :no-focus t))))

      (defun mr-x/quick-ask--strip-thinking (text)
        "Strip Claude's thinking/reasoning block from response TEXT.
  The agent-shell output includes collapsible thinking fragments that render
  as: ▶ Thinking\\n\\n[reasoning content]\\n\\n[actual response]
  Strip everything up to and including the thinking block."
        (if (and text (string-match "\\`[ \t\n]*▶[^\n]*[Tt]hinking[^\n]*\n\n" text))
            (let ((after-header (match-end 0)))
              ;; The thinking content continues until we hit a double newline
              ;; followed by the actual response. Thinking blocks from agent-shell
              ;; are a single contiguous block, so find the first \n\n boundary.
              (if (string-match "\n\n" text after-header)
                  (string-trim (substring text (match-end 0)))
                ;; No double newline found — entire text is thinking, return empty
                ""))
          (or text "")))

      (defun mr-x/quick-ask--show-response (question response)
        "Render QUESTION and RESPONSE in the popup buffer."
        ;; Stop thinking animation
        (when mr-x/quick-ask--thinking-timer
          (cancel-timer mr-x/quick-ask--thinking-timer)
          (setq mr-x/quick-ask--thinking-timer nil))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (remove-overlays)
          (if (not response)
              (progn
                (setq-local header-line-format
                            (propertize " Request failed" 'face '(:weight bold :foreground "#bf616a")))
                (insert "Error: no response received"))
            ;; Strip thinking block and save Q&A for surfacing
            (let ((clean-response (mr-x/quick-ask--strip-thinking response)))
              (setq mr-x/quick-ask--question question)
              (setq mr-x/quick-ask--response clean-response)
              ;; Header
              (setq-local header-line-format
                          (propertize " AI Response  (q dismiss · r again · R reset · C agent-shell)"
                                      'face '(:weight bold)))
              ;; Question echo
              (insert (propertize question 'face '(:weight bold :foreground "#88c0d0")))
              (insert "\n")
              (insert (propertize "────────────────────────────────────────"
                                  'face 'shadow))
              (insert "\n\n")
              ;; Response body
              (insert clean-response)
              (insert "\n")
              (mr-x/quick-ask--render-markdown)
              (goto-char (point-min))))
          ;; Switch to response phase
          (setq mr-x/quick-ask--phase 'response)
          (use-local-map mr-x/quick-ask-response-map)
          (setq buffer-read-only t)
          (when (fboundp 'evil-normal-state)
            (evil-normal-state))))

      ;; Main entry point
      (defun mr-x/quick-ask ()
        "Ask a quick question in a bottom popup. Powered by Claude via agent-shell."
        (interactive)
        ;; Capture context before opening popup
        (let ((source-buf (current-buffer))
              (region-active (use-region-p))
              (region-beg (when (use-region-p) (region-beginning)))
              (region-end (when (use-region-p) (region-end))))
          (let ((buf (get-buffer-create "*quick-ask*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (remove-overlays)
                (mr-x/quick-ask-mode)
                (setq mr-x/quick-ask--phase 'input)
                (setq buffer-read-only nil)
                ;; Save source context
                (setq mr-x/quick-ask--source-buffer source-buf)
                (setq mr-x/quick-ask--source-region
                      (when region-active (cons region-beg region-end)))
                (setq mr-x/quick-ask--context-items nil)

                ;; Auto-attach region if active
                (when region-active
                  (let* ((content (with-current-buffer source-buf
                                    (buffer-substring-no-properties region-beg region-end)))
                         (line-beg (with-current-buffer source-buf
                                     (line-number-at-pos region-beg)))
                         (line-end (with-current-buffer source-buf
                                     (line-number-at-pos region-end)))
                         (label (format "%s (lines %d-%d)"
                                        (buffer-name source-buf) line-beg line-end)))
                    (push (list :type 'region :label label :content content)
                          mr-x/quick-ask--context-items)))

                ;; Header
                (mr-x/quick-ask--update-context-display)

                ;; Prompt label
                (insert (propertize "Ask anything:" 'face '(:weight bold)))
                (insert "\n")
                (insert (propertize "────────────────────────────────────────"
                                    'face 'shadow))
                (insert "\n")

                ;; Context indicator
                (when mr-x/quick-ask--context-items
                  (insert (propertize
                           (format "  attached: %s"
                                   (mapconcat (lambda (item) (plist-get item :label))
                                              mr-x/quick-ask--context-items ", "))
                           'face 'shadow))
                  (insert "\n"))

                ;; Editable text region
                (setq mr-x/quick-ask--input-start (point-marker))
                (set-marker-insertion-type mr-x/quick-ask--input-start nil)
                (insert "\n")
                (setq mr-x/quick-ask--input-end (point-marker))
                (set-marker-insertion-type mr-x/quick-ask--input-end t)

                ;; Field overlay — sparse keymap so typing works naturally
                (setq mr-x/quick-ask--field-overlay
                      (make-overlay (marker-position mr-x/quick-ask--input-start)
                                    (marker-position mr-x/quick-ask--input-end)
                                    nil nil t))
                (overlay-put mr-x/quick-ask--field-overlay 'local-map mr-x/quick-ask-input-map)
                (overlay-put mr-x/quick-ask--field-overlay 'face '(:extend t))))

            ;; Display at bottom
            (let ((win (display-buffer buf
                                       '((display-buffer-at-bottom)
                                         (window-height . 0.4)
                                         (preserve-size . (nil . t))))))
              (select-window win)
              (goto-char mr-x/quick-ask--input-start)
              (when (fboundp 'evil-insert-state)
                (evil-insert-state))))))

