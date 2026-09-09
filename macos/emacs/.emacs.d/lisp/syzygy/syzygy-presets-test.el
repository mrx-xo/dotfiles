;;; syzygy-presets-test.el --- Tests for syzygy-presets -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)

;; Declared special here too: a `let' in this lexical-binding file would
;; otherwise bind it lexically and the bridge would not see it.
(defvar mr-x/agent-shell-presets)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "syzygy-bridge.el" dir) nil t)
  (load (expand-file-name "syzygy-presets.el" dir) nil t))

(defun syzygy-presets-test--decode (encoded)
  "Decode ENCODED base64 JSON into a list of alists."
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist
   :array-type 'list))

(ert-deftest syzygy-presets-json-mirrors-the-rig-list ()
  "Key, label, model, mode, agent and effort travel; order is the rig's."
  (let ((mr-x/agent-shell-presets
         '((?f "Fable 5.1 · Bypass" "fable[1m]" "bypassPermissions")
           (?F "Fable 5 · Bypass" "claude-fable-5[1m]" "bypassPermissions")
           (?a "Astra · Full" "gpt-6-astra" "agent-full-access"
               agent-shell-openai-make-codex-config "high")
           (?d "DeepSeek · Accept" "default" "acceptEdits"
               mr-x/agent-shell-make-deepseek-config))))
    (let ((got (syzygy-presets-test--decode (syzygy-presets-json))))
      (should (equal (mapcar (lambda (p) (alist-get 'key p)) got)
                     '("f" "F" "a" "d")))
      (should (equal (alist-get 'label (car got)) "Fable 5.1 · Bypass"))
      (should (equal (alist-get 'model (car got)) "fable[1m]"))
      (should (equal (alist-get 'mode (car got)) "bypassPermissions"))
      (should (equal (alist-get 'agent (car got)) "claude"))
      (should (equal (alist-get 'effort (car got)) ""))
      (should (equal (alist-get 'agent (nth 2 got)) "codex"))
      (should (equal (alist-get 'effort (nth 2 got)) "high"))
      (should (equal (alist-get 'agent (nth 3 got)) "deepseek")))))

(ert-deftest syzygy-presets-json-empty-list-is-an-empty-array ()
  "No presets is a valid answer (phone shows only default), not a 404."
  (let ((mr-x/agent-shell-presets nil))
    (should (equal (syzygy-presets-test--decode (syzygy-presets-json)) '()))))

(ert-deftest syzygy-presets-json-is-nil-without-the-rig-variable ()
  "An unbound presets list is a 404 on the phone, not a daemon error."
  (let ((saved (and (boundp 'mr-x/agent-shell-presets) mr-x/agent-shell-presets)))
    (unwind-protect
        (progn (makunbound 'mr-x/agent-shell-presets)
               (should (null (syzygy-presets-json))))
      (setq mr-x/agent-shell-presets saved))))

(provide 'syzygy-presets-test)
;;; syzygy-presets-test.el ends here
