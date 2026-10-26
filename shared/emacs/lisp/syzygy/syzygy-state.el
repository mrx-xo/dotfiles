;;; syzygy-state.el --- One state directory for acp-mobile sidecar files -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Every SYZYGY write into the acp-mobile state directory goes through
;; `syzygy-state-file'.  acp-mobile (Go) reads these files from
;; `os.UserHomeDir()/.acp-mobile', which is %USERPROFILE% on Windows and
;; ~ elsewhere.  Emacs on Windows resolves ~ to %APPDATA%, so the
;; directory is computed here to match Go rather than trusting ~.

;;; Code:

(defvar syzygy-state-directory nil
  "When non-nil, overrides the computed state directory (for tests).")

(defun syzygy-state-dir ()
  "Return the acp-mobile state directory, with a trailing slash."
  (or syzygy-state-directory
      (if (eq system-type 'windows-nt)
          (expand-file-name ".acp-mobile/" (or (getenv "USERPROFILE") "~"))
        (expand-file-name "~/.acp-mobile/"))))

(defun syzygy-state-file (name)
  "Return the absolute path of NAME inside the state directory."
  (expand-file-name name (syzygy-state-dir)))

(provide 'syzygy-state)
;;; syzygy-state.el ends here
