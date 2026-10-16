;;; test-init.el --- Minimal init for trying ob-chromium  -*- lexical-binding: t; -*-

;;; Commentary:

;; Used by dev-test.sh:
;;   emacs -Q -l test-init.el test-example.org
;; Loads the package from this directory, enables the chromium
;; language, turns off the evaluation prompt and shows images inline.
;; OB_CHROMIUM_EXTRA_ARGS adds flags, for example --no-sandbox in a
;; container.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'org)
(require 'ob-chromium)

(org-babel-do-load-languages 'org-babel-load-languages '((chromium . t)))
(setq org-confirm-babel-evaluate nil)
(setq vc-handled-backends nil)
(setq org-startup-with-inline-images t)
(add-hook 'org-babel-after-execute-hook #'org-redisplay-inline-images)

(let ((extra (getenv "OB_CHROMIUM_EXTRA_ARGS")))
  (when (and extra (not (string-empty-p extra)))
    (setq ob-chromium-extra-args (split-string extra))))

;;; test-init.el ends here
