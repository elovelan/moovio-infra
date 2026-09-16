#!/usr/bin/env bash
# Behavior regression tests for go/lint-project.sh.
#
# Each cases/<name>.env file is a set of environment variables. The script is
# run once per case inside a throwaway Go project with stub go/wget/curl/tar
# binaries on PATH (see stubs/). The stubs record every external command the
# script executes, plus the generated golangci-lint config, into a log that is
# compared byte-for-byte against golden/<name>.log.
#
# Only the commands are compared. The script's own echo output is ignored, so
# changes to logging never fail these tests while any change to what actually
# runs (flags, ordering, skipped steps, exit code) does.
#
# Usage:
#   tests/lint-project/run.sh                  run every case
#   tests/lint-project/run.sh <name>...        run selected cases
#   UPDATE_GOLDEN=1 tests/lint-project/run.sh  rewrite golden files
#   LINT_SCRIPT=/path/to/lint-project.sh       test a different copy of the script
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script="${LINT_SCRIPT:-$repo/go/lint-project.sh}"

# Read a single STUB_* fixture knob from a case file (used to set up the
# fake project before the script runs).
case_var() {
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

run_case() {
    local name="$1"
    local envfile="$here/cases/$name.env"
    local golden="$here/golden/$name.log"
    if [[ ! -f "$envfile" ]]; then
        echo "FAIL $name: no such case file $envfile"
        return 1
    fi

    local work project
    work=$(mktemp -d)
    project="$work/project"
    mkdir -p "$project/pkg/a" "$project/cmd/b" "$work/tmp" "$work/gopath/bin" "$work/home"
    printf 'module example\n\ngo 1.24\n' > "$project/go.mod"
    printf 'package main\n' > "$project/main.go"
    printf 'package a\n' > "$project/pkg/a/a.go"
    printf 'package main\n' > "$project/cmd/b/main.go"

    if [[ -n "$(case_var "$envfile" STUB_SUBMODULE)" ]]; then
        mkdir -p "$project/sub"
        printf 'module example/sub\n' > "$project/sub/go.mod"
    fi
    if [[ -n "$(case_var "$envfile" STUB_GOLANGCI_YML)" ]]; then
        printf 'version: "2"\n' > "$project/.golangci.yml"
    fi
    if [[ -n "$(case_var "$envfile" STUB_GOVULNCHECK_WORKFLOW)" ]]; then
        mkdir -p "$project/.github/workflows"
        : > "$project/.github/workflows/govulncheck.yml"
    fi
    if [[ -n "$(case_var "$envfile" STUB_PREEXISTING_GOLANGCI)" ]]; then
        mkdir -p "$project/bin"
        cp "$here/stubs/_tool" "$project/bin/golangci-lint"
    fi

    local -a vars=()
    local line
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) ;;
            *) vars+=("$line") ;;
        esac
    done < "$envfile"

    local log="$work/commands.log"
    : > "$log"

    local status=0
    (
        cd "$project"
        env -i \
            PATH="$here/stubs:/usr/bin:/bin" \
            HOME="$work/home" \
            TMPDIR="$work/tmp" \
            LC_ALL=C \
            STUB_STUBS_DIR="$here/stubs" \
            STUB_PROJECT="$project" \
            STUB_GOPATH="$work/gopath" \
            STUB_LOG="$log" \
            ${vars[@]+"${vars[@]}"} \
            bash "$script"
    ) > "$work/output.txt" 2>&1 || status=$?
    echo "exit=$status" >> "$log"

    local actual="$work/actual.log"
    sed -e "s#$work/tmp/tmp\.[A-Za-z0-9]*#<TMPDIR>#g" \
        -e "s#$work#<WORK>#g" \
        -e "s#$here/stubs#<STUBS>#g" "$log" > "$actual"

    if [[ -n "${UPDATE_GOLDEN:-}" ]]; then
        cp "$actual" "$golden"
        echo "UPDATED $name"
        rm -rf "$work"
        return 0
    fi

    if [[ ! -f "$golden" ]]; then
        echo "FAIL $name: missing golden file $golden (run with UPDATE_GOLDEN=1 to create it)"
        echo "  script output: $work/output.txt"
        return 1
    fi
    if diff -u "$golden" "$actual"; then
        echo "PASS $name"
        rm -rf "$work"
        return 0
    fi
    echo "FAIL $name: command log differs from $golden"
    echo "  script output: $work/output.txt"
    return 1
}

if [[ $# -gt 0 ]]; then
    cases=("$@")
else
    cases=()
    for f in "$here"/cases/*.env; do
        cases+=("$(basename "${f%.env}")")
    done
fi

failed=0
for name in "${cases[@]}"; do
    run_case "$name" || failed=$((failed + 1))
done

if [[ $failed -gt 0 ]]; then
    echo "$failed of ${#cases[@]} lint-project cases failed"
    exit 1
fi
echo "all ${#cases[@]} lint-project cases passed"
