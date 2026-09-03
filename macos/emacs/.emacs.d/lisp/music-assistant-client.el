;;; music-assistant-client.el --- Music Assistant protocol client -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Transport and state boundary for the native Music Assistant dashboard.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup music-assistant-client nil
  "Connect to Music Assistant over its WebSocket API."
  :group 'multimedia)

(provide 'music-assistant-client)

;;; music-assistant-client.el ends here
