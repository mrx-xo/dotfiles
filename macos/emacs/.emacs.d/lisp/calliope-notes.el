;;; calliope-notes.el --- Send CALLIOPE drawings into an agent-shell chat -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Keywords: convenience, tools

;;; Commentary:

;; BOOX Notes on CALLIOPE (the e-ink tablet) exports a notebook to
;; /sdcard/note/<notebook>/<notebook>.pdf.  The Syncthing folder
;; `calliope-notes' (send-only on the tablet, receive-only here) mirrors
;; that tree into `calliope-notes-directory'.
;;
;; `calliope-notes-send-newest' picks the newest export, renders a PDF
;; to PNG with sips (agent-shell attachments have to be images), and
;; attaches it to an agent-shell chat as an @-mention, the same way
;; agent-shell-inbox does for phone screenshots.  Bound to `SPC . n'.

;;; Code:

;; No (require 'agent-shell): same rule as agent-shell-inbox.el.  The
;; send command only runs inside a live agent-shell session, so
;; agent-shell is loaded by the time it is called.
(require 'seq)
(require 'subr-x)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-inbox--attachment-text "agent-shell-inbox")

(defgroup calliope-notes nil
  "Send CALLIOPE drawings into an agent-shell chat."
  :group 'agent-shell)

(defcustom calliope-notes-directory (expand-file-name "~/calliope/notes/")
  "Where Syncthing lands CALLIOPE's BOOX Notes exports (receive-only)."
  :type 'directory)

(defcustom calliope-notes-render-directory (expand-file-name "~/calliope/png/")
  "Cache of rendered PNGs.  Kept outside the Syncthing folder so nothing
is written into a receive-only tree, and outside ~/agent-inbox so an
armed inbox never double-attaches them."
  :type 'directory)

(defcustom calliope-notes-file-regexp "\\.\\(pdf\\|png\\|jpe?g\\|webp\\)\\'"
  "Exports worth sending.  Anything else in the tree is ignored."
  :type 'regexp)

(defun calliope-notes--candidate-p (path)
  "Non-nil when PATH is a sendable export (not a dotfile, matches the regexp)."
  (let ((name (file-name-nondirectory path)))
    (and (not (string-prefix-p "." name))
         (string-match-p calliope-notes-file-regexp name))))

(defun calliope-notes--visible-dir-p (dir)
  "Non-nil unless DIR is a dot directory (.stfolder, .stversions, ...)."
  (not (string-prefix-p "." (file-name-nondirectory (directory-file-name dir)))))

(defun calliope-notes--mtime (path)
  "Modification time of PATH."
  (file-attribute-modification-time (file-attributes path)))

(defun calliope-notes-files (&optional directory)
  "Sendable exports under DIRECTORY (default `calliope-notes-directory'), newest first."
  (let ((dir (or directory calliope-notes-directory)))
    (when (file-directory-p dir)
      (sort (seq-filter #'calliope-notes--candidate-p
                        (directory-files-recursively
                         dir "" nil #'calliope-notes--visible-dir-p))
            (lambda (a b)
              (time-less-p (calliope-notes--mtime b) (calliope-notes--mtime a)))))))

(defun calliope-notes-newest (&optional directory)
  "Newest sendable export under DIRECTORY, or nil."
  (car (calliope-notes-files directory)))

(defun calliope-notes--safe-name (path)
  "Base name of PATH with anything that is not [A-Za-z0-9._-] turned into `-'.
The @-mention parser splits on whitespace, so \"OP sketch.pdf\" must
not reach the prompt with its space intact."
  (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" (file-name-base path)))

(defun calliope-notes--render-target (path)
  "PNG path for PATH in the render cache, keyed by name and mtime.
A re-export overwrites the PDF in place on the tablet, so the mtime is
what distinguishes one version of a notebook from the next."
  (expand-file-name
   (format "%s-%s.png"
           (calliope-notes--safe-name path)
           (format-time-string "%Y%m%d-%H%M%S" (calliope-notes--mtime path)))
   calliope-notes-render-directory))

(defun calliope-notes--sips (source target)
  "Render the first page of SOURCE to PNG at TARGET with sips."
  (let ((sips (or (executable-find "sips")
                  (error "calliope-notes: sips not found, cannot render %s" source))))
    (with-temp-buffer
      (unless (zerop (call-process sips nil t nil
                                   "-s" "format" "png" source "--out" target))
        (error "calliope-notes: sips failed on %s: %s"
               source (string-trim (buffer-string)))))))

(defun calliope-notes-render (path)
  "Return an image file for PATH, ready to attach.
PDFs are rendered to PNG; images are copied.  Either way the result
lives in `calliope-notes-render-directory' under a whitespace-free
name, and is reused when the same version was rendered before."
  (let ((target (calliope-notes--render-target path)))
    (unless (file-exists-p target)
      (make-directory calliope-notes-render-directory t)
      (if (string-match-p "\\.pdf\\'" path)
          (calliope-notes--sips path target)
        (copy-file path target)))
    target))

(defun calliope-notes--attachment-text (image)
  "Sendable prompt text for IMAGE, with a thumbnail when agent-shell-inbox can make one."
  (or (and (fboundp 'agent-shell-inbox--attachment-text)
           (ignore-errors (agent-shell-inbox--attachment-text image)))
      (concat "@" (expand-file-name image))))

(defun calliope-notes--chat-buffers ()
  "Live agent-shell buffers."
  (seq-filter (lambda (b)
                (with-current-buffer b (derived-mode-p 'agent-shell-mode)))
              (buffer-list)))

(defun calliope-notes--chat-buffer ()
  "The agent-shell buffer to attach to: the current one, else ask."
  (cond
   ((derived-mode-p 'agent-shell-mode) (current-buffer))
   ((null (calliope-notes--chat-buffers))
    (user-error "No agent-shell chat open to send the drawing to"))
   (t (get-buffer
       (completing-read "Send drawing to chat: "
                        (mapcar #'buffer-name (calliope-notes--chat-buffers))
                        nil t)))))

;;;###autoload
(defun calliope-notes-send-newest (&optional buffer)
  "Attach CALLIOPE's newest drawing to an agent-shell chat.
BUFFER defaults to the current agent-shell buffer, or a picked one.
The drawing is whatever BOOX Notes exported last; export on the tablet
first, Syncthing brings it over, then this key."
  (interactive)
  (let* ((source (or (calliope-notes-newest)
                     (user-error "No drawings in %s yet (export one on CALLIOPE; is its Syncthing running?)"
                                 (abbreviate-file-name calliope-notes-directory))))
         (image (calliope-notes-render source))
         (buf (or buffer (calliope-notes--chat-buffer))))
    (with-current-buffer buf
      (agent-shell-insert :text (calliope-notes--attachment-text image)
                          :shell-buffer buf
                          :no-focus t))
    (message "CALLIOPE: attached %s (exported %s) to %s"
             (file-name-nondirectory source)
             (format-time-string "%H:%M" (calliope-notes--mtime source))
             (buffer-name buf))))

(provide 'calliope-notes)
;;; calliope-notes.el ends here
