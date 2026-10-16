;;; ob-chromium-test.el --- Tests for ob-chromium  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 James Gornet

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Unit tests run without Chromium.  Integration tests run when a
;; browser is found and are skipped otherwise.  Set
;; OB_CHROMIUM_EXTRA_ARGS, for example to --no-sandbox, for a
;; container.
;;
;; Run with:
;;   emacs --batch -L . -l ob-chromium-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'ob-chromium)

;;;; Executable

(ert-deftest ob-chromium-test-executable-set ()
  "`ob-chromium-executable' wins when it is set and executable."
  (let ((ob-chromium-executable "/bin/sh"))
    (should (equal (ob-chromium--executable) "/bin/sh"))))

(ert-deftest ob-chromium-test-executable-set-not-executable ()
  "A set but missing `ob-chromium-executable' is a `user-error'."
  (let ((ob-chromium-executable "/nonexistent/chromium"))
    (should-error (ob-chromium--executable) :type 'user-error)))

(ert-deftest ob-chromium-test-executable-candidates ()
  "Names resolve on `exec-path', absolute paths resolve as files."
  (let* ((dir (make-temp-file "ob-chromium-test" t))
         (fake (expand-file-name "fake-chromium" dir)))
    (unwind-protect
        (progn
          (with-temp-file fake (insert "#!/bin/sh\n"))
          (set-file-modes fake #o755)
          (let ((ob-chromium-executable nil)
                (ob-chromium--executable-cache nil)
                (ob-chromium-candidates '("no-such-browser-xyz" "fake-chromium"))
                (exec-path (list dir)))
            (should (equal (ob-chromium--executable) fake))
            (should (equal ob-chromium--executable-cache fake)))
          (let ((ob-chromium-executable nil)
                (ob-chromium--executable-cache nil)
                (ob-chromium-candidates (list "no-such-browser-xyz" fake))
                (exec-path nil))
            (should (equal (ob-chromium--executable) fake))))
      (delete-directory dir t))))

(ert-deftest ob-chromium-test-executable-none ()
  "No candidate resolves: `user-error'."
  (let ((ob-chromium-executable nil)
        (ob-chromium--executable-cache nil)
        (ob-chromium-candidates '("no-such-browser-xyz"))
        (exec-path nil))
    (should-error (ob-chromium--executable) :type 'user-error)))

;;;; Running a process

(ert-deftest ob-chromium-test-run ()
  "`ob-chromium--run' returns the exit code, stdout and stderr."
  (let ((result (ob-chromium--run
                 (list "sh" "-c" "echo out; echo err >&2; exit 3"))))
    (should (equal (nth 0 result) 3))
    (should (equal (nth 1 result) "out\n"))
    (should (equal (nth 2 result) "err\n"))))

(provide 'ob-chromium-test)

;;; ob-chromium-test.el ends here
