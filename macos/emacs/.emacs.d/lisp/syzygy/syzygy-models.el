;;; syzygy-models.el --- Session models for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; List and switch live agent-shell models through the phone JSON bridge.
;; Agent-shell helpers resolve at runtime, without loading the package here.

;;; Code:

(require 'map)
(require 'seq)
(require 'syzygy-bridge)

(declare-function agent-shell--state "agent-shell" ())
(declare-function agent-shell--current-model-id "agent-shell-config" (state))
(declare-function agent-shell--get-available-models "agent-shell-config" (state))
(declare-function agent-shell--config-option-set-model-id "agent-shell"
                  (&rest args))

(defun syzygy-models--live-state ()
  "Return the current buffer's live agent-shell state, or nil."
  (when (derived-mode-p 'agent-shell-mode)
    (let ((state (condition-case nil
                     (agent-shell--state)
                   (error nil))))
      (and (map-nested-elt state '(:session :id)) state))))

(defun syzygy-models-json (buffer-name)
  "Return BUFFER-NAME's models as base64 JSON, or nil if not live."
  (when-let* ((buffer (get-buffer buffer-name)))
    (with-current-buffer buffer
      (when-let* ((state (syzygy-models--live-state)))
        (syzygy-bridge-encode-json
         `((current . ,(or (agent-shell--current-model-id state) ""))
           (models . ,(vconcat
                       (mapcar
                        (lambda (model)
                          `((id . ,(map-elt model :model-id))
                            (name . ,(map-elt model :name))
                            (description . ,(or (map-elt model :description) ""))))
                        (agent-shell--get-available-models state))))))))))

(defun syzygy-models--set (state model-id)
  "Set MODEL-ID from STATE and return a JSON-ready result alist."
  (cond
   ((not (seq-find (lambda (model)
                    (equal (map-elt model :model-id) model-id))
                  (agent-shell--get-available-models state)))
    '((ok . :false) (error . "Unknown model id")))
   ((equal model-id (agent-shell--current-model-id state))
    `((ok . t) (current . ,model-id)))
   (t
    (let ((deadline (+ (float-time) 15.0))
          result)
      (condition-case err
          (progn
            (agent-shell--config-option-set-model-id
             :model-id model-id
             :on-success (lambda ()
                           (unless result
                             (setq result `((ok . t) (current . ,model-id)))))
             :on-failure (lambda (err _raw)
                           (unless result
                             (setq result
                                   `((ok . :false)
                                     (error . ,(format "%s" err)))))))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output nil 0.1)))
        (error
         (unless result
           (setq result `((ok . :false)
                          (error . ,(error-message-string err)))))))
      ;; Settle the result so a late callback cannot replace the timeout.
      (or result
          (setq result '((ok . :false) (error . "Model switch timed out"))))))))

(defun syzygy-model-set-json (buffer-name model-id)
  "Set BUFFER-NAME's MODEL-ID and return base64 JSON, or nil if not live.
Wait at most about 15 seconds for the asynchronous model callback."
  (when-let* ((buffer (get-buffer buffer-name)))
    (with-current-buffer buffer
      (when-let* ((state (syzygy-models--live-state)))
        (syzygy-bridge-encode-json
         (syzygy-models--set state model-id))))))

(provide 'syzygy-models)
;;; syzygy-models.el ends here
