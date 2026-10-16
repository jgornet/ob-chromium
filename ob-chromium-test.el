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

;;;; Document assembly

(defmacro ob-chromium-test--with-org (text &rest body)
  "Run BODY in a temporary `org-mode' buffer holding TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

(ert-deftest ob-chromium-test-full-document-p ()
  "Doctype and <html> in any case and after whitespace are documents."
  (should (ob-chromium--full-document-p "<!DOCTYPE html><html></html>"))
  (should (ob-chromium--full-document-p "\n  <!doctype html>"))
  (should (ob-chromium--full-document-p "<HTML lang=\"en\">"))
  (should (ob-chromium--full-document-p "<html>"))
  (should-not (ob-chromium--full-document-p "<div>x</div>"))
  (should-not (ob-chromium--full-document-p "<!-- c --><html>"))
  (should-not (ob-chromium--full-document-p "")))

(ert-deftest ob-chromium-test-assemble-fragment ()
  "A fragment is wrapped with the base URL, the CSS and the body."
  (let ((doc (ob-chromium--assemble "<p>hi</p>" "p { color: red }" "file:///d/")))
    (should (string-prefix-p "<!DOCTYPE html>" doc))
    (should (string-match-p "<base href=\"file:///d/\">" doc))
    (should (string-match-p "<style>\np { color: red }\n</style>" doc))
    (should (string-match-p "<body>\n<p>hi</p>\n</body>" doc))))

(ert-deftest ob-chromium-test-assemble-fragment-percent ()
  "A percent sign in the body or the CSS survives `format-spec'."
  (let ((doc (ob-chromium--assemble "<p>100%</p>" "div { width: 50% }" "file:///d/")))
    (should (string-match-p "<p>100%</p>" doc))
    (should (string-match-p "width: 50%" doc))))

(ert-deftest ob-chromium-test-assemble-fragment-no-css ()
  "Without CSS the style element is empty."
  (let ((doc (ob-chromium--assemble "<p>hi</p>" nil "file:///d/")))
    (should (string-match-p "<style>\n\n</style>" doc))))

(ert-deftest ob-chromium-test-assemble-document-head ()
  "A document with </head> gets the base and style before it."
  (let ((doc (ob-chromium--assemble
              "<!DOCTYPE html>\n<html><head><title>t</title></head><body>b</body></html>"
              "b { margin: 0 }" "file:///d/")))
    (should (string-match-p "<title>t</title><base href=\"file:///d/\">\n<style>\nb { margin: 0 }\n</style>\n</head>" doc))
    (should (= 1 (length (split-string doc "<!DOCTYPE" t))))))

(ert-deftest ob-chromium-test-assemble-document-no-head ()
  "A document without </head> gets the base and style after <html>."
  (let ((doc (ob-chromium--assemble "<html lang=\"en\"><body>b</body></html>" "" "file:///d/")))
    (should (string-prefix-p "<html lang=\"en\">\n<base href=\"file:///d/\">\n<style>" doc))))

(ert-deftest ob-chromium-test-assemble-document-backslash ()
  "Backslashes in the CSS are kept literally in a full document."
  (let ((doc (ob-chromium--assemble "<html><head></head></html>" "p::before { content: \"\\201C\" }" "file:///d/")))
    (should (string-match-p (regexp-quote "content: \"\\201C\"") doc))))

(ert-deftest ob-chromium-test-css-named-block ()
  ":css resolves named blocks in the buffer, in order."
  (ob-chromium-test--with-org
      "#+NAME: theme\n#+begin_src css\nbody { color: red }\n#+end_src\n\n#+NAME: more\n#+begin_src css\np { margin: 0 }\n#+end_src\n"
    (should (equal (ob-chromium--css '((:css . "theme more")))
                   "body { color: red }\np { margin: 0 }"))
    (should (equal (ob-chromium--css '((:css . "more theme")))
                   "p { margin: 0 }\nbody { color: red }"))))

(ert-deftest ob-chromium-test-css-file ()
  ":css resolves a file relative to `default-directory'."
  (let* ((dir (make-temp-file "ob-chromium-test" t))
         (default-directory (file-name-as-directory dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.css" dir) (insert "a { x: 1 }"))
          (ob-chromium-test--with-org "#+NAME: b\n#+begin_src css\nb { y: 2 }\n#+end_src\n"
            (should (equal (ob-chromium--css '((:css . "a.css b")))
                           "a { x: 1 }\nb { y: 2 }"))))
      (delete-directory dir t))))

(ert-deftest ob-chromium-test-css-missing ()
  "An item that is neither a block nor a file is a `user-error'."
  (ob-chromium-test--with-org ""
    (should-error (ob-chromium--css '((:css . "nothing-here"))) :type 'user-error)))

(ert-deftest ob-chromium-test-css-absent ()
  "Without :css the CSS is nil."
  (should-not (ob-chromium--css '((:file . "x.png")))))

(ert-deftest ob-chromium-test-expand-body ()
  "`org-babel-expand-body:chromium' returns the assembled document."
  (ob-chromium-test--with-org "#+NAME: t\n#+begin_src css\nq { z: 3 }\n#+end_src\n"
    (let ((doc (org-babel-expand-body:chromium "<q>x</q>" '((:css . "t")))))
      (should (string-match-p "q { z: 3 }" doc))
      (should (string-match-p "<base href=\"file://" doc)))))

(provide 'ob-chromium-test)

;;; ob-chromium-test.el ends here
