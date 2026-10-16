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
