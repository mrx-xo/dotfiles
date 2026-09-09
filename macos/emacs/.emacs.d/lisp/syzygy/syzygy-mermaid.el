;;; syzygy-mermaid.el --- Mermaid config export for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The phone renders Mermaid fences with the same engine and the same
;; look as the Emacs markdown-xwidget preview.  Rather than a second
;; copy of the gruvbox palette hand-maintained in index.html, the rig's
;; `mr-x/markdown-mermaid-config' (emacs.org, markdown-xwidget block) is
;; the single source of truth: it is written out as JSON to
;; `syzygy-mermaid-config-file', and acp-mobile's /api/mermaid-config
;; serves that file when present, its own defaults when not.
;;
;; A file rather than an elisp call (the route syzygy-presets and
;; syzygy-models take) because the page needs the config on first paint,
;; before any agent session exists, and it must still be right when
;; Emacs is not running.
;;
;; `startOnLoad' is dropped: the phone renders explicitly per block from
;; `renderDiagrams', never by scanning the document.

;;; Code:

(require 'json)

(defvar mr-x/markdown-mermaid-config)

(defcustom syzygy-mermaid-config-file
  (expand-file-name "~/.acp-mobile/mermaid.json")
  "Where the exported Mermaid configuration is written for acp-mobile."
  :type 'file
  :group 'syzygy)

(defun syzygy-mermaid--payload ()
  "Return the rig's Mermaid config as a JSON string, or nil if unavailable.
`startOnLoad' is removed: the phone renders each block explicitly."
  (when (fboundp 'mr-x/markdown-mermaid-config)
    (let ((config (assq-delete-all 'startOnLoad
                                   (copy-alist (mr-x/markdown-mermaid-config)))))
      (json-encode config))))

;;;###autoload
(defun syzygy-export-mermaid-config ()
  "Export the rig's Mermaid configuration for acp-mobile.
Writes `syzygy-mermaid-config-file' and returns its path.  Returns nil
when `mr-x/markdown-mermaid-config' is unavailable, which leaves the
phone on its built-in defaults.  Rewrites only on a real change, so the
markdown-xwidget `:config' block can call this on every load without
churning the file's mtime."
  (interactive)
  (let ((payload (syzygy-mermaid--payload)))
    (cond
     ((null payload)
      (when (called-interactively-p 'interactive)
        (message "SYZYGY: no Mermaid config to export (markdown-xwidget not loaded)"))
      nil)
     (t
      (let ((file syzygy-mermaid-config-file))
        (make-directory (file-name-directory file) t)
        (unless (and (file-readable-p file)
                     (string= payload
                              (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))))
          (with-temp-file file (insert payload)))
        (when (called-interactively-p 'interactive)
          (message "SYZYGY: Mermaid config exported to %s" file))
        file)))))

(provide 'syzygy-mermaid)
;;; syzygy-mermaid.el ends here
