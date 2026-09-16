#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT_PROJECT="$SCRIPT_DIR/lint-project.sh"
REAL_GO=$(command -v go)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lint-project-test.XXXXXX")

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    file=$1
    expected=$2
    grep -Fq -- "$expected" "$file" ||
        fail "expected $(basename "$file") to contain: $expected"
}

assert_not_contains() {
    file=$1
    unexpected=$2
    if grep -Fq -- "$unexpected" "$file"; then
        fail "expected $(basename "$file") not to contain: $unexpected"
    fi
}

assert_command_matches() {
    file=$1
    pattern=$2
    grep -Eq -- "$pattern" "$file" ||
        fail "expected $(basename "$file") to match: $pattern"
}

assert_command_not_matches() {
    file=$1
    pattern=$2
    if grep -Eq -- "$pattern" "$file"; then
        fail "expected $(basename "$file") not to match: $pattern"
    fi
}

make_fixture() {
    fixture=$1
    mkdir -p "$fixture"
    cat > "$fixture/go.mod" <<'EOF'
module example.com/lintfixture

go 1.22
EOF
    cat > "$fixture/fixture.go" <<'EOF'
package fixture

func Answer() int {
	return 42
}
EOF
}

make_command_guards() {
    fakebin=$1
    mkdir -p "$fakebin"

    cat > "$fakebin/go" <<'EOF'
#!/usr/bin/env bash
{
    printf 'go'
    printf '\t%s' "$@"
    printf '\n'
} >> "$COMMAND_LOG"

if [[ "${1:-}" == "install" ]]; then
    echo "blocked unsafe command: go $*" >&2
    exit 97
fi
if [[ "${1:-}" == "list" && "${2:-}" == "-m" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "-u" ]]; then
            echo "blocked network-sensitive command: go $*" >&2
            exit 97
        fi
    done
fi

exec "$REAL_GO" "$@"
EOF
    chmod +x "$fakebin/go"

    for command_name in curl wget; do
        cat > "$fakebin/$command_name" <<'EOF'
#!/usr/bin/env bash
command_name=${0##*/}
{
    printf '%s' "$command_name"
    printf '\t%s' "$@"
    printf '\n'
} >> "$COMMAND_LOG"
echo "blocked network command: $command_name $*" >&2
exit 97
EOF
        chmod +x "$fakebin/$command_name"
    done
}

run_case() {
    name=$1
    shift

    case_root="$TEST_ROOT/$name"
    fixture="$case_root/fixture"
    fakebin="$case_root/fakebin"
    output="$case_root/output"
    commands="$case_root/commands"
    mkdir -p "$case_root/home" "$case_root/tmp"
    : > "$commands"
    make_fixture "$fixture"
    make_command_guards "$fakebin"

    if ! (
        cd "$fixture"
        env -i \
            PATH="$fakebin:$PATH" \
            HOME="$case_root/home" \
            TMPDIR="$case_root/tmp" \
            COMMAND_LOG="$commands" \
            REAL_GO="$REAL_GO" \
            GOPROXY=off \
            GOSUMDB=off \
            GOTOOLCHAIN=local \
            "$@" \
            bash "$LINT_PROJECT"
    ) > "$output" 2>&1; then
        cat "$output" >&2
        fail "$name exited unsuccessfully"
    fi

    LAST_OUTPUT=$output
    LAST_COMMANDS=$commands
}

test_only_golangci_disabled() {
    run_case only-golangci-disabled \
        ONLY_GOLANGCI=yes \
        SKIP_GOLANGCI=yes

    assert_contains "$LAST_OUTPUT" "SKIPPING golangci-lint"
    assert_contains "$LAST_OUTPUT" "SKIPPING Go tests from env var"
    assert_not_contains "$LAST_OUTPUT" "Building Go source code"
    assert_command_not_matches "$LAST_COMMANDS" '^go	(build|install|test)(	|$)'
    assert_command_not_matches "$LAST_COMMANDS" '^(curl|wget)(	|$)'
}

test_skip_linters_runs_tests() {
    run_case skip-linters-runs-tests \
        SKIP_LINTERS=yes \
        SKIP_RETRACTED=yes \
        DISABLE_GORACE=yes \
        COVER_THRESHOLD=disabled

    assert_contains "$LAST_OUTPUT" "SKIPPING linters"
    assert_contains "$LAST_OUTPUT" "SKIPPING golangci-lint"
    assert_contains "$LAST_OUTPUT" "with coverage disabled"
    assert_contains "$LAST_OUTPUT" "finished running Go tests"
    assert_not_contains "$LAST_OUTPUT" "Building Go source code"
    assert_command_matches "$LAST_COMMANDS" '^go	test(	|$)'
    assert_command_not_matches "$LAST_COMMANDS" '^go	list	-m	-u(	|$)'
    assert_command_not_matches "$LAST_COMMANDS" '^(curl|wget)(	|$)'
}

test_all_skip_controls() {
    run_case skip-linters-tests-retracted \
        SKIP_LINTERS=yes \
        SKIP_TESTS=yes \
        SKIP_RETRACTED=yes

    assert_contains "$LAST_OUTPUT" "SKIPPING linters"
    assert_contains "$LAST_OUTPUT" "SKIPPING golangci-lint"
    assert_contains "$LAST_OUTPUT" "SKIPPING Go tests from env var"
    assert_command_not_matches "$LAST_COMMANDS" '^go	(build|install|test)(	|$)'
    assert_command_not_matches "$LAST_COMMANDS" '^go	list	-m	-u(	|$)'
    assert_command_not_matches "$LAST_COMMANDS" '^(curl|wget)(	|$)'
}

tests=(
    test_only_golangci_disabled
    test_skip_linters_runs_tests
    test_all_skip_controls
)

for test_name in "${tests[@]}"; do
    "$test_name"
    echo "PASS: $test_name"
done

echo "PASS: ${#tests[@]} lint-project characterization tests"
