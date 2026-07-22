;;; early-init.el --- Early Init File -*- lexical-binding: t -*-

;; Fix for yabai window management - removes titlebar
;; Use 'undecorated' for sharp corners or 'undecorated-round' for rounded
(add-to-list 'default-frame-alist '(undecorated-round . t))

;; Suppress native-comp warnings from popping up
(setq native-comp-async-report-warnings-errors 'silent)
(setq native-comp-warning-on-missing-source nil)

;; Never load a stale .elc when the .el is newer. Elpaca's builds/ dir
;; symlinks .el files into sources/, so editing a package repo (e.g.
;; hacking on agent-shell) leaves the neighboring .elc stale — without
;; this, Emacs silently keeps running the OLD compiled code. Must be set
;; here (before any loading) to cover init + all packages.
(setq load-prefer-newer t)

;; Performance optimizations
(setq gc-cons-threshold most-positive-fixnum)
(setq gc-cons-percentage 0.6)
(setq package-enable-at-startup nil)
(setq frame-inhibit-implied-resize t)

;; Disable unnecessary UI elements early
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
