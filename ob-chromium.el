;;; ob-chromium.el --- Render HTML and CSS to screenshots with headless Chromium  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 James Gornet

;; Author: James Gornet <gornetj@gmail.com>
;; Assisted-by: Claude Code:claude-fable-5-1
;; URL: https://github.com/jgornet/ob-chromium
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: org, babel, html, chromium, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Org-babel support for the `chromium' language.  A chromium source
;; block holds HTML.  Executing it assembles one HTML document from the
;; body and the CSS named in the :css header argument, renders the
;; document with headless Chromium, and inserts a link to the PNG.
;;
;; Supported header arguments:
;; :file       - Output file, .png or .pdf.  A named block can omit it.
;; :css        - Names of css source blocks or CSS file paths, inlined.
;; :width      - Window width in CSS pixels (default 1280).
;; :height     - Window height in CSS pixels (default 800).
;; :fit        - viewport (default) or content.
;; :scale      - Device scale factor (default 1).
;; :background - transparent, or a 6 or 8 digit hex colour.
;; :delay      - Virtual time budget in ms, for timer driven pages.
;; :timeout    - Capture timeout in ms (default `ob-chromium-timeout').
;; :cmdline    - Additional Chromium flags, verbatim.
;; :keep-html  - yes keeps the assembled document beside the output.
;; :document   - yes or no, overrides full document detection.
;; :selector   - CSS selector of one element to capture.
;;
;; Requirements: a Chromium family browser.  See `ob-chromium-executable'.

;;; Code:

(require 'ob)
(require 'ob-eval)
(require 'format-spec)
(require 'subr-x)
(require 'browse-url)
(require 'seq)
(require 'url-util)
(require 'json)

;;;; Customization

(defvar ob-chromium--executable-cache nil
  "The executable found by `ob-chromium--executable', for this session.")

(defcustom ob-chromium-executable nil
  "Path to the Chromium family browser.
When nil, the first entry of `ob-chromium-candidates' that resolves
is used."
  :group 'org-babel
  :type '(choice (const :tag "Search `ob-chromium-candidates'" nil)
                 (file :tag "Path to the browser"))
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq ob-chromium--executable-cache nil)))

(defcustom ob-chromium-candidates
  '("chromium" "chromium-browser" "google-chrome" "google-chrome-stable"
    "chrome" "chrome-headless-shell" "brave-browser" "microsoft-edge"
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
  "Browser names and absolute paths tried in order.
Used when `ob-chromium-executable' is nil.  A name is looked up on
the variable `exec-path'; an absolute path must be executable."
  :group 'org-babel
  :type '(repeat string))

(defcustom ob-chromium-extra-args nil
  "Flags added to every Chromium run, for example \"--no-sandbox\"."
  :group 'org-babel
  :type '(repeat string))

(defcustom ob-chromium-default-width 1280
  "Window width in CSS pixels when the block has no :width."
  :group 'org-babel
  :type 'integer)

(defcustom ob-chromium-default-height 800
  "Window height in CSS pixels when the block has no :height."
  :group 'org-babel
  :type 'integer)

(defcustom ob-chromium-timeout 30000
  "Milliseconds Chromium waits for the page before it captures it.
Passed as --timeout when the block has no :timeout."
  :group 'org-babel
  :type 'integer)

(defcustom ob-chromium-temporary-directory nil
  "Directory for the assembled document and the Chromium profile.
When nil, org's `org-babel-temporary-directory' is used.  A snap
installed Chromium cannot read /tmp, so set this to a directory
under your home directory that does not start with a period."
  :group 'org-babel
  :type '(choice (const :tag "Org's temporary directory" nil)
                 (directory :tag "Directory")))

(defcustom ob-chromium-template
  "<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<base href=\"%u\">
<style>
%c
</style>
</head>
<body>
%b
</body>
</html>"
  "Document wrapped around a fragment.
%u is the file URL of the org file's directory, %c the CSS and %b
the block body."
  :group 'org-babel
  :type 'string)

;;;; Document assembly

(defun ob-chromium--param (key params)
  "Return the header argument KEY from PARAMS as a string, or nil."
  (let ((value (cdr (assq key params))))
    (and value (format "%s" value))))

(defun ob-chromium--full-document-p (body)
  "Return non-nil for a BODY whose first tag is a doctype or <html>."
  (let ((case-fold-search t))
    (and (string-match-p "\\`[ \t\n\r]*<\\(!doctype\\|html\\)" body) t)))

(defun ob-chromium--named-block-body (name)
  "Return the body of the source block NAME in the current buffer.
Return nil when there is no such block."
  (save-excursion
    (save-restriction
      (widen)
      (let ((pos (org-babel-find-named-block name)))
        (when pos
          (goto-char pos)
          (nth 1 (org-babel-get-src-block-info 'light)))))))

(defun ob-chromium--css (params)
  "Return the CSS named by the :css header argument in PARAMS.
Each item is the name of a source block in the current buffer or a
file path relative to `default-directory'.  The bodies are joined
with newlines in the order given.  Return nil without :css."
  (let ((spec (ob-chromium--param :css params)))
    (when spec
      (mapconcat
       (lambda (item)
         (or (ob-chromium--named-block-body item)
             (let ((file (expand-file-name item)))
               (and (file-readable-p file)
                    (not (file-directory-p file))
                    (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
             (user-error "The :css item %S is neither a named source block nor a readable file"
                         item)))
       (split-string spec nil t)
       "\n"))))

(defun ob-chromium--file-url (path)
  "Return the file URL of PATH."
  (if (fboundp 'browse-url-file-url)
      (browse-url-file-url path)
    (concat "file://" (url-hexify-string (expand-file-name path)
                                         (cons ?/ url-unreserved-chars)))))

(defun ob-chromium--base-url ()
  "Return the file URL of `default-directory', with a trailing slash."
  (ob-chromium--file-url
   (file-name-as-directory (expand-file-name default-directory))))

(defun ob-chromium--assemble (body css base-url &optional document)
  "Return the HTML document for BODY with CSS and BASE-URL.
A fragment is wrapped in `ob-chromium-template'.  A full document
gets a <base> and a <style> element before </head>, or after the
<html> tag when there is no </head>.  DOCUMENT is the :document
header argument: \"yes\" treats BODY as a full document, \"no\"
as a fragment, and nil lets `ob-chromium--full-document-p' decide."
  (let ((css (or css ""))
        (case-fold-search t)
        (full (pcase document
                ("yes" t)
                ("no" nil)
                ((pred null) (ob-chromium--full-document-p body))
                (_ (user-error "The :document header argument must be yes or no, not %S"
                               document)))))
    (if (not full)
        (format-spec ob-chromium-template
                     `((?u . ,base-url) (?c . ,css) (?b . ,body)))
      (let ((head (format "<base href=\"%s\">\n<style>\n%s\n</style>" base-url css)))
        (cond ((string-match "</head>" body)
               (replace-match (concat head "\n</head>") t t body))
              ((string-match "<html[^>]*>" body)
               (replace-match (concat (match-string 0 body) "\n" head) t t body))
              (t (concat head "\n" body)))))))

(defun org-babel-expand-body:chromium (body params)
  "Return the document rendered for BODY with PARAMS.
This is what `org-babel-expand-src-block' shows."
  (ob-chromium--assemble body (ob-chromium--css params) (ob-chromium--base-url)
                         (ob-chromium--param :document params)))

;;;; Chromium driver

(defun ob-chromium--executable ()
  "Return the path of the browser, or signal `user-error'.
`ob-chromium-executable' wins when it is set.  Otherwise the first
entry of `ob-chromium-candidates' that resolves is returned and
cached for the session."
  (cond
   (ob-chromium-executable
    (if (file-executable-p ob-chromium-executable)
        ob-chromium-executable
      (user-error "`ob-chromium-executable' is %s, which is not executable"
                  ob-chromium-executable)))
   ((and ob-chromium--executable-cache
         (file-executable-p ob-chromium--executable-cache))
    ob-chromium--executable-cache)
   (t
    (let ((found (seq-some (lambda (candidate)
                             (if (file-name-absolute-p candidate)
                                 (and (file-executable-p candidate) candidate)
                               (executable-find candidate)))
                           ob-chromium-candidates)))
      (unless found
        (user-error "No Chromium found on `exec-path' or in `ob-chromium-candidates'; set `ob-chromium-executable'"))
      (setq ob-chromium--executable-cache found)))))

(defun ob-chromium--run (args)
  "Run the command ARGS, a list of the program and its arguments.
Return (EXIT-CODE STDOUT STDERR).  EXIT-CODE is a number, or a
string when a signal ended the process."
  (let ((stderr-file (make-temp-file "ob-chromium-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let ((code (apply #'call-process (car args) nil
                             (list (current-buffer) stderr-file) nil
                             (cdr args))))
            (list code
                  (buffer-string)
                  (with-temp-buffer
                    (insert-file-contents stderr-file)
                    (buffer-string)))))
      (delete-file stderr-file))))

(defun ob-chromium--background (value)
  "Return the --default-background-color argument for VALUE.
VALUE is transparent, or a 6 or 8 digit hex colour with or without
a leading #."
  (let ((v (string-remove-prefix "#" (format "%s" value))))
    (cond ((string= v "transparent") "00000000")
          ((string-match-p "\\`[0-9a-fA-F]\\{6\\}\\'" v) (concat v "FF"))
          ((string-match-p "\\`[0-9a-fA-F]\\{8\\}\\'" v) v)
          (t (user-error "The :background header argument must be transparent or a 6 or 8 digit hex colour, not %S"
                         value)))))

(defun ob-chromium--output-file (params)
  "Return the absolute output file named by PARAMS.
Org has already derived :file from #+NAME and :file-ext and
prefixed :output-dir.  Only .png and .pdf are accepted."
  (let ((file (ob-chromium--param :file params)))
    (unless file
      (user-error "No :file header argument and no #+NAME to derive one from; did you forget to name the block?"))
    (unless (member (downcase (or (file-name-extension file) "")) '("png" "pdf"))
      (user-error "The :file header argument must end in .png or .pdf, not %S" file))
    (expand-file-name file)))

(defun ob-chromium--pdf-p (out)
  "Return non-nil when the output file OUT is a PDF."
  (string= (downcase (or (file-name-extension out) "")) "pdf"))

(defun ob-chromium--temp-directory ()
  "Return the directory for the document and the profile, created.
`ob-chromium-temporary-directory' when set, else org's temporary
directory, else the variable `temporary-file-directory'.  Org 9.3 to 9.5 leave
`org-babel-temporary-directory' unset in batch mode, and org 9.6
and later create it on demand in `org-babel-temp-directory'."
  (let ((dir (or ob-chromium-temporary-directory
                 (and (fboundp 'org-babel-temp-directory)
                      (org-babel-temp-directory))
                 (and (bound-and-true-p org-babel-temporary-directory)
                      (file-exists-p org-babel-temporary-directory)
                      org-babel-temporary-directory)
                 temporary-file-directory)))
    (make-directory dir t)
    (file-name-as-directory (expand-file-name dir))))

(defun ob-chromium--write-document (html file)
  "Write HTML to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file file (insert html))))

(defun ob-chromium--command (exe url profile width height mode out params)
  "Return the Chromium command line as a list of strings.
EXE is the browser, URL the document, PROFILE the --user-data-dir,
WIDTH and HEIGHT the window size in CSS pixels, MODE one of
`screenshot', `pdf' and `dump', OUT the output file and PARAMS the
header arguments."
  (let ((scale (ob-chromium--param :scale params))
        (background (ob-chromium--param :background params))
        (timeout (or (ob-chromium--param :timeout params) ob-chromium-timeout))
        (delay (ob-chromium--param :delay params))
        (cmdline (ob-chromium--param :cmdline params)))
    (append
     ;; --disable-infobars: without it the new headless mode reserves
     ;; room for an infobar inside the window, paints the page only
     ;; in the rest, and captures the whole window, so a window under
     ;; about 145 px tall is mostly blank.
     (list exe "--headless" "--disable-gpu" "--hide-scrollbars" "--disable-infobars"
           (concat "--user-data-dir=" profile)
           (format "--window-size=%s,%s" width height))
     (and scale (list (concat "--force-device-scale-factor=" scale)))
     (and background
          (list (concat "--default-background-color="
                        (ob-chromium--background background))))
     (list (format "--timeout=%s" timeout))
     (and delay (list (concat "--virtual-time-budget=" delay)))
     ob-chromium-extra-args
     (and cmdline (split-string-and-unquote cmdline))
     (pcase mode
       ('screenshot (list (concat "--screenshot=" out)))
       ('pdf (list (concat "--print-to-pdf=" out) "--no-pdf-header-footer"))
       ('dump (list "--dump-dom"))
       (_ (error "Unknown mode %S" mode)))
     (list url))))

(defun ob-chromium--check (result out)
  "Signal `user-error' unless RESULT is a clean exit that wrote OUT.
RESULT is what `ob-chromium--run' returned.  On failure the standard
error of Chromium goes to the Org-Babel error buffer first."
  (let ((code (nth 0 result))
        (stderr (nth 2 result)))
    (unless (and (eql code 0)
                 (file-exists-p out)
                 (> (file-attribute-size (file-attributes out)) 0))
      (org-babel-eval-error-notify (if (numberp code) code 1) stderr)
      (user-error "Chromium exited with %s and %s was not written; see *Org-Babel Error Output*"
                  code (file-name-nondirectory out)))))

(defconst ob-chromium--max-window 16384
  "Largest window side in CSS pixels the measured size is clamped to.")

(defun ob-chromium--json-string (string)
  "Return STRING as a JSON string literal, quotes and backslashes escaped."
  (if (and (fboundp 'json-serialize) (fboundp 'json-available-p) (json-available-p))
      (json-serialize string)
    (json-encode-string string)))

(defun ob-chromium--probe-script (&optional selector)
  "Return the script that records the measured size on the root element.
Without SELECTOR the size is the document's scrollWidth and
scrollHeight.  With SELECTOR, a CSS selector, the script keeps only
the first matching element under <body>, with no body margin, and
records the element's size.  When nothing matches it records
data-ob-chromium-error instead."
  (if selector
      (format "<script>
(function () {
  var d = document.documentElement;
  var el = document.querySelector(%s);
  if (!el) {
    d.setAttribute(\"data-ob-chromium-error\", \"no element matches\");
    return;
  }
  document.body.replaceChildren(el);
  document.body.style.margin = \"0\";
  addEventListener(\"load\", function () {
    var r = el.getBoundingClientRect();
    d.setAttribute(\"data-ob-chromium-size\",
                   Math.ceil(r.width) + \"x\" + Math.ceil(r.height));
  });
})();
</script>" (ob-chromium--json-string selector))
    "<script>
addEventListener(\"load\", function () {
  var d = document.documentElement;
  d.setAttribute(\"data-ob-chromium-size\",
                 d.scrollWidth + \"x\" + d.scrollHeight);
});
</script>"))

(defun ob-chromium--append-probe (html script)
  "Return HTML with SCRIPT before </body>, or at the end without </body>."
  (let ((case-fold-search t))
    (if (string-match "</body>" html)
        (replace-match (concat script "\n</body>") t t html)
      (concat html "\n" script))))

(defun ob-chromium--parse-size (dom)
  "Return (WIDTH . HEIGHT) from the probe attribute in the DOM dump, or nil."
  (when (string-match "data-ob-chromium-size=\"\\([0-9]+\\)x\\([0-9]+\\)\"" dom)
    (cons (min (string-to-number (match-string 1 dom)) ob-chromium--max-window)
          (min (string-to-number (match-string 2 dom)) ob-chromium--max-window))))

(defun ob-chromium--parse-error (dom)
  "Return the probe's error message from the DOM dump, or nil."
  (when (string-match "data-ob-chromium-error=\"\\([^\"]*\\)\"" dom)
    (match-string 1 dom)))

(defun ob-chromium--measure (exe url profile width height params)
  "Run the measurement pass and return the DOM dump as a string.
EXE, URL, PROFILE, WIDTH, HEIGHT and PARAMS are as for
`ob-chromium--command'.  The document at URL must carry the probe
script.  A failed run is a `user-error'."
  (let ((result (ob-chromium--run
                 (ob-chromium--command exe url profile width height 'dump nil params))))
    (unless (eql (nth 0 result) 0)
      (org-babel-eval-error-notify (if (numberp (nth 0 result)) (nth 0 result) 1)
                                   (nth 2 result))
      (user-error "The measurement run exited with %s; see *Org-Babel Error Output*"
                  (nth 0 result)))
    (nth 1 result)))

;;;; Babel entry points

(defvar org-babel-default-header-args:chromium
  '((:results . "file") (:exports . "results") (:file-ext . "png"))
  "Default header arguments for a chromium source block.")

(defconst org-babel-header-args:chromium
  '((css . :any)
    (width . :any)
    (height . :any)
    (fit . ((viewport content)))
    (scale . :any)
    (background . :any)
    (delay . :any)
    (timeout . :any)
    (cmdline . :any)
    (keep-html . ((yes no)))
    (document . ((yes no)))
    (selector . :any))
  "Header arguments specific to chromium source blocks.")

(add-to-list 'org-src-lang-modes '("chromium" . mhtml))

(defun org-babel-prep-session:chromium (_session _params)
  "Signal an error: chromium blocks have no sessions."
  (error "Sessions are not supported by ob-chromium"))

(defun org-babel-execute:chromium (body params)
  "Render BODY with the header arguments PARAMS to the :file.
Return nil: org inserts the link to :file because :results is file."
  (when (file-remote-p default-directory)
    (user-error "Remote files are not supported by ob-chromium"))
  (when (string-blank-p body)
    (user-error "The block body is empty"))
  (let* ((exe (ob-chromium--executable))
         (out (ob-chromium--output-file params))
         (pdf (ob-chromium--pdf-p out))
         (css (ob-chromium--css params))
         (width (or (ob-chromium--param :width params) ob-chromium-default-width))
         (height (or (ob-chromium--param :height params) ob-chromium-default-height))
         (fit (or (ob-chromium--param :fit params) "viewport"))
         (selector (ob-chromium--param :selector params))
         ;; A selector needs the measurement run whatever :fit says.
         ;; A PDF takes its page size from the document, so :fit
         ;; content has nothing to measure for it.
         (measure (or selector
                      (pcase fit
                        ("content" (not pdf))
                        ("viewport" nil)
                        (_ (user-error "The :fit header argument must be viewport or content, not %S" fit)))))
         (probe (and measure (ob-chromium--probe-script selector)))
         (html (ob-chromium--assemble body css (ob-chromium--base-url)
                                      (ob-chromium--param :document params)))
         (dir (ob-chromium--temp-directory))
         (hash (substring (sha1 html) 0 8))
         (doc-file (expand-file-name (format "ob-chromium-%s.html" hash) dir))
         (profile (expand-file-name (format "ob-chromium-profile-%s" hash) dir))
         (url (ob-chromium--file-url doc-file)))
    (unwind-protect
        (progn
          (make-directory profile t)
          (make-directory (file-name-directory out) t)
          (when (file-exists-p out) (delete-file out))
          (when measure
            (ob-chromium--write-document (ob-chromium--append-probe html probe) doc-file)
            (let* ((dom (ob-chromium--measure exe url profile width height params))
                   (size (ob-chromium--parse-size dom))
                   (problem (ob-chromium--parse-error dom)))
              (cond
               (problem
                (user-error "The :selector %S failed: %s" selector problem))
               ((and selector (not size))
                (user-error "The :selector %S gave no size in the measurement run"
                            selector))
               ((and selector size)
                (setq width (car size) height (cdr size)))
               ;; Without a selector the width stays :width.  The root
               ;; element's scrollWidth is never less than the window width.
               (size (setq height (cdr size))))))
          ;; With a selector the capture run isolates the element too.
          (ob-chromium--write-document
           (if selector (ob-chromium--append-probe html probe) html) doc-file)
          (ob-chromium--check
           (ob-chromium--run
            (ob-chromium--command exe url profile width height
                                  (if pdf 'pdf 'screenshot) out params))
           out)
          (when (equal (ob-chromium--param :keep-html params) "yes")
            (copy-file doc-file (concat (file-name-sans-extension out) ".html") t))
          nil)
      (ignore-errors (delete-file doc-file))
      (ignore-errors (delete-directory profile t)))))

(provide 'ob-chromium)

;;; ob-chromium.el ends here
