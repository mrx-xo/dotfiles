;;; agent-shell-link-hint-test.el --- Link discovery regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'link-hint)
(require 'agent-shell-link-hint nil t)

(ert-deftest agent-shell-link-hint-discovers-rendered-labels ()
  ;; Visible labels have no Markdown syntax or literal destination path.
  (with-temp-buffer
    (setq major-mode 'agent-shell-mode)
    (insert "See ")
    (insert (propertize "source.el" 'agent-shell-markdown-url "/tmp/source.el"))
    (insert " and ")
    (insert (propertize "website" 'agent-shell-markdown-url "https://example.org"))
    (insert ".")
    (let (links)
      (dolist (type link-hint-types)
        (when (and (eq type 'link-hint-agent-shell)
                   (link-hint--type-valid-p type))
          (setq links (reverse (link-hint--collect (point-min) (point-max) type)))))
      (should (equal (mapcar (lambda (link) (plist-get link :pos)) links)
                     '(5 19)))
      (should (equal (mapcar (lambda (link) (plist-get link :args)) links)
                     '("/tmp/source.el" "https://example.org"))))))

(ert-deftest agent-shell-link-hint-respects-region-boundaries ()
  (with-temp-buffer
    (setq major-mode 'agent-shell-mode)
    (insert (propertize "first" 'agent-shell-markdown-url "/tmp/first"))
    (insert " ")
    (insert (propertize "second" 'agent-shell-markdown-url "/tmp/second"))
    (should (memq 'link-hint-agent-shell link-hint-types))
    (should (equal (mapcar (lambda (link) (plist-get link :args))
                          (link-hint--collect 3 7 'link-hint-agent-shell))
                   '("/tmp/first")))))

;;; agent-shell-link-hint-test.el ends here
