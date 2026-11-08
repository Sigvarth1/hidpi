#!/bin/sh
set -eu
binary="${1:-build/hidpi}"
"$binary" --help >/dev/null
"$binary" --version | /usr/bin/grep -q '2.1'
"$binary" status >/dev/null
"$binary" list >/dev/null
"$binary" profile list >/dev/null
"$binary" clean --dry-run >/dev/null
expect_failure() {
    if "$binary" "$@" >/dev/null 2>&1; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
}
expect_failure set all 1920x1080 --hz nan
expect_failure set all 1920x1080 --hz inf
expect_failure set all 1920x1080 --hz -1
expect_failure set all 1920x1080 --hz
expect_failure set all 1920x1080 --hz --yes
expect_failure set all -1920x1080
expect_failure set all 1920xx1080
expect_failure list --surprise
expect_failure status extra
expect_failure clean --undo file --include-foreign
expect_failure enable all
# The printed "W × H" form must parse; an unknown monitor keeps this from changing any display.
if ! "$binary" set hidpi-smoke-no-such-display "1920 × 1080" 2>&1 | /usr/bin/grep -q 'no display'; then
    echo "Expected the × size form to parse" >&2
    exit 1
fi
printf 'Passed CLI smoke tests (read-only commands and rejected arguments).\n'
