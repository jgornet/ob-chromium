#!/usr/bin/env bash
# Development checks for ob-chromium, after ob-mermaid's dev-test.sh.
#
#   ./dev-test.sh check        prerequisites: emacs and a browser
#   ./dev-test.sh clean        remove test-output/ and compiled files
#   ./dev-test.sh syntax       byte-compile with warnings as errors
#   ./dev-test.sh lint         checkdoc, and package-lint when it is installed
#   ./dev-test.sh unit         ERT tests (integration tests skip without a browser)
#   ./dev-test.sh batch        execute every chromium block of test-example.org
#   ./dev-test.sh interactive  open test-example.org in Emacs (default)
#   ./dev-test.sh all          syntax, lint, unit, batch
#
# OB_CHROMIUM_EXECUTABLE names the browser.  OB_CHROMIUM_EXTRA_ARGS adds
# Chromium flags, for example --no-sandbox in a container.
set -euo pipefail
cd "$(dirname "$0")"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*"; }

check_prerequisites() {
    command -v emacs >/dev/null || { fail "emacs not found"; exit 1; }
    ok "emacs: $(emacs --version | head -1)"
    local browser
    browser=$(emacs --batch -L . -l ob-chromium.el --eval \
        '(princ (condition-case nil
                    (let ((ob-chromium-executable (or (getenv "OB_CHROMIUM_EXECUTABLE")
                                                      ob-chromium-executable)))
                      (ob-chromium--executable))
                  (error "")))' 2>/dev/null || true)
    if [ -n "$browser" ]; then
        ok "browser: $browser"
    else
        warn "no Chromium found; integration tests will be skipped and batch will fail"
    fi
}

clean_outputs() {
    rm -rf test-output ./*.elc
    ok "cleaned"
}

validate_syntax() {
    emacs --batch --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile ob-chromium.el
    rm -f ob-chromium.elc
    ok "byte-compile passed"
}

run_lint() {
    local out
    out=$(emacs --batch --eval '(progn (setq vc-handled-backends nil)
                                       (require (quote checkdoc))
                                       (checkdoc-file "ob-chromium.el")
                                       (checkdoc-file "ob-chromium-test.el"))' 2>&1 | grep -v '^Warning (emacs): *$' || true)
    if [ -n "$out" ]; then
        echo "$out"; fail "checkdoc reported the lines above"; return 1
    fi
    ok "checkdoc passed"
    if emacs --batch --eval '(progn (require (quote package)) (package-initialize) (require (quote package-lint)))' >/dev/null 2>&1; then
        emacs --batch --eval '(progn (require (quote package)) (package-initialize))' \
            -f package-lint-batch-and-exit ob-chromium.el
        ok "package-lint passed"
    else
        warn "package-lint is not installed; skipped"
    fi
}

run_unit() {
    emacs --batch -L . -l ob-chromium-test.el -f ert-run-tests-batch-and-exit
}

run_batch() {
    rm -rf test-output
    emacs --batch -l test-init.el test-example.org --eval '
      (let ((n 0) (failed 0))
        (org-babel-map-src-blocks nil
          (when (string= lang "chromium")
            (setq n (1+ n))
            (condition-case err
                (org-babel-execute-src-block)
              (error (setq failed (1+ failed))
                     (message "[batch] block %d failed: %s" n (error-message-string err))))))
        (message "[batch] %d blocks, %d failed" n failed)
        (kill-emacs (if (zerop failed) 0 1)))' 2>&1 | grep -v '^Executing\|^Code block\|^Babel evaluation'
    local expected missing=0
    expected=$(grep -oE '^#\+begin_src chromium.* :file [^ ]+|^#\+NAME: test-[^ ]+' test-example.org \
        | sed -E 's/^.* :file //; s/^#\+NAME: (.*)$/\1.png/')
    for f in $expected; do
        if [ -s "test-output/$f" ]; then
            ok "test-output/$f ($(wc -c < "test-output/$f") bytes)"
        else
            fail "missing test-output/$f"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 1
    ok "batch passed"
}

run_interactive() {
    emacs -Q -l test-init.el test-example.org
}

case "${1:-interactive}" in
    check)       check_prerequisites ;;
    clean)       clean_outputs ;;
    syntax)      validate_syntax ;;
    lint)        run_lint ;;
    unit)        run_unit ;;
    batch)       check_prerequisites; run_batch ;;
    interactive) check_prerequisites; run_interactive ;;
    all)         check_prerequisites; validate_syntax; run_lint; run_unit; run_batch ;;
    *)           sed -n '2,15p' "$0"; exit 1 ;;
esac
