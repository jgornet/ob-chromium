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
(require 'cl-lib)
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

(ert-deftest ob-chromium-test-assemble-document-override ()
  ":document yes and no override the detection."
  (let ((wrapped (ob-chromium--assemble "<html><body>b</body></html>" "" "file:///d/" "no"))
        (kept (ob-chromium--assemble "<div>x</div>" "" "file:///d/" "yes")))
    (should (string-prefix-p "<!DOCTYPE html>" wrapped))
    (should (string-match-p "<body>\n<html><body>b</body></html>\n</body>" wrapped))
    (should (string-prefix-p "<base href=\"file:///d/\">" kept))
    (should-not (string-match-p "<!DOCTYPE" kept))))

(ert-deftest ob-chromium-test-assemble-document-bad ()
  "A :document value other than yes or no is a `user-error'."
  (should-error (ob-chromium--assemble "<p>x</p>" "" "file:///d/" "maybe") :type 'user-error))

(ert-deftest ob-chromium-test-expand-body-document ()
  "`org-babel-expand-body:chromium' passes :document through."
  (ob-chromium-test--with-org ""
    (should (string-prefix-p "<base href="
                             (org-babel-expand-body:chromium "<p>x</p>" '((:document . "yes")))))
    (should (string-prefix-p "<!DOCTYPE html>"
                             (org-babel-expand-body:chromium "<html></html>" '((:document . "no")))))))

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

;;;; Command line and output file

(ert-deftest ob-chromium-test-background ()
  "transparent, 6 and 8 digit colours map to RRGGBBAA; others error."
  (should (equal (ob-chromium--background "transparent") "00000000"))
  (should (equal (ob-chromium--background "#ff0000") "ff0000FF"))
  (should (equal (ob-chromium--background "00ff0080") "00ff0080"))
  (should-error (ob-chromium--background "red") :type 'user-error))

(ert-deftest ob-chromium-test-output-file ()
  ":file is made absolute; .png and .pdf pass; others and none error."
  (let ((default-directory "/d/"))
    (should (equal (ob-chromium--output-file '((:file . "a.png"))) "/d/a.png"))
    (should (equal (ob-chromium--output-file '((:file . "sub/a.PDF"))) "/d/sub/a.PDF")))
  (should-error (ob-chromium--output-file '((:file . "a.jpg"))) :type 'user-error)
  (should-error (ob-chromium--output-file '((:file . "a"))) :type 'user-error)
  (should-error (ob-chromium--output-file '((:file-ext . "png"))) :type 'user-error))

(ert-deftest ob-chromium-test-command-defaults ()
  "The command carries the fixed flags, the window size and the timeout."
  (let* ((ob-chromium-extra-args nil)
         (ob-chromium-timeout 30000)
         (cmd (ob-chromium--command "/x/chromium" "file:///t/d.html" "/t/p"
                                    1280 800 'screenshot "/o/out.png" nil)))
    (should (equal (car cmd) "/x/chromium"))
    (should (member "--headless" cmd))
    (should (member "--disable-gpu" cmd))
    (should (member "--hide-scrollbars" cmd))
    (should (member "--disable-infobars" cmd))
    (should (member "--user-data-dir=/t/p" cmd))
    (should (member "--window-size=1280,800" cmd))
    (should (member "--timeout=30000" cmd))
    (should (member "--screenshot=/o/out.png" cmd))
    (should (equal (car (last cmd)) "file:///t/d.html"))
    (should-not (seq-some (lambda (a) (string-prefix-p "--force-device-scale-factor" a)) cmd))
    (should-not (seq-some (lambda (a) (string-prefix-p "--virtual-time-budget" a)) cmd))
    (should-not (seq-some (lambda (a) (string-prefix-p "--default-background-color" a)) cmd))))

(ert-deftest ob-chromium-test-command-header-args ()
  "Every header argument becomes its flag; extra args and :cmdline pass through."
  (let* ((ob-chromium-extra-args '("--no-sandbox"))
         (cmd (ob-chromium--command "c" "u" "p" 400 300 'screenshot "o.png"
                                    '((:scale . 2) (:background . "transparent")
                                      (:timeout . 5000) (:delay . 250)
                                      (:cmdline . "--lang=de \"--user-agent=a b\"")))))
    (should (member "--window-size=400,300" cmd))
    (should (member "--force-device-scale-factor=2" cmd))
    (should (member "--default-background-color=00000000" cmd))
    (should (member "--timeout=5000" cmd))
    (should (member "--virtual-time-budget=250" cmd))
    (should (member "--no-sandbox" cmd))
    (should (member "--lang=de" cmd))
    (should (member "--user-agent=a b" cmd))))

(ert-deftest ob-chromium-test-command-modes ()
  "pdf adds --print-to-pdf and --no-pdf-header-footer, dump adds --dump-dom."
  (let ((pdf (ob-chromium--command "c" "u" "p" 1 1 'pdf "o.pdf" nil))
        (dump (ob-chromium--command "c" "u" "p" 1 1 'dump nil nil)))
    (should (member "--print-to-pdf=o.pdf" pdf))
    (should (member "--no-pdf-header-footer" pdf))
    (should (member "--dump-dom" dump))
    (should-not (seq-some (lambda (a) (string-prefix-p "--screenshot" a)) dump))))

(ert-deftest ob-chromium-test-check ()
  "A non-zero exit or a missing or empty output file is a `user-error'."
  (let ((out (make-temp-file "ob-chromium-test-out")))
    (unwind-protect
        (progn
          (should-error (ob-chromium--check (list 1 "" "boom") out) :type 'user-error)
          (should-error (ob-chromium--check (list 0 "" "") out) :type 'user-error)
          (with-temp-file out (insert "x"))
          (should-not (ob-chromium--check (list 0 "" "warning noise") out))
          (should-error (ob-chromium--check (list 0 "" "") "/nonexistent/x.png") :type 'user-error))
      (delete-file out))))

;;;; Integration: these run only when a browser is found

(defun ob-chromium-test--browser ()
  "Return the browser path, or nil."
  (ignore-errors
    (let ((ob-chromium--executable-cache nil))
      (ob-chromium--executable))))

(defun ob-chromium-test--extra-args ()
  "Return `ob-chromium-extra-args' plus OB_CHROMIUM_EXTRA_ARGS."
  (append ob-chromium-extra-args
          (split-string (or (getenv "OB_CHROMIUM_EXTRA_ARGS") "") nil t)))

(defun ob-chromium-test--png-size (file)
  "Return (WIDTH . HEIGHT) from the IHDR chunk of the PNG FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 24)
    (let ((b (buffer-string)))
      (cl-flet ((be32 (i) (logior (ash (aref b i) 24) (ash (aref b (+ i 1)) 16)
                                  (ash (aref b (+ i 2)) 8) (aref b (+ i 3)))))
        (cons (be32 16) (be32 20))))))

(defun ob-chromium-test--png-colour-type (file)
  "Return the colour type byte of the PNG FILE: 2 is RGB, 6 is RGBA."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 26)
    (aref (buffer-string) 25)))

(defmacro ob-chromium-test--with-block (org-text &rest body)
  "Execute the first chromium block of ORG-TEXT in a fresh directory.
BODY runs afterwards in the org buffer with `dir' bound to that
directory and `temp' to the temporary directory the package used.
Skipped when no browser is found."
  (declare (indent 1))
  `(progn
     (unless (ob-chromium-test--browser) (ert-skip "no Chromium found"))
     (let* ((dir (make-temp-file "ob-chromium-test" t))
            (temp (make-temp-file "ob-chromium-test-tmp" t))
            (default-directory (file-name-as-directory dir))
            (ob-chromium-temporary-directory temp)
            (ob-chromium-extra-args (ob-chromium-test--extra-args))
            (org-confirm-babel-evaluate nil))
       (unwind-protect
           (ob-chromium-test--with-org ,org-text
             (re-search-forward "^#\\+begin_src chromium")
             (beginning-of-line)
             ,@body)
         (delete-directory dir t)
         (delete-directory temp t)))))

(ert-deftest ob-chromium-test-integration-viewport ()
  "A fragment renders to a PNG of the default window size and a link is inserted."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png\n<p>hello</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (should (equal (ob-chromium-test--png-size (expand-file-name "out.png" dir)) '(1280 . 800)))
    (should (string-match-p "#\\+RESULTS:\n\\[\\[file:out.png\\]\\]" (buffer-string)))
    (should-not (directory-files temp nil "ob-chromium"))))

(ert-deftest ob-chromium-test-integration-size-scale-background ()
  ":width, :height, :scale and :background transparent shape the PNG."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :width 100 :height 50 :scale 2 :background transparent\n<p>hello</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (let ((png (expand-file-name "out.png" dir)))
      (should (equal (ob-chromium-test--png-size png) '(200 . 100)))
      (should (= (ob-chromium-test--png-colour-type png) 6)))))

(ert-deftest ob-chromium-test-integration-small-window ()
  "A 300x100 window is painted in full.
Without --disable-infobars the new headless mode paints only the
top 13 px of such a window and the PNG is about 370 bytes.  A
painted one with text is well over 1000 bytes."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :width 300 :height 100\n<div style=\"margin:24px;padding:16px;background:#2d7a2d;color:#fff;font-size:24px\">painted</div>\n#+end_src\n"
    (org-babel-execute-src-block)
    (let ((png (expand-file-name "out.png" dir)))
      (should (equal (ob-chromium-test--png-size png) '(300 . 100)))
      (should (> (file-attribute-size (file-attributes png)) 1000)))))

(ert-deftest ob-chromium-test-integration-named-block-and-css ()
  "A named block needs no :file, and :css from a block is in the kept document."
  (ob-chromium-test--with-block "#+NAME: theme\n#+begin_src css\nbody { background: #123456 }\n#+end_src\n\n#+NAME: shot\n#+begin_src chromium :css theme :keep-html yes :width 50 :height 40\n<p>x</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (should (equal (ob-chromium-test--png-size (expand-file-name "shot.png" dir)) '(50 . 40)))
    (with-temp-buffer
      (insert-file-contents (expand-file-name "shot.html" dir))
      (should (string-match-p "background: #123456" (buffer-string))))
    (should (string-match-p "\\[\\[file:shot.png\\]\\]" (buffer-string)))))

(ert-deftest ob-chromium-test-integration-output-dir ()
  ":output-dir is created and prefixed to :file."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :output-dir img :width 10 :height 10\n<p>x</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (should (file-exists-p (expand-file-name "img/out.png" dir)))))

(ert-deftest ob-chromium-test-integration-failure ()
  "A browser that exits 1 gives a `user-error' and leaves no temporary files."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png\n<p>x</p>\n#+end_src\n"
    (let ((fake (expand-file-name "fake-browser" dir)))
      (with-temp-file fake (insert "#!/bin/sh\necho 'it broke' >&2\nexit 1\n"))
      (set-file-modes fake #o755)
      (let ((ob-chromium-executable fake))
        (should-error (org-babel-execute-src-block) :type 'user-error))
      (should-not (file-exists-p (expand-file-name "out.png" dir)))
      (should-not (directory-files temp nil "ob-chromium"))
      (with-current-buffer org-babel-error-buffer-name
        (should (string-match-p "it broke" (buffer-string)))))))

(ert-deftest ob-chromium-test-integration-empty-body ()
  "An empty body is a `user-error' before Chromium starts."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png\n\n#+end_src\n"
    (should-error (org-babel-execute-src-block) :type 'user-error)))

;;;; Measurement pass

(ert-deftest ob-chromium-test-probe-script ()
  "The probe script sets data-ob-chromium-size on load."
  (let ((script (ob-chromium--probe-script)))
    (should (string-prefix-p "<script>" script))
    (should (string-match-p "data-ob-chromium-size" script))
    (should (string-match-p "scrollHeight" script))))

(ert-deftest ob-chromium-test-append-probe ()
  "The probe goes before </body>, or at the end without one."
  (should (equal (ob-chromium--append-probe "<body>x</body>" "<s/>") "<body>x<s/>\n</body>"))
  (should (equal (ob-chromium--append-probe "<p>x</p>" "<s/>") "<p>x</p>\n<s/>")))

(ert-deftest ob-chromium-test-parse-size ()
  "The size is read from a DOM dump and clamped; a dump without it gives nil."
  (should (equal (ob-chromium--parse-size "<html data-ob-chromium-size=\"1265x2000\"><head>") '(1265 . 2000)))
  (should (equal (ob-chromium--parse-size "<html data-ob-chromium-size=\"100x99999\">") (cons 100 ob-chromium--max-window)))
  (should-not (ob-chromium--parse-size "<html><body></body></html>")))

(ert-deftest ob-chromium-test-integration-fit-content ()
  ":fit content makes the height follow the content and keeps the width."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :width 300 :height 100 :fit content\n<div style=\"height:1200px;margin:0\">tall</div>\n#+end_src\n"
    (org-babel-execute-src-block)
    (let ((size (ob-chromium-test--png-size (expand-file-name "out.png" dir))))
      (should (= (car size) 300))
      (should (>= (cdr size) 1200))
      (should (< (cdr size) 1300)))))

(ert-deftest ob-chromium-test-integration-fit-bad ()
  "A :fit value other than viewport or content is a `user-error'."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :fit page\n<p>x</p>\n#+end_src\n"
    (should-error (org-babel-execute-src-block) :type 'user-error)))

;;;; Element capture

(ert-deftest ob-chromium-test-probe-script-selector ()
  "With a selector the script isolates the element and escapes the selector."
  (let ((script (ob-chromium--probe-script "a[title=\"x\"] > .b")))
    (should (string-match-p "querySelector(\"a\\[title=\\\\\"x\\\\\"\\] > .b\")" script))
    (should (string-match-p "replaceChildren" script))
    (should (string-match-p "data-ob-chromium-error" script))
    (should (string-match-p "getBoundingClientRect" script))))

(ert-deftest ob-chromium-test-parse-error ()
  "The probe's error attribute is read from the DOM dump."
  (should (equal (ob-chromium--parse-error "<html data-ob-chromium-error=\"no element matches\">") "no element matches"))
  (should-not (ob-chromium--parse-error "<html data-ob-chromium-size=\"1x1\">")))

(ert-deftest ob-chromium-test-integration-selector ()
  ":selector captures one element at its own size, without :fit."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :selector .card\n<p>before</p>\n<div class=\"card\" style=\"width:300px;height:200px;background:#c00\">card</div>\n<p style=\"height:1500px\">after</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (should (equal (ob-chromium-test--png-size (expand-file-name "out.png" dir)) '(300 . 200)))))

(ert-deftest ob-chromium-test-integration-selector-missing ()
  "A selector that matches nothing is a `user-error' and writes no image."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.png :selector .nothing\n<p>x</p>\n#+end_src\n"
    (should-error (org-babel-execute-src-block) :type 'user-error)
    (should-not (file-exists-p (expand-file-name "out.png" dir)))))

;;;; PDF output

(ert-deftest ob-chromium-test-pdf-p ()
  "The extension picks PDF output, in any letter case."
  (should (ob-chromium--pdf-p "/a/b.pdf"))
  (should (ob-chromium--pdf-p "/a/b.PDF"))
  (should-not (ob-chromium--pdf-p "/a/b.png")))

(ert-deftest ob-chromium-test-integration-pdf ()
  "A .pdf :file gives a PDF document, also with :fit content."
  (ob-chromium-test--with-block "#+begin_src chromium :file out.pdf :fit content\n<h1>Title</h1><p>body</p>\n#+end_src\n"
    (org-babel-execute-src-block)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (expand-file-name "out.pdf" dir) nil 0 5)
      (should (equal (buffer-string) "%PDF-")))
    (should (string-match-p "\\[\\[file:out.pdf\\]\\]" (buffer-string)))))

(provide 'ob-chromium-test)

;;; ob-chromium-test.el ends here
