#!/bin/bash
# lint-project.sh — Moov Go lint + test runner.
#
# This script is downloaded and run by most Moov Go repositories. It is
# typically invoked twice per CI pipeline:
#   1. Linting job:  SKIP_TESTS=yes   ./lint-project.sh   (runs linters only)
#   2. Testing job:  SKIP_LINTERS=yes ./lint-project.sh   (runs tests only)
#
# Environment variables (see go/README.md for the authoritative list).
: "${SKIP_LINTERS:=}"                # Skip all linters (testing job).
: "${SKIP_TESTS:=}"                  # Skip the Go test phase (linting job).
: "${ONLY_GOLANGCI:=}"               # Run only golangci-lint (and its --fix).
: "${DISABLE_GITLEAKS:=}"            # Skip gitleaks.
: "${DISABLE_GOVULNCHECK:=}"         # Skip govulncheck.
: "${DISABLE_XMLENCODERCLOSE:=}"     # Skip xmlencoderclose.
: "${DISABLE_GORACE:=}"              # Disable -race.
: "${SKIP_GOLANGCI:=}"               # Skip golangci-lint.
: "${SKIP_FORBIDIGO:=}"              # Don't add forbidigo to golangci-lint.
: "${GOLANGCI_DO_FIX:=}"             # Pass --fix to golangci-lint.
: "${GOLANGCI_LINTERS:=}"            # Append linters to golangci-lint.
: "${SET_GOLANGCI_LINTERS:=}"        # Replace the golangci-lint linter set.
: "${DISABLED_GOLANGCI_LINTERS:=}"   # Disable these golangci-lint linters.
: "${STRICT_GOLANGCI_LINTERS:=}"     # Enable strict golangci-lint linters (auto for moov-io).
: "${GOLANGCI_SKIP_DIR:=}"           # Exclude a dir from golangci-lint paths.
: "${GOLANGCI_SKIP_FILES:=}"         # Exclude files from golangci-lint paths.
: "${GOLANGCI_ALLOW_PRINT:=}"        # Allow fmt.Print* (otherwise forbidden by forbidigo).
: "${GOLANGCI_LINT_VERSION:=latest}" # Override golangci-lint version.
: "${GOLANGCI_FLAGS:=}"              # Extra flags for golangci-lint.
: "${GOTAGS:=}"                      # Build tags (passed to go build/test/golangci-lint).
: "${GOBUILD_FLAGS:=}"               # Extra flags for go build.
: "${GOTEST_PKGS:=./...}"            # Package selector for go test.
: "${GOTEST_FLAGS:=}"                # Extra flags for go test.
: "${GOTEST_PARALLEL:=}"             # -parallel=N flag for go test.
: "${COVER_THRESHOLD:=}"             # Minimum statement coverage (e.g. 85.0) or "disabled".
: "${PROFILE_GOTEST:=}"              # Per-package CPU/mem profiling.
: "${SKIP_SUBMODULE_TESTS:=}"        # Skip tests in nested go.mod submodules.
: "${VENDOR_FOR_TESTS:=}"            # Run go mod tidy + vendor before tests.
: "${EXPERIMENTAL:=}"                # Opt-in to experimental features:
                                     #   linters: gitleaks (moov-io only), govulncheck,
                                     #            sqlvet, xmlencoderclose, nilaway
                                     #   go test: shuffle, parallel
: "${GITLEAKS_EXCLUDE:=}"            # Exclude a dir pattern from gitleaks.
: "${NILAWAY_MEMORY_LIMIT:=7168MiB}" # GOMEMLIMIT for nilaway.
: "${NILAWAY_PACKAGES:=./...}"       # Packages for nilaway.
: "${CGO_ENABLED:=}"                 # Standard Go env var (affects -race eligibility).
: "${GOOS:=}"                        # Standard Go env var (affects -race eligibility).
: "${GOARCH:=}"                      # Standard Go env var (affects -race eligibility).
: "${TRAVIS_OS_NAME:=}"              # (Legacy) OS hint; otherwise derived from uname.

set -e

# --- Constants ---
readonly \
    gitleaks_version=8.17.0 \
    golangci_version="${GOLANGCI_LINT_VERSION:-latest}" \
    sqlvet_version=v1.1.5 \
    default_linters="\
asciicheck,bidichk,bodyclose,durationcheck,exhaustive,fatcontext,forcetypeassert,gosec,\
misspell,nolintlint,protogetter,rowserrcheck,sqlclosecheck,testifylint,wastedassign" \
    strict_linters="\
dupword,exptostd,gocheckcompilerdirectives,iface,mirror,\
nilnesserr,sloglint,testableexamples,usetesting" \
    UNAME="$(uname -s | tr [:upper:] [:lower:])"
declare -ra skip_modules=("github.com/moby/sys/user")

configFilepath="" org="" GOLANGCI_TAGS="" GORACE=""
# TODO: why does this need to be exported?
export OS_NAME="$TRAVIS_OS_NAME"


cleanup() {
    if [[ -n "$configFilepath" ]]; then
        rm -f "$configFilepath"
    fi
}
trap cleanup EXIT

main() {
    setup_environment
    collect_go_metadata
    setup_build_test_flags

    if [[ $SKIP_LINTERS ]]; then
        echo "SKIPPING linters for $OS_NAME"
    else
        echo "running go linters for $OS_NAME"
    fi

    if [[ $ONLY_GOLANGCI == "yes" ]]; then
        maybe_run_golangci_lint
        return $?
    fi

    if [[ $org == "moov-io" ]]; then
        check_no_moovfinancial_deps
    fi
    check_retracted_modules

    if [[ -z $SKIP_LINTERS ]]; then
        build_source # discover compile errors prior to linting
        run_linters # includes golangci_lint
    fi

    if [[ $SKIP_TESTS == "yes" ]]; then
        echo "SKIPPING Go tests from env var"
    else
        run_tests
        verify_coverage

        echo "finished running Go tests"
    fi
}

setup_environment() {
    mkdir -p ./bin/

    # Print (and capture) the host's Go version.
    GO_VERSION=$(go version | grep -Eo '[0-9]\.[0-9]+\.?[0-9]?')
    echo "Detected Go version $GO_VERSION"

    # Set OS_NAME if it's empty (local dev).
    if [[ "$OS_NAME" == "" ]]; then
        if [[ "$UNAME" == "darwin" ]]; then
            OS_NAME=osx
        else
            OS_NAME=linux
        fi
    fi
}

collect_go_metadata() {
    # Collect all our files for processing.
    MODNAME=$(go list .)
    GOPKGS=($(go list ./...))
    GOFILES=($(find . -type f -not -path "./nginx/*" -name '*.go' -not -name '*.pb.go' | grep -v client | grep -v vendor))

    # Would be set to 'moov-io' or 'moovfinancial'.
    org=$(go mod why | head -n1  | awk -F'/' '{print $2}')
}

check_no_moovfinancial_deps() {
    # Reject moovfinancial dependencies in moov-io projects.
    if go list -m all | grep moovfinancial; then
        echo "Found github.com/moovfinancial dependencies in OSS. Please remove"
        exit 1
    fi
}

setup_build_test_flags() {
    # Allow for build tags to be set.
    if [[ "$GOTAGS" != "" ]]; then
        GOLANGCI_TAGS=" --build-tags $GOTAGS "
        GOTAGS=" -tags $GOTAGS "
    fi

    GORACE='-race'
    if [[ "$CGO_ENABLED" == "0" || "$GOOS" == "js" || "$GOARCH" == "wasm" ]]; then
        GORACE=''
    fi
    if [[ "$DISABLE_GORACE" != "" ]]; then
        GORACE=''
    fi
}

maybe_run_golangci_lint() {
    [[ $OS_NAME == "windows" ]] && return

    if [[ $SKIP_GOLANGCI || $SKIP_LINTERS ]]; then
        echo "SKIPPING golangci-lint"
    else
        run_golangci_lint
    fi
}

check_retracted_modules() {
    # Verify no retracted module versions are in the build.
    retracted_mods=($(go list -m -u all | grep retracted | cut -f1 -d' '))
    for dep in "${retracted_mods[@]}"
    do
        # Check if the project actually uses this mod.
        if go mod why "$dep" | grep -q "module does not need package";
        then
            echo "INFO: $dep is retracted, but not used in this project"
        else
            # Check if the module is in skip_modules.
            skip=false
            for skip_mod in "${skip_modules[@]}"
            do
                if [ "$dep" = "$skip_mod" ]; then
                    skip=true
                    break
                fi
            done

            if [[ $skip == "true" ]]; then
                echo "INFO: $dep is retracted but in skip list, ignoring"
            else
                echo "ERROR: $dep needs to be updated, current version is retracted"
                go list -m -u -json "$dep"
                exit 1
            fi
        fi
    done
}

build_source() {
    echo "Building Go source code"
    go build $GORACE $GOTAGS $GOBUILD_FLAGS ./...
    echo "SUCCESS: Go code built without errors"
}

# === Linters phase ===

run_linters() {
    if [[ $org == "moov-io" && $EXPERIMENTAL == *gitleaks* && -z $DISABLE_GITLEAKS ]]; then
        run_gitleaks
    fi

    if [[ -z $DISABLE_GOVULNCHECK ]]; then
        run_govulncheck
    fi

    if [[ $EXPERIMENTAL == *sqlvet* ]];
    then
        run_sqlvet
    fi

    if [[ $EXPERIMENTAL == *xmlencoderclose* && -z $DISABLE_XMLENCODERCLOSE ]]; then
        run_xmlencoderclose
    fi

    if [[ $EXPERIMENTAL == *nilaway* ]]; then
        run_nilaway
    fi

    maybe_run_golangci_lint
}

# gitleaks (secret scanning, in-progress of a rollout).
run_gitleaks() {
    [[ $OS_NAME == "windows" ]] && return

    wget -q -O gitleaks.tar.gz https://github.com/zricethezav/gitleaks/releases/download/v"$gitleaks_version"/gitleaks_"$gitleaks_version"_"$UNAME"_x64.tar.gz
    tar xf gitleaks.tar.gz gitleaks
    mv gitleaks ./bin/gitleaks

    echo "gitleaks version: "$(./bin/gitleaks version)

    # Find directories and optionally exclude one.
    if [[ $GITLEAKS_EXCLUDE ]]; then
        dirs=($(find . -mindepth 1 -type d | sort -u | grep -v ".git"))
        dirs=($(printf "%s\n" "${dirs[@]}" | grep -v "$GITLEAKS_EXCLUDE"))

        for dir in "${dirs[@]}"; do
            echo "Running gitleaks on $dir"
            ./bin/gitleaks detect --no-git --verbose --no-banner --source "$dir"
        done
    else
        ./bin/gitleaks detect --no-git --verbose
    fi

    echo "FINISHED gitleaks check"
}

## Run govulncheck which parses the compiled/used code for known vulnerabilities.
run_govulncheck() {
    # Dedicated govulncheck workflow handles scanning (including weekly scheduled runs);
    # skip here to avoid running twice on PRs.
    [[ -f ".github/workflows/govulncheck.yml" ]] && return

    echo "STARTING govulncheck check"

    # Install the latest govulncheck release.
    go install golang.org/x/vuln/cmd/govulncheck@latest

    # Find govulncheck.
    local bin=$(resolve_go_tool govulncheck)

    # Run govulncheck.
    if [[ $bin != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED govulncheck check"
    else
        echo "Can't find govulncheck..."
    fi
}

run_sqlvet() {
    # Download only on linux or macOS.
    if [[ $OS_NAME == "windows" ]]; then
        echo "sqlvet is not supported on windows"
        return
    fi

    wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/"$sqlvet_version"/sqlvet-"$sqlvet_version"-"$UNAME"-amd64.tar.gz
    tar xf sqlvet.tar.gz sqlvet
    mv sqlvet ./bin/sqlvet

    echo "sqlvet version: "$(./bin/sqlvet --version)
    ./bin/sqlvet .
    echo "FINISHED sqlvet check"
}

run_xmlencoderclose() {
    echo "STARTING xmlencoderclose check"

    # Install xmlencoderclose.
    go install github.com/adamdecaf/xmlencoderclose@latest

    # Find the linter.
    local bin=$(resolve_go_tool xmlencoderclose)

    # Run xmlencoderclose.
    if [[ $bin != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED xmlencoderclose check"
    else
        echo "Can't find xmlencoderclose..."
    fi
}

run_nilaway() {
    # nilaway can deliver false positives so it's not currently allowed inside of golangci-lint,
    # however this linter is useful so we offer it.
    #
    # https://github.com/golangci/golangci-lint/issues/4045
    echo "STARTING nilaway check"

    # Install nilaway.
    go install go.uber.org/nilaway/cmd/nilaway@latest

    # Find nilaway on PATH.
    local bin=$(resolve_go_tool nilaway)

    # Run nilaway.
    if [[ $bin != "" ]];
    then
        echo "Running nilaway with GOMEMLIMIT=""$NILAWAY_MEMORY_LIMIT"" in ""$NILAWAY_PACKAGES"
        GOMEMLIMIT="$NILAWAY_MEMORY_LIMIT" time "$bin" -test=false "$NILAWAY_PACKAGES"
        echo "FINISHED nilaway check"
    fi
}

# golangci-lint.
run_golangci_lint() {
    if [[ $org == "moov-io" ]];
    then
        STRICT_GOLANGCI_LINTERS=${STRICT_GOLANGCI_LINTERS:="yes"}
    fi

    echo "STARTING golangci-lint checks"

    # Download golangci-lint.
    wget -qO- https://golangci-lint.run/install.sh | sh -s -- -b ./bin "$golangci_version"

    ./bin/golangci-lint version

    local GOLANGCI_FIX_FLAG=""
    if [[ $GOLANGCI_DO_FIX == "true" ]]; then
        GOLANGCI_FIX_FLAG="--fix"
    fi

    local golangci_lint_cmd_common=(
        ./bin/golangci-lint "$GOLANGCI_FLAGS" run "$GOLANGCI_FIX_FLAG"
        --verbose --timeout=5m "$GOLANGCI_TAGS"
    )
    # If the project has a committed .golangci.yml, use it directly and skip
    # dynamic config generation — the file controls all linter settings.
    if [[ -f ".golangci.yml" ]]; then
        "${golangci_lint_cmd_common[@]}"
    else
        # Create config file in the project directory so golangci-lint v2
        # resolves file paths relative to the project root, not the config location.
        configFilepath=".golangci-lint-generated.yml"
        emit_golangci_config "$configFilepath"

        local -a enable_disable_args
        set_golangci_enable_disable_args enable_disable_args

        "${golangci_lint_cmd_common[@]}" --config="$configFilepath" "${enable_disable_args[@]}"

        # Cleanup generated config (the EXIT trap is the safety net for failure)
        rm -f "$configFilepath"
        configFilepath=""
    fi

    echo "FINISHED golangci-lint checks"
}

set_golangci_enable_disable_args() {
    local -n out="$1"

    # Build the linters list.
    # TODO(adam): re-add unused when they fix some bugs.
    local enabled="$default_linters"

    if [[ $GOLANGCI_LINTERS ]]; then
        # Append additional linters.
        enabled="$enabled,$GOLANGCI_LINTERS"
    fi

    # If SET_GOLANGCI_LINTERS is set, it completely replaces the current set.
    if [[ $SET_GOLANGCI_LINTERS ]]; then
        enabled="$SET_GOLANGCI_LINTERS"
    fi

    # Add strict linters if STRICT_GOLANGCI_LINTERS is set to "yes".
    if [[ $STRICT_GOLANGCI_LINTERS == "yes" ]]; then
        enabled="$enabled,$strict_linters"
    fi

    # Add forbidigo unless skipped.
    if [[ $SKIP_FORBIDIGO != "yes" ]]; then
        enabled="$enabled,forbidigo"
    fi

    local disabled="depguard,errcheck"
    if [[ "$DISABLED_GOLANGCI_LINTERS" != "" ]]; then
        disabled="$disabled,$DISABLED_GOLANGCI_LINTERS"
    fi

    out=( "--enable=$enabled" "--disable=$disabled" )
}

# emit_golangci_config writes the dynamic golangci-lint config to
# $configFilepath using the "compute stanzas, then emit once" pattern: each
# conditional section is built into a string variable (compute phase), then the
# entire YAML is written in a single heredoc that interpolates them (emit
# phase). Empty stanzas render as blank lines, which YAML ignores. The output
# is semantically identical to the previous 3-heredoc + 6-echo>> approach.
emit_golangci_config() {
    local configFilepath="$1"

    local moovfinancial_forbid=""
    if [[ $org == "moovfinancial" ]]; then
        # Prevent UUID direct inspections in favor of moovfinancial/go-http,
        # plus ozzo validators. Quoted heredoc so \d and $ are literal.
        moovfinancial_forbid=$(cat <<'YAML'
        - pattern: .*\.IsUUID
          pkg: github.com/moovfinancial/go-libs/mvalidation
          msg: Update to moovfinancial/go-libs/mvalidation IsID[(id type goes here)]
        - pattern: is.UUID[\d]{0,}
          pkg: github.com/go-ozzo/ozzo-validation/v4/is
          msg: Update to moovfinancial/go-libs/mvalidation IsID[(id type goes here)]
YAML
        )
    fi

    local print_forbid=""
    if [[ $GOLANGCI_ALLOW_PRINT != "yes" ]]; then
        print_forbid='        - pattern: ^fmt\.Print.*$'
    fi

    local skip_paths=""
    if [[ $GOLANGCI_SKIP_DIR ]]; then
        skip_paths+="      - $GOLANGCI_SKIP_DIR"$'\n'
    fi
    if [[ $GOLANGCI_SKIP_FILES ]]; then
        skip_paths+="      - $GOLANGCI_SKIP_FILES"$'\n'
    fi

    # --- Emit phase: the entire YAML shape is visible in ONE heredoc ---
    cat > "$configFilepath" <<YAML
version: "2"
run:
  tests: false
  go: "$GO_VERSION"
formatters:
  enable:
    - gofmt
  settings:
    gofmt:
      simplify: true
linters:
  default: none
  settings:
    gosec:
      excludes:
        - G101 # Potential hardcoded credentials
        - G104 # Audit errors not checked
        - G304 # File path provided as taint input
        - G404 # Insecure random number source (rand)
        - G703 # Path traversal via taint analysis (false positive)
        - G704 # SSRF via taint analysis (false positive)
        - G705 # XSS via taint analysis (false positive)
    forbidigo:
      analyze-types: true
      forbid:
        - pkg: ^math/rand\$
        - pkg: ^plugin\$
        - pattern: ^panic\$
        - pattern: .*\.Call.*\$
          pkg: reflect
$moovfinancial_forbid
$print_forbid
    staticcheck:
      checks:
        - "none"
        - "S1*"
        - "QF1004"
        - "QF1005"
        - "QF1006"
        - "QF1009"
        - "QF1010"
        - "QF1012"
  exclusions:
    generated: lax
    presets:
      - comments
      - common-false-positives
      - legacy
      - std-error-handling
    paths:
      - admin
      - client
      - pkg/test/fixtures
$skip_paths
    rules:
      - linters: [forbidigo]
        path: '^(main\.go|cmd/|docs/|examples/|scripts/)'
YAML
}

run_tests() {
    if [[ "$VENDOR_FOR_TESTS" == "yes" ]];
    then
        echo "Vendoring deps before running tests"
        go mod tidy
        go mod vendor
    fi

    ## Clear GOARCH and GOOS for testing...
    GOARCH=''
    GOOS=''

    gotest_packages="$GOTEST_PKGS"

    coveredStatements=0
    maximumCoverage=0
    coveragePath=$(mktemp -d)"/coverage.txt"

    # Find "gotest" or "go test".
    GOTEST=$(which go)" test"
    if which -s gotest > /dev/null;
    then
        GOTEST=$(which gotest 2>&1 | head -n1)
    fi

    echo "======"

    # Run 'go test'.
    if [[ "$OS_NAME" == "windows" ]]; then
        # Just run short tests on Windows as we don't have Docker support in tests worked out for the database tests.
        echo "Running $GOTEST on $OS_NAME with extra flags: $GOTEST_FLAGS"
        $GOTEST $GOTAGS "$gotest_packages" "$GORACE" -short -coverprofile="$coveragePath" -covermode=atomic $GOTEST_FLAGS
    fi
    # Add some default flags to every 'go test' case.
    if [[ "$GOTEST_FLAGS" == "" ]]; then
        # Enable test shuffling.
        if [[ "$EXPERIMENTAL" == *"shuffle"* ]]; then
            GOTEST_FLAGS="$GOTEST_FLAGS -test.shuffle=on"
        fi

        # Enable -parallel.
        if [[ "$EXPERIMENTAL" == *"parallel"* || "$GOTEST_PARALLEL" != "" ]]; then
            if [[ "$GOTEST_PARALLEL" == "" ]]; then
                GOTEST_PARALLEL=8
            fi
            GOTEST_FLAGS="$GOTEST_FLAGS -parallel=$GOTEST_PARALLEL"
        fi
    fi
    if [[ "$OS_NAME" != "windows" ]]; then
        if [[ "$COVER_THRESHOLD" == "disabled" ]]; then
            echo "Running $GOTEST on $OS_NAME with coverage disabled and extra flags: $GOTEST_FLAGS"
            $GOTEST $GOTAGS "$gotest_packages" "$GORACE" -count 1 $GOTEST_FLAGS
        else
            # Optionally profile each package.
            if [[ "$PROFILE_GOTEST" == "yes" ]]; then
                echo "Running $GOTEST on $OS_NAME package by package and extra flags: $GOTEST_FLAGS"

                for pkg in "${GOPKGS[@]}"
                do
                    # fixup the sub-package for writing cpu/mem profile.
                    dir=${pkg#$MODNAME"/"}
                    if [[ "$pkg" == "$dir" ]];
                    then
                        dir="."
                    fi

                    $GOTEST $GOTAGS "$pkg" "$GORACE" \
                       -covermode=atomic \
                       -coverprofile="$dir"/coverage.txt \
                       -test.cpuprofile="$dir"/cpu.out \
                       -test.memprofile="$dir"/mem.out \
                       -count 1 $GOTEST_FLAGS

                    coverage=$(go tool cover -func="$dir"/coverage.txt | grep total | grep -Eo '[0-9]+\.[0-9]+')
                    if [[ "$coverage" > "0.0" ]];
                    then
                        coveredStatements=$(echo "$coveredStatements" + "$coverage" | bc)
                        maximumCoverage=$((maximumCoverage+100))
                    fi
                done
            else
                # Otherwise just run Go tests with coverage.
                echo "Running $GOTEST on $OS_NAME with coverage and extra flags: $GOTEST_FLAGS"
                $GOTEST $GOTAGS "$gotest_packages" "$GORACE" -coverprofile="$coveragePath" -covermode=atomic -count 1 $GOTEST_FLAGS
            fi
        fi
    fi

    # Run Go Tests on submodules.
    if [[ "$SKIP_SUBMODULE_TESTS" == "" ]];
    then
        submodules=$(find . -mindepth 2 -name go.mod)
        if [ -n "$submodules" ]; then
            echo "Testing Submodules..."

            for mod_file in $submodules; do
                dir=$(dirname "$mod_file")
                (cd "$dir" && $GOTEST $GOTAGS "$gotest_packages" "$GORACE" && cd -)
            done
        fi
    fi
}

verify_coverage() {
    # Verify Code Coverage Threshold.
    if [[ "$COVER_THRESHOLD" != "" && "$COVER_THRESHOLD" != "disabled" ]]; then
        if [[ -f "$coveragePath" && "$PROFILE_GOTEST" != "yes" ]];
        then
            # Ignore test directories in coverage analysis.
            cat "$coveragePath" | grep -v -E "/client/" | grep -v -E "/pkg*/*test" | grep -v -E "/internal*/*test" | grep -v -E "/examples/" | grep -v -E "/gen/"  > coverage.txt
            coveredStatements=$(go tool cover -func=coverage.txt | grep -E '^total:' | grep -Eo '[0-9]+\.[0-9]+')
            maximumCoverage=100
        fi

        avgCoverage=$(printf "%.1f" $(echo "($coveredStatements / $maximumCoverage)*100" | bc -l))
        echo "Project has $avgCoverage% statement coverage."

        if (( $(echo "$avgCoverage < $COVER_THRESHOLD" | bc -l) )); then
            echo "ERROR: statement coverage is not sufficient, $COVER_THRESHOLD% is required"
            exit 1
        else
            echo "SUCCESS: project has sufficient statement coverage (over $COVER_THRESHOLD%)"
        fi
    else
        echo "Skipping code coverage threshold, consider setting COVER_THRESHOLD. (Example: 85.0)"
    fi
}

# === Shared helpers (lowest level; used by multiple phases above) ===

# resolve_go_tool finds a Go-installed linter binary by name, checking (in
# order) the PATH via `which`, then the public GitHub runners' GOBIN, then the
# Moov hosted runners' bin dir. Returns the path on stdout (empty if not
# found). Dedupes the three copy-pasted blocks previously inlined in
# run_govulncheck, run_xmlencoderclose, and run_nilaway.
resolve_go_tool() {
    local name="$1"
    local bin=""
    if which -s "$name" > /dev/null;
    then
        bin=$(which "$name" 2>&1 | head -n1)
    fi
    # Public GitHub runners path.
    local actions_path="/home/runner/go/bin/$name"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi
    # Moov hosted runner paths.
    actions_path="/home/actions/bin/$name"
    if [[ -f "$actions_path" ]];
    then
        bin="$actions_path"
    fi
    printf '%s' "$bin"
}

main "$@"
