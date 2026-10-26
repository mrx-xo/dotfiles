;;; syzygy-projects.el --- project list for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The phone's spawn sheet mirrors the rig's project dashboard list.

;;; Code:

(require 'syzygy-bridge)

(defvar project-dashboard-projects)

(defun syzygy-projects-json ()
  "Return the rig's projects as base64-wrapped JSON, or nil if unavailable."
  (when (boundp 'project-dashboard-projects)
    (syzygy-bridge-encode-json
     (vconcat
      (mapcar (lambda (project)
                `((name . ,(car project))
                  (path . ,(expand-file-name (cdr project)))))
              project-dashboard-projects)))))

(provide 'syzygy-projects)
;;; syzygy-projects.el ends here
