;;; ob-chromium.el --- Org-babel support for rendering HTML and CSS with headless Chromium  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 James Gornet

;; Author: James Gornet <gornetj@gmail.com>
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
  "Browser names and absolute paths tried in order when
`ob-chromium-executable' is nil.  A name is looked up on `exec-path'."
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
  "Return non-nil when BODY starts with a doctype or an <html> tag."
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
             (user-error "ob-chromium: :css item %S is neither a named source block nor a readable file"
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
                (_ (user-error "ob-chromium: :document must be yes or no, not %S"
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
      (user-error "ob-chromium: `ob-chromium-executable' is %s, which is not executable"
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
        (user-error "ob-chromium: no Chromium found on `exec-path' or in `ob-chromium-candidates'; set `ob-chromium-executable'"))
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
  (error "ob-chromium does not support sessions"))

(provide 'ob-chromium)

;;; ob-chromium.el ends here
