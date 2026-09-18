#!/usr/bin/env bash
# Behavior tests for go/lint-project.sh.
#
# Each test_* function runs the script inside a throwaway Go project with stub
# go/wget/curl/tar binaries on PATH. The stubs record every external command
# the script executes (and copy the generated golangci-lint config aside) so
# tests can assert on what actually ran, independent of the script's own
# echo output.
#
# A test reads top to bottom as fixture setup, one run_lint call with the
# environment variables under test on its command line, then assertions:
#
#   test_example() {
#       with_submodule
#       given_module github.com/moovfinancial/thing
#       run_lint SKIP_TESTS=yes GOTAGS=integration
#       assert_exit 0
#       assert_ran "go build -race -tags integration ./..."
#       assert_not_ran "gitleaks"
#   }
#
# Usage:
#   tests/lint-project_test.sh                    run every test
#   tests/lint-project_test.sh <name>...          run selected tests
#   LINT_SCRIPT=/path/to/lint-project.sh ...      test a different copy
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="${LINT_SCRIPT:-$here/../go/lint-project.sh}"

# Linter lists the script enables by default, for use in assertions.
default_linters="asciicheck,bidichk,bodyclose,durationcheck,exhaustive,fatcontext,forcetypeassert,gosec,misspell,nolintlint,protogetter,rowserrcheck,sqlclosecheck,testifylint,wastedassign"
strict_linters="dupword,exptostd,gocheckcompilerdirectives,iface,mirror,nilnesserr,sloglint,testableexamples,usetesting"
golangci_run="golangci-lint run --config=.golangci-lint-generated.yml"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_default_moov_io_project_runs_every_check() {
    with_submodule
    run_lint
    assert_exit 0
    assert_ran_in_order \
        "go list -m all" \
        "go list -m -u all" \
        "go build -race ./..." \
        "gitleaks detect --no-git --verbose" \
        "govulncheck -test ./..." \
        "$golangci_run" \
        "go test ./..."
    assert_ran "wget -q -O gitleaks.tar.gz https://github.com/zricethezav/gitleaks/releases/download/v8.17.0/gitleaks_8.17.0_linux_x64.tar.gz"
    assert_ran "go install golang.org/x/vuln/cmd/govulncheck@latest"
    assert_ran "go test ./... -race -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic -count 1"
    assert_ran_exactly "[sub] go test ./... -race"
    assert_not_ran "sqlvet"
    assert_not_ran "xmlencoderclose"
    assert_not_ran "nilaway"
    assert_file_absent gitleaks.tar.gz
    assert_file_absent .golangci-lint-generated.yml
}

test_default_golangci_config_for_moov_io() {
    run_lint SKIP_TESTS=yes
    assert_ran "curl -sSfL -o /dev/null -w %{url_effective} https://github.com/golangci/golangci-lint/releases/latest"
    assert_ran "wget -q -O ./bin/golangci-lint-2.5.0-linux-amd64.tar.gz https://github.com/golangci/golangci-lint/releases/download/v2.5.0/golangci-lint-2.5.0-linux-amd64.tar.gz"
    assert_ran "wget -q -O ./bin/golangci-lint-checksums.txt https://github.com/golangci/golangci-lint/releases/download/v2.5.0/golangci-lint-2.5.0-checksums.txt"
    assert_ran "tar -xzf ./bin/golangci-lint-2.5.0-linux-amd64.tar.gz -C ./bin --strip-components=1 golangci-lint-2.5.0-linux-amd64/golangci-lint"
    assert_ran_exactly "$golangci_run --enable=$default_linters,$strict_linters,forbidigo --disable=depguard,errcheck --verbose --timeout=5m"
    assert_config_contains 'go: "1.24.1"'
    assert_config_contains '- pattern: ^fmt\.Print.*$'
    assert_config_contains "- pkg/test/fixtures"
    assert_config_not_contains "moovfinancial"
}

test_only_golangci_skips_everything_else() {
    run_lint ONLY_GOLANGCI=yes GOLANGCI_DO_FIX=true
    assert_exit 0
    assert_ran "$golangci_run --fix --enable="
    assert_not_ran "go list -m"
    assert_not_ran "go build"
    assert_not_ran "gitleaks"
    assert_not_ran "govulncheck"
    assert_not_ran "go test"
}

test_skip_linters_still_runs_tests_and_coverage() {
    with_submodule
    run_lint SKIP_LINTERS=yes COVER_THRESHOLD=85.0 SKIP_SUBMODULE_TESTS=yes
    assert_exit 0
    assert_ran "go list -m -u all"
    assert_ran "go test ./... -race -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic -count 1"
    assert_ran "go tool cover -func=coverage.txt"
    assert_not_ran "go build"
    assert_not_ran "gitleaks"
    assert_not_ran "govulncheck"
    assert_not_ran "golangci-lint"
    assert_not_ran "[sub]"
}

test_moovfinancial_module_defaults() {
    given_module github.com/moovfinancial/thing
    run_lint SKIP_TESTS=yes
    assert_exit 0
    assert_not_ran "go list -m all"
    assert_not_ran "gitleaks"
    assert_ran "$golangci_run --enable=$default_linters,forbidigo --disable=depguard,errcheck"
    assert_config_contains "pkg: github.com/moovfinancial/go-libs/mvalidation"
    assert_config_contains "pkg: github.com/go-ozzo/ozzo-validation/v4/is"
}

test_moovfinancial_dependency_in_oss_module_fails() {
    given_dependency github.com/moovfinancial/private
    run_lint
    assert_exit 1
    assert_ran "go list -m all"
    assert_not_ran "go build"
}

test_retracted_module_in_use_fails() {
    given_retracted github.com/unused/x github.com/moby/sys/user github.com/foo/bar
    given_unused github.com/unused/x
    run_lint
    assert_exit 1
    assert_ran "go mod why github.com/unused/x"
    assert_ran "go mod why github.com/moby/sys/user"
    assert_ran "go list -m -u -json github.com/foo/bar"
    assert_not_ran "go build"
}

test_retracted_modules_unused_or_in_skip_list_are_ignored() {
    given_retracted github.com/unused/x github.com/moby/sys/user
    given_unused github.com/unused/x
    run_lint SKIP_TESTS=yes
    assert_exit 0
    assert_not_ran "go list -m -u -json"
    assert_ran "go build -race ./..."
}

test_skip_retracted_skips_the_lookup() {
    given_retracted github.com/foo/bar
    run_lint SKIP_RETRACTED=yes SKIP_TESTS=yes
    assert_exit 0
    assert_not_ran "go list -m -u all"
    assert_ran "go build -race ./..."
}

test_build_tags_and_build_flags() {
    run_lint GOTAGS=integration GOBUILD_FLAGS=-v SKIP_TESTS=yes
    assert_ran_exactly "go build -race -tags integration -v ./..."
    assert_ran "$golangci_run --enable=" "--timeout=5m --build-tags integration"
}

test_pinned_golangci_version_skips_latest_lookup() {
    run_lint GOLANGCI_LINT_VERSION=v2.5.0 SKIP_TESTS=yes
    assert_not_ran "curl"
    assert_ran "wget -q -O ./bin/golangci-lint-2.5.0-linux-amd64.tar.gz"
}

test_golangci_linter_and_exclusion_options() {
    run_lint SKIP_TESTS=yes \
        GOLANGCI_LINTERS=lll \
        DISABLED_GOLANGCI_LINTERS=lll \
        STRICT_GOLANGCI_LINTERS=no \
        SKIP_FORBIDIGO=yes \
        GOLANGCI_ALLOW_PRINT=yes \
        GOLANGCI_FLAGS=--color=never \
        GOLANGCI_SKIP_DIR=./not-exist/ \
        GOLANGCI_SKIP_FILES=not_found.go
    assert_ran_exactly "golangci-lint --color=never run --config=.golangci-lint-generated.yml --enable=$default_linters,lll --disable=depguard,errcheck,lll --verbose --timeout=5m"
    assert_config_not_contains 'pattern: ^fmt\.Print'
    assert_config_contains "- ./not-exist/"
    assert_config_contains "- not_found.go"
}

test_set_golangci_linters_replaces_defaults() {
    run_lint SET_GOLANGCI_LINTERS=govet,errcheck GOLANGCI_LINTERS=lll SKIP_TESTS=yes
    assert_ran "$golangci_run --enable=govet,errcheck,$strict_linters,forbidigo --disable="
}

test_committed_golangci_yml_is_used_as_is() {
    with_file .golangci.yml 'version: "2"'
    run_lint SKIP_TESTS=yes
    assert_ran_exactly "golangci-lint run --verbose --timeout=5m"
    assert_not_ran "--config="
    assert_no_generated_config
}

test_reuses_matching_prebuilt_golangci_binary() {
    with_prebuilt_golangci v2.5.0-custom-gcl-abc123
    run_lint GOLANGCI_LINT_VERSION=v2.5.0 SKIP_TESTS=yes
    assert_ran "golangci-lint version"
    assert_ran "$golangci_run"
    assert_not_ran "curl"
    assert_not_ran "wget -q -O ./bin/golangci-lint"
}

test_downloads_when_prebuilt_golangci_version_differs() {
    with_prebuilt_golangci v2.4.0
    run_lint GOLANGCI_LINT_VERSION=v2.5.0 SKIP_TESTS=yes
    assert_ran "wget -q -O ./bin/golangci-lint-2.5.0-linux-amd64.tar.gz"
}

test_generated_config_is_removed_when_lint_fails() {
    given_failing_tool golangci-lint
    run_lint ONLY_GOLANGCI=yes
    assert_exit 3
    assert_ran "$golangci_run"
    assert_file_absent .golangci-lint-generated.yml
}

test_skip_golangci_disables_only_golangci() {
    run_lint SKIP_GOLANGCI=yes SKIP_TESTS=yes
    assert_exit 0
    assert_not_ran "golangci-lint"
    assert_ran "gitleaks detect"
    assert_ran "govulncheck -test ./..."
}

test_disable_flags_win_over_experimental() {
    run_lint SKIP_TESTS=yes \
        DISABLE_GITLEAKS=yes \
        DISABLE_GOVULNCHECK=yes \
        DISABLE_XMLENCODERCLOSE=yes \
        EXPERIMENTAL=xmlencoderclose
    assert_exit 0
    assert_not_ran "gitleaks"
    assert_not_ran "govulncheck"
    assert_not_ran "xmlencoderclose"
    assert_ran "$golangci_run"
}

test_dedicated_govulncheck_workflow_skips_scan() {
    with_file .github/workflows/govulncheck.yml ""
    run_lint SKIP_TESTS=yes
    assert_not_ran "govulncheck"
    assert_ran "gitleaks detect"
}

test_experimental_gitleaks_exclude_scans_directories_individually() {
    run_lint EXPERIMENTAL=gitleaks GITLEAKS_EXCLUDE=cmd SKIP_TESTS=yes
    assert_ran "gitleaks detect --no-git --verbose --no-banner --source ./pkg"
    assert_ran "gitleaks detect --no-git --verbose --no-banner --source ./pkg/a"
    assert_not_ran "--source ./cmd"
    assert_not_ran_exactly "gitleaks detect --no-git --verbose"
}

test_experimental_sqlvet() {
    run_lint EXPERIMENTAL=sqlvet SKIP_TESTS=yes
    assert_ran "wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/v1.1.5/sqlvet-v1.1.5-linux-amd64.tar.gz"
    assert_ran_exactly "sqlvet ."
    assert_file_absent sqlvet.tar.gz
}

test_experimental_xmlencoderclose() {
    run_lint EXPERIMENTAL=xmlencoderclose SKIP_TESTS=yes
    assert_ran "go install github.com/adamdecaf/xmlencoderclose@latest"
    assert_ran_exactly "xmlencoderclose -test ./..."
}

test_experimental_nilaway_with_options() {
    run_lint EXPERIMENTAL=nilaway NILAWAY_PACKAGES=./pkg/... NILAWAY_MEMORY_LIMIT=1GiB SKIP_TESTS=yes
    assert_ran "go install go.uber.org/nilaway/cmd/nilaway@latest"
    assert_ran_exactly "GOMEMLIMIT=1GiB nilaway -test=false ./pkg/..."
}

test_installed_tools_run_from_gopath_bin_when_gobin_unset() {
    given_tools_log_full_path
    run_lint EXPERIMENTAL=xmlencoderclose SKIP_TESTS=yes
    assert_ran_exactly "go env GOBIN"
    assert_ran_exactly "go env GOPATH"
    assert_ran_exactly "<WORK>/home/go/bin/govulncheck -test ./..."
    assert_ran_exactly "<WORK>/home/go/bin/xmlencoderclose -test ./..."
}

test_installed_tools_run_from_gobin_when_set() {
    given_tools_log_full_path
    run_lint GOBIN="$work/gobin" EXPERIMENTAL=nilaway SKIP_TESTS=yes
    assert_ran_exactly "<WORK>/gobin/govulncheck -test ./..."
    assert_ran_exactly "GOMEMLIMIT=7168MiB <WORK>/gobin/nilaway -test=false ./..."
    assert_not_ran "go env GOPATH"
}

test_installed_tools_fall_back_to_path() {
    given_go_install_writes_nowhere
    given_tools_log_full_path
    with_tool_on_path nilaway
    run_lint EXPERIMENTAL=nilaway SKIP_TESTS=yes
    assert_ran_exactly "GOMEMLIMIT=7168MiB <WORK>/path/nilaway -test=false ./..."
}

test_missing_installed_tool_is_skipped_not_fatal() {
    given_go_install_writes_nowhere
    run_lint EXPERIMENTAL=xmlencoderclose SKIP_TESTS=yes
    assert_exit 0
    assert_ran "go install golang.org/x/vuln/cmd/govulncheck@latest"
    assert_ran "go install github.com/adamdecaf/xmlencoderclose@latest"
    assert_not_ran "govulncheck -test"
    assert_not_ran "xmlencoderclose -test"
    assert_ran "$golangci_run"
}

test_experimental_nilaway_defaults() {
    run_lint EXPERIMENTAL=nilaway SKIP_TESTS=yes
    assert_ran_exactly "GOMEMLIMIT=7168MiB nilaway -test=false ./..."
}

test_experimental_shuffle_and_parallel_test_flags() {
    run_lint EXPERIMENTAL=shuffle,parallel GOTEST_PARALLEL=4 SKIP_LINTERS=yes
    assert_ran_exactly "go test ./... -race -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic -count 1 -test.shuffle=on -parallel=4"
}

test_explicit_gotest_flags_replace_experimental_defaults() {
    run_lint EXPERIMENTAL=shuffle GOTEST_FLAGS=-v SKIP_LINTERS=yes
    assert_ran_exactly "go test ./... -race -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic -count 1 -v"
    assert_not_ran "-test.shuffle=on"
}

test_profile_gotest_runs_each_package_with_profiles() {
    run_lint PROFILE_GOTEST=yes COVER_THRESHOLD=50.0 SKIP_LINTERS=yes
    assert_exit 0
    assert_ran_exactly "go test github.com/moov-io/example -race -covermode=atomic -coverprofile=./coverage.txt -test.cpuprofile=./cpu.out -test.memprofile=./mem.out -count 1"
    assert_ran_exactly "go test github.com/moov-io/example/pkg/a -race -covermode=atomic -coverprofile=pkg/a/coverage.txt -test.cpuprofile=pkg/a/cpu.out -test.memprofile=pkg/a/mem.out -count 1"
    assert_ran "go tool cover -func=pkg/a/coverage.txt"
    assert_ran "go tool cover -func=cmd/b/coverage.txt"
}

test_coverage_below_threshold_fails() {
    given_coverage 40.0
    run_lint COVER_THRESHOLD=50.0 SKIP_LINTERS=yes
    assert_exit 1
}

test_coverage_above_threshold_passes() {
    given_coverage 60.0
    run_lint COVER_THRESHOLD=50.0 SKIP_LINTERS=yes
    assert_exit 0
}

test_coverage_disabled_and_custom_packages() {
    run_lint COVER_THRESHOLD=disabled GOTEST_PKGS=./pkg/... GOTEST_FLAGS=-v SKIP_LINTERS=yes
    assert_exit 0
    assert_ran_exactly "go test ./pkg/... -race -count 1 -v"
    assert_not_ran "go tool cover"
}

test_vendor_for_tests_tidies_and_vendors_first() {
    run_lint VENDOR_FOR_TESTS=yes SKIP_LINTERS=yes
    assert_ran_in_order "go mod tidy" "go mod vendor" "go test"
}

test_disable_gorace_drops_race_flag() {
    run_lint DISABLE_GORACE=yes COVER_THRESHOLD=disabled SKIP_LINTERS=yes
    assert_ran_exactly "go test ./... '' -count 1"
}

test_cgo_disabled_drops_race_flag() {
    run_lint CGO_ENABLED=0 SKIP_LINTERS=yes
    assert_ran_exactly "go test ./... '' -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic -count 1"
}

test_windows_runs_short_tests_without_unsupported_tools() {
    run_lint TRAVIS_OS_NAME=windows EXPERIMENTAL=sqlvet
    assert_exit 0
    assert_ran_exactly "go test ./... -race -short -coverprofile=<TMPDIR>/coverage.txt -covermode=atomic"
    assert_ran "govulncheck -test ./..."
    assert_not_ran "gitleaks"
    assert_not_ran "sqlvet"
    assert_not_ran "golangci-lint"
}

# ---------------------------------------------------------------------------
# Fixture builders (call before run_lint)
# ---------------------------------------------------------------------------

# Module path reported by the stubbed 'go list .' (decides moov-io vs moovfinancial).
given_module() { stub_env+=("STUB_MODNAME=$1"); }

# Add a module to the stubbed 'go list -m all' output.
given_dependency() { stub_env+=("STUB_DEPENDENCY=$1"); }

# Modules reported as retracted by the stubbed 'go list -m -u all'.
given_retracted() { stub_env+=("STUB_RETRACTED=$*"); }

# Modules for which the stubbed 'go mod why' reports "module does not need package".
given_unused() { stub_env+=("STUB_UNUSED=$*"); }

# Total statement coverage reported by the stubbed 'go tool cover -func'.
given_coverage() { stub_env+=("STUB_COVERAGE=$1"); }

# Make the named linter binary exit 3 when invoked with a subcommand.
given_failing_tool() { stub_env+=("STUB_FAIL=$1"); }

# Make the stubbed 'go install' succeed without producing a binary anywhere
# the script looks.
given_go_install_writes_nowhere() { stub_env+=("STUB_INSTALL_NOWHERE=1"); }

# Log linter binaries by full path instead of name, to assert which copy ran.
given_tools_log_full_path() { stub_env+=("STUB_LOG_FULL_PATH=1"); }

# Put a copy of the named tool on PATH (outside the go install directory).
with_tool_on_path() {
    mkdir -p "$work/path"
    cp "$stubs/_tool" "$work/path/$1"
}

with_submodule() {
    mkdir -p "$project/sub"
    printf 'module example/sub\n' > "$project/sub/go.mod"
}

# with_file <relative path> <content>
with_file() {
    mkdir -p "$project/$(dirname "$1")"
    printf '%s\n' "$2" > "$project/$1"
}

# Pre-place a ./bin/golangci-lint that reports the given version string.
with_prebuilt_golangci() {
    mkdir -p "$project/bin"
    cp "$stubs/_tool" "$project/bin/golangci-lint"
    stub_env+=("STUB_TOOL_VERSION=$1")
}

# ---------------------------------------------------------------------------
# Running the script
# ---------------------------------------------------------------------------

# run_lint [VAR=value]... runs lint-project.sh with exactly the given
# environment (plus what the stubs need) and captures the command log.
run_lint() {
    (
        cd "$project" && env -i \
            PATH="$stubs:$work/path:/usr/bin:/bin" \
            HOME="$work/home" \
            TMPDIR="$work/tmp" \
            LC_ALL=C \
            STUB_DIR="$stubs" \
            STUB_PROJECT="$project" \
            STUB_LOG="$work/commands.log" \
            ${stub_env[@]+"${stub_env[@]}"} \
            "$@" \
            bash "$script"
    ) > "$work/output.txt" 2>&1
    exit_code=$?
    commands=$(sed -e "s#$work/tmp/tmp\.[A-Za-z0-9]*#<TMPDIR>#g" \
                   -e "s#$work#<WORK>#g" "$work/commands.log")
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

fail() {
    failures+=("$*")
}

assert_exit() {
    [[ "$exit_code" == "$1" ]] || fail "expected exit code $1, got $exit_code"
}

# A command line containing every given fragment ran.
assert_ran() {
    local matches="$commands" fragment
    for fragment in "$@"; do
        matches=$(grep -F -- "$fragment" <<< "$matches")
    done
    [[ -n "$matches" ]] || fail "expected a command containing: $*"
}

assert_not_ran() {
    ! grep -qF -- "$1" <<< "$commands" || fail "expected no command containing: $1"
}

assert_ran_exactly() {
    grep -qFx -- "$1" <<< "$commands" || fail "expected the command: $1"
}

assert_not_ran_exactly() {
    ! grep -qFx -- "$1" <<< "$commands" || fail "expected the command not to run: $1"
}

# Each fragment first appears on a later command than the previous one.
assert_ran_in_order() {
    local previous=0 line fragment
    for fragment in "$@"; do
        line=$(grep -nF -- "$fragment" <<< "$commands" | head -n 1 | cut -d: -f1)
        if [[ -z "$line" ]]; then
            fail "expected a command containing: $fragment"
            return
        fi
        if (( line <= previous )); then
            fail "expected '$fragment' to run after the previous command in: $*"
            return
        fi
        previous=$line
    done
}

assert_config_contains() {
    [[ -f "$work/golangci-config.yml" ]] || { fail "expected a generated golangci-lint config"; return; }
    grep -qF -- "$1" "$work/golangci-config.yml" || fail "expected generated golangci config to contain: $1"
}

assert_config_not_contains() {
    [[ -f "$work/golangci-config.yml" ]] || { fail "expected a generated golangci-lint config"; return; }
    ! grep -qF -- "$1" "$work/golangci-config.yml" || fail "expected generated golangci config not to contain: $1"
}

assert_no_generated_config() {
    [[ ! -f "$work/golangci-config.yml" ]] || fail "expected no generated golangci-lint config"
}

assert_file_absent() {
    [[ ! -e "$project/$1" ]] || fail "expected $1 not to be left in the project"
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

write_stubs() {
    mkdir -p "$stubs"

    cat > "$stubs/lib.sh" <<'EOF'
# Record an invocation: "[relative cwd] name args", quoting only empty or
# whitespace-containing arguments.
stub_log() {
    local rel="${PWD#"$STUB_PROJECT"}" line="" arg
    rel="${rel#/}"
    if [[ -n "$rel" ]]; then line="[$rel] "; fi
    line+="$1"
    shift
    for arg in "$@"; do
        if [[ -z "$arg" ]]; then
            line+=" ''"
        elif [[ "$arg" == *[[:space:]]* ]]; then
            line+=" '$arg'"
        else
            line+=" $arg"
        fi
    done
    echo "$line" >> "$STUB_LOG"
}
EOF

    cat > "$stubs/go" <<'EOF'
#!/usr/bin/env bash
. "$STUB_DIR/lib.sh"
stub_log go "$@"
mod="${STUB_MODNAME:-github.com/moov-io/example}"
case "$*" in
    "version") echo "go version go1.24.1 linux/amd64" ;;
    "list .") echo "$mod" ;;
    "list ./...") printf '%s\n' "$mod" "$mod/pkg/a" "$mod/cmd/b" ;;
    "mod why") printf '# %s\n%s\n' "$mod" "$mod" ;;
    "mod why "*)
        echo "# $3"
        if [[ " ${STUB_UNUSED:-} " == *" $3 "* ]]; then
            echo "(main module does not need package $3)"
        else
            printf '%s\n%s\n' "$mod" "$3"
        fi
        ;;
    "list -m all")
        printf '%s\n%s\n' "$mod" "github.com/moov-io/base v0.50.0"
        if [[ -n "${STUB_DEPENDENCY:-}" ]]; then echo "$STUB_DEPENDENCY v1.0.0"; fi
        ;;
    "list -m -u all")
        printf '%s\n%s\n' "$mod" "github.com/moov-io/base v0.50.0"
        for dep in ${STUB_RETRACTED:-}; do echo "$dep v0.1.0 (retracted) [v0.2.0]"; done
        ;;
    "list -m -u -json "*) printf '{"Path": "%s"}\n' "$5" ;;
    "env GOBIN") echo "${GOBIN:-}" ;;
    "env GOPATH") echo "${GOPATH:-$HOME/go}" ;;
    "install "*)
        # Place the tool where the real 'go install' would, unless the test
        # simulates an install that lands somewhere the script does not look.
        if [[ -z "${STUB_INSTALL_NOWHERE:-}" ]]; then
            dir="${GOBIN:-${GOPATH:-$HOME/go}/bin}"
            tool="${2%@*}"
            mkdir -p "$dir"
            cp "$STUB_DIR/_tool" "$dir/${tool##*/}"
            chmod +x "$dir/${tool##*/}"
        fi
        ;;
    "tool cover -func="*) printf 'a.go:1:\tFoo\t100.0%%\ntotal:\t(statements)\t%s%%\n' "${STUB_COVERAGE:-87.5}" ;;
    "test "*)
        for arg in "$@"; do
            case "$arg" in
                -coverprofile=*)
                    mkdir -p "$(dirname "${arg#-coverprofile=}")"
                    printf 'mode: atomic\n%s/a.go:1.1,2.2 1 1\n' "$mod" > "${arg#-coverprofile=}"
                    ;;
            esac
        done
        ;;
    "build "*|"mod tidy"|"mod vendor") ;;
    *) echo "go stub: unhandled invocation: go $*" >&2; exit 1 ;;
esac
exit 0
EOF

    cat > "$stubs/wget" <<'EOF'
#!/usr/bin/env bash
# Creates an empty file at -O. For a golangci-lint checksums file, writes real
# checksums of the (empty) tarballs already downloaded next to it.
. "$STUB_DIR/lib.sh"
stub_log wget "$@"
out=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -O ]]; then out="$2"; shift; fi
    shift
done
[[ -n "$out" ]] || exit 0
: > "$out"
if [[ "$out" == *checksums.txt ]]; then
    for tgz in "$(dirname "$out")"/*.tar.gz; do
        [[ -f "$tgz" ]] || continue
        if command -v sha256sum > /dev/null 2>&1; then
            sum=$(sha256sum "$tgz" | cut -d' ' -f1)
        else
            sum=$(shasum -a 256 "$tgz" | cut -d' ' -f1)
        fi
        echo "$sum  $(basename "$tgz")" >> "$out"
    done
fi
exit 0
EOF

    cat > "$stubs/tar" <<'EOF'
#!/usr/bin/env bash
# "Extracts" each requested member by placing a copy of _tool at the destination.
. "$STUB_DIR/lib.sh"
stub_log tar "$@"
dest="."
shift # mode (xf, -xzf, ...)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -C) dest="$2"; shift ;;
        -*|*.tar.gz) ;;
        *) cp "$STUB_DIR/_tool" "$dest/$(basename "$1")"; chmod +x "$dest/$(basename "$1")" ;;
    esac
    shift
done
exit 0
EOF

    cat > "$stubs/curl" <<'EOF'
#!/usr/bin/env bash
# Answers the golangci-lint "latest release" redirect lookup.
. "$STUB_DIR/lib.sh"
stub_log curl "$@"
printf 'https://github.com/golangci/golangci-lint/releases/tag/v2.5.0'
EOF

    cat > "$stubs/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -m) echo "x86_64" ;; *) echo "Linux" ;; esac
EOF

    # Generic linter binary (gitleaks, sqlvet, golangci-lint, govulncheck,
    # nilaway, xmlencoderclose). Logs under the name it was invoked as (or its
    # full path when STUB_LOG_FULL_PATH is set), copies any --config file aside
    # for assertions, and answers version queries.
    cat > "$stubs/_tool" <<'EOF'
#!/usr/bin/env bash
. "$STUB_DIR/lib.sh"
name=$(basename "$0")
if [[ -n "${STUB_LOG_FULL_PATH:-}" ]]; then name="$0"; fi
if [[ -n "${GOMEMLIMIT:-}" ]]; then
    stub_log "GOMEMLIMIT=$GOMEMLIMIT" "$name" "$@"
else
    stub_log "$name" "$@"
fi
for arg in "$@"; do
    case "$arg" in
        --config=*) cp "${arg#--config=}" "$(dirname "$STUB_LOG")/golangci-config.yml" ;;
        version|--version) echo "$name has version ${STUB_TOOL_VERSION:-2.5.0} built with go1.24.1"; exit 0 ;;
    esac
done
if [[ "${STUB_FAIL:-}" == "$name" ]]; then
    echo "$name: simulated failure" >&2
    exit 3
fi
exit 0
EOF

    chmod +x "$stubs"/go "$stubs"/wget "$stubs"/tar "$stubs"/curl "$stubs"/uname "$stubs"/_tool
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

set_up() {
    work=$(mktemp -d)
    project="$work/project"
    mkdir -p "$project/pkg/a" "$project/cmd/b" "$work/tmp" "$work/home"
    printf 'module example\n\ngo 1.24\n' > "$project/go.mod"
    printf 'package main\n' > "$project/main.go"
    printf 'package a\n' > "$project/pkg/a/a.go"
    printf 'package main\n' > "$project/cmd/b/main.go"
    : > "$work/commands.log"
    stub_env=()
    failures=()
    exit_code=""
    commands=""
}

# Runs one test in a subshell so fixture state and failures stay isolated.
run_test() {
    (
        set_up
        "$1"
        if [[ ${#failures[@]} -eq 0 ]]; then
            rm -rf "$work"
            echo "PASS $1"
            exit 0
        fi
        echo "FAIL $1"
        printf '    %s\n' "${failures[@]}"
        echo "    commands run:"
        while IFS= read -r line; do echo "      $line"; done <<< "$commands"
        echo "    script output: $work/output.txt"
        exit 1
    )
}

main() {
    stubs=$(mktemp -d)/stubs
    write_stubs
    trap 'rm -rf "$(dirname "$stubs")"' EXIT

    local -a tests=()
    if [[ $# -gt 0 ]]; then
        tests=("$@")
    else
        while IFS= read -r name; do
            tests+=("$name")
        done < <(grep -oE '^test_[a-z0-9_]+' "$0")
    fi

    local failed_tests=0 name
    for name in "${tests[@]}"; do
        run_test "$name" || failed_tests=$((failed_tests + 1))
    done

    if [[ $failed_tests -gt 0 ]]; then
        echo "$failed_tests of ${#tests[@]} lint-project tests failed"
        exit 1
    fi
    echo "all ${#tests[@]} lint-project tests passed"
}

main "$@"
