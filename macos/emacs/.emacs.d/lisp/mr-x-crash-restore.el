;;; mr-x-crash-restore.el --- Frame reconstruction transaction -*- lexical-binding: t; -*-

;;; Commentary:
;; Rebuilds frames from a validated session as one attempt.  Every frame is
;; created with `client' nil, so a request arriving through emacsclient still
;; gets one live root window, and with its restore key as a frame parameter.
;; The caller's replay function fills each frame.  Any failure deletes every
;; frame this attempt created, newest first; frames that refuse deletion are
;; reported as leaked so the caller can block retries until they are gone.
;;
;; Buffers and processes made by replay handlers are not tracked yet; that
;; ledger is the next step of the design.  Frame primitives are injectable
;; so the transaction is testable without a window system.  Loading is inert.

;;; Code:

(require 'cl-lib)
(require 'mr-x-crash-capture)

(defun mr-x/crash-restore-legacy-session (session)
  "Return SESSION with generated restore keys for a flat legacy snapshot."
  (cl-loop for frame in session for n from 1
           collect (plist-put (copy-sequence frame) :restore-key (format "legacy-%d" n))))

(defun mr-x/crash-restore--parameters (record)
  "Frame parameters for RECORD: NS, no client, the key, then geometry."
  (append (list (cons 'window-system 'ns)
                (cons 'client nil)
                (cons 'mr-x/restore-key (plist-get record :restore-key)))
          (cl-loop for field in '(left top width height fullscreen)
                   for value = (plist-get record (intern (format ":%s" field)))
                   when value collect (cons field value))))

(defun mr-x/crash-restore-frames (session replay &optional make delete)
  "Create one frame per SESSION record and REPLAY each window tree.
SESSION is validated before any frame exists.  REPLAY receives the new
frame and the record's :window-tree.  MAKE and DELETE default to
`make-frame' and `delete-frame'.

Return (:status restored :frames ((:restore-key KEY :frame FRAME) ...)) in
session order.  On any failure, delete every frame this attempt created,
newest first, and return (:status failed :errors ((:restore-key KEY :phase
frame|tree :error MESSAGE)) :leaked (KEY ...)) where :leaked names frames
that could not be deleted."
  (unless session (mr-x/crash-capture--invalid "Empty session"))
  (mr-x/crash-capture--session-keys session)
  (let ((make (or make #'make-frame))
        (delete (or delete #'delete-frame))
        (created nil) (failure nil))
    (dolist (record session)
      (unless failure
        (let ((key (plist-get record :restore-key)) (frame nil))
          (condition-case err
              (setq frame (funcall make (mr-x/crash-restore--parameters record)))
            ((error quit) (setq failure (list :restore-key key :phase 'frame
                                              :error (error-message-string err)))))
          (when frame
            (push (list :restore-key key :frame frame) created)
            (condition-case err
                (funcall replay frame (plist-get record :window-tree))
              ((error quit) (setq failure (list :restore-key key :phase 'tree
                                                :error (error-message-string err)))))))))
    (if (not failure)
        (list :status 'restored :frames (nreverse created))
      (let ((leaked nil))
        ;; `created' is newest first; keep going past a failed deletion.
        (dolist (entry created)
          (condition-case nil
              (funcall delete (plist-get entry :frame) t)
            (error (push (plist-get entry :restore-key) leaked))))
        (list :status 'failed :errors (list failure) :leaked (nreverse leaked))))))

(provide 'mr-x-crash-restore)
;;; mr-x-crash-restore.el ends here
