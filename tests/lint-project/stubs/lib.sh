# shellcheck shell=bash
# Shared helpers for the command stubs used by tests/lint-project/run.sh.
#
# Every stub records its invocation (working directory relative to the fake
# project, command name, and shell-quoted arguments) to $STUB_LOG so the test
# runner can compare the exact sequence of external commands lint-project.sh
# executes against a golden file.

stub_log() {
    local rel="${PWD#"${STUB_PROJECT:-}"}"
    local line="[${rel:-/}] $1"
    shift
    local arg
    for arg in "$@"; do
        line+=" $(printf '%q' "$arg")"
    done
    echo "$line" >> "$STUB_LOG"
}
