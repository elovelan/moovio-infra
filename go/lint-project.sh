#!/bin/bash
# lint-project.sh — Moov Go lint + test runner.
#
# This script is downloaded and run by most Moov Go repositories. It is
# typically invoked twice per CI pipeline:
#   1. Linting job:  SKIP_TESTS=yes   ./lint-project.sh   (runs linters only)
#   2. Testing job:  SKIP_LINTERS=yes ./lint-project.sh   (runs tests only)
#
# Environment variables (see go/README.md for the authoritative list):
#   SKIP_LINTERS            Skip all linters (testing job).
#   SKIP_TESTS=yes          Skip the Go test phase (linting job).
#   ONLY_GOLANGCI=yes       Run only golangci-lint (and its --fix).
#   DISABLE_GITLEAKS        Skip gitleaks.
#   DISABLE_GOVULNCHECK     Skip govulncheck.
#   DISABLE_XMLENCODERCLOSE Skip xmlencoderclose.
#   DISABLE_GORACE          Disable -race.
#   SKIP_GOLANGCI           Skip golangci-lint.
#   SKIP_FORBIDIGO=yes      Don't add forbidigo to golangci-lint.
#   GOLANGCI_DO_FIX=true    Pass --fix to golangci-lint.
#   GOLANGCI_LINTERS        Append linters to golangci-lint.
#   SET_GOLANGCI_LINTERS    Replace the golangci-lint linter set.
#   DISABLED_GOLANGCI_LINTERS  Disable these golangci-lint linters.
#   STRICT_GOLANGCI_LINTERS=yes  Enable strict golangci-lint linters (auto for moov-io).
#   GOLANGCI_SKIP_DIR       Exclude a dir from golangci-lint paths.
#   GOLANGCI_SKIP_FILES     Exclude files from golangci-lint paths.
#   GOLANGCI_ALLOW_PRINT=yes  Allow fmt.Print* (otherwise forbidden by forbidigo).
#   GOLANGCI_LINT_VERSION   Override golangci-lint version (default latest).
#   GOLANGCI_FLAGS          Extra flags for golangci-lint.
#   GOTAGS                  Build tags (passed to go build/test/golangci-lint).
#   GOBUILD_FLAGS           Extra flags for go build.
#   GOTEST_PKGS             Package selector for go test (default ./...).
#   GOTEST_FLAGS            Extra flags for go test.
#   GOTEST_PARALLEL         -parallel=N flag for go test.
#   COVER_THRESHOLD         Minimum statement coverage (e.g. 85.0) or "disabled".
#   PROFILE_GOTEST=yes      Per-package CPU/mem profiling.
#   SKIP_SUBMODULE_TESTS    Skip tests in nested go.mod submodules.
#   VENDOR_FOR_TESTS=yes    Run go mod tidy + vendor before tests.
#   EXPERIMENTAL            Comma-list of opt-in checks: gitleaks, govulncheck,
#                           shuffle, parallel, sqlvet, xmlencoderclose, nilaway.
#   GITLEAKS_EXCLUDE        Exclude a dir pattern from gitleaks.
#   NILAWAY_MEMORY_LIMIT    GOMEMLIMIT for nilaway (default 7168MiB).
#   NILAWAY_PACKAGES        Packages for nilaway (default ./...).
#   CGO_ENABLED, GOOS, GOARCH  Standard Go env vars (affect -race eligibility).
#   TRAVIS_OS_NAME          (Legacy) OS hint; otherwise derived from uname.

set -e

# --- Constants ---
gitleaks_version=8.17.0
golangci_version="${GOLANGCI_LINT_VERSION:-latest}"
sqlvet_version=v1.1.5

default_linters="asciicheck,bidichk,bodyclose,durationcheck,exhaustive,fatcontext,forcetypeassert,gosec,misspell,nolintlint,protogetter,rowserrcheck,sqlclosecheck,testifylint,wastedassign"
strict_linters="dupword,exptostd,gocheckcompilerdirectives,iface,mirror,nilnesserr,sloglint,testableexamples,usetesting"
skip_modules=(
    "github.com/moby/sys/user"
)

# --- Globals (set during setup; declared here so the EXIT trap and cross-
#     function reads have a defined empty value before setup runs) ---
disable_golangci=""
configFilepath=""

# --- Cleanup trap ---
# Removes the generated golangci-lint config on any exit (success or failure),
# so a mid-run crash never leaves .golangci-lint-generated.yml behind. The
# manual rm at the end of run_golangci_lint still runs on the happy path; this
# trap is the safety net for the failure path.
cleanup() {
    if [[ -n "$configFilepath" ]]; then
        rm -f "$configFilepath"
    fi
}
trap cleanup EXIT

# === Entry point ===
#
# main is the single dispatch point. Every phase is a direct callee of main;
# nothing runs except through main. The dual-run contract lives here:
#   - SKIP_LINTERS set  -> each linter self-gates and skips (run_linters is
#                          still called so per-linter skip messages print).
#   - SKIP_TESTS=yes    -> early exit 0 after linters (matches prior behavior).
main() {
    setup_environment
    collect_go_metadata
    check_no_moovfinancial_deps
    setup_build_flags
    check_retracted_modules
    build_source

    run_linters

    if [[ "$SKIP_TESTS" == "yes" ]]; then
        echo "SKIPPING Go tests from env var"
        exit 0
    fi
    run_tests
    verify_coverage

    echo "finished running Go tests"
}

# === Setup phase (callees in the order main calls them) ===

setup_environment() {
    # Set disable_golangci to any non-blank value to disable golangci-lint.
    disable_golangci=""
    if [[ "$SKIP_GOLANGCI" != "" ]]; then
        disable_golangci="$SKIP_GOLANGCI"
    fi

    mkdir -p ./bin/

    # Print (and capture) the host's Go version.
    GO_VERSION=$(go version | grep -Eo '[0-9]\.[0-9]+\.?[0-9]?')
    echo "Detected Go version $GO_VERSION"

    # Set OS_NAME if it's empty (local dev).
    OS_NAME=$TRAVIS_OS_NAME
    UNAME=$(uname -s | tr [:upper:] [:lower:])
    if [[ "$OS_NAME" == "" ]]; then
        if [[ "$UNAME" == "darwin" ]]; then
            export OS_NAME=osx
        else
            export OS_NAME=linux
        fi
    fi

    if [[ "$SKIP_LINTERS" != "" ]]; then
        echo "SKIPPING linters for $OS_NAME"
    else
        echo "running go linters for $OS_NAME"
    fi

    # ONLY_GOLANGCI=yes skips all checks except golangci-lint (and its --fix
    # via GOLANGCI_DO_FIX=true).
    if [[ "$ONLY_GOLANGCI" == "yes" ]]; then
        DISABLE_GITLEAKS=yes
        DISABLE_GOVULNCHECK=yes
        EXPERIMENTAL=""
        SKIP_TESTS=yes
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
    if [[ "$ONLY_GOLANGCI" != "yes" && "$org" == "moov-io" ]]; then
        # Fail our build if we find moovfinancial dependencies.
        if go list -m all | grep moovfinancial; then
            echo "Found github.com/moovfinancial dependencies in OSS. Please remove"
            exit 1
        fi
    fi
}

setup_build_flags() {
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

check_retracted_modules() {
    # Verify no retracted module versions are in the build.
    if [[ "$ONLY_GOLANGCI" == "yes" ]]; then
        retracted_mods=()
    else
        retracted_mods=($(go list -m -u all | grep retracted | cut -f1 -d' '))
    fi
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

            if [ "$skip" = true ]; then
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
    # Build the source code (to discover compile errors prior to linting).
    if [[ "$SKIP_LINTERS" == "" && "$ONLY_GOLANGCI" != "yes" ]]; then
        echo "Building Go source code"
        go build $GORACE $GOTAGS $GOBUILD_FLAGS ./...
        echo "SUCCESS: Go code built without errors"
    fi
}

# === Linters phase ===

run_linters() {
    # Called unconditionally by main; each linter self-gates on SKIP_LINTERS,
    # DISABLE_*, and EXPERIMENTAL so the per-linter skip messages (e.g.
    # "SKIPPING golangci-lint") print exactly as before.
    run_gitleaks
    run_govulncheck
    run_sqlvet
    run_xmlencoderclose
    run_nilaway
    run_golangci_lint
}

# gitleaks (secret scanning, in-progress of a rollout).
run_gitleaks() {
    run_gitleaks=true
    if [[ "$OS_NAME" == "windows" ]]; then
        run_gitleaks=false
    fi
    if [[ "$org" != "moov-io" ]]; then
        run_gitleaks=false
    fi
    if [[ "$EXPERIMENTAL" == *"gitleaks"* ]]; then
        run_gitleaks=true
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        run_gitleaks=false
    fi
    if [[ "$DISABLE_GITLEAKS" != "" ]]; then
        run_gitleaks=false
    fi
    if [[ "$run_gitleaks" == "true" ]]; then
        wget -q -O gitleaks.tar.gz https://github.com/zricethezav/gitleaks/releases/download/v"$gitleaks_version"/gitleaks_"$gitleaks_version"_"$UNAME"_x64.tar.gz
        tar xf gitleaks.tar.gz gitleaks
        mv gitleaks ./bin/gitleaks

        echo "gitleaks version: "$(./bin/gitleaks version)

        # Find directories and optionally exclude one.
        if [ -n "$GITLEAKS_EXCLUDE" ]; then
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
    fi
}

## Run govulncheck which parses the compiled/used code for known vulnerabilities.
run_govulncheck() {
    run_govulncheck=true
    if [[ "$DISABLE_GOVULNCHECK" != "" ]]; then
        run_govulncheck=false
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        run_govulncheck=false
    fi
    if [[ -f ".github/workflows/govulncheck.yml" ]]; then
        # Dedicated govulncheck workflow handles scanning (including weekly scheduled runs);
        # skip here to avoid running twice on PRs.
        run_govulncheck=false
    fi
    if [[ "$run_govulncheck" == "true" ]]; then
        echo "STARTING govulncheck check"

        # Install the latest govulncheck release.
        go install golang.org/x/vuln/cmd/govulncheck@latest

        # Find govulncheck.
        bin=$(resolve_go_tool govulncheck)

        # Run govulncheck.
        if [[ "$bin" != "" ]];
        then
            "$bin" -test ./...
            echo "FINISHED govulncheck check"
        else
            echo "Can't find govulncheck..."
        fi
    fi
}

# sqlvet.
run_sqlvet() {
    run_sqlvet=false
    if [[ "$EXPERIMENTAL" == *"sqlvet"* ]]; then
        run_sqlvet=true
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        run_sqlvet=false
    fi
    if [[ "$run_sqlvet" == "true" ]]; then
        # Download only on linux or macOS.
        if [[ "$OS_NAME" != "windows" ]]; then
            if [[ "$OS_NAME" == "linux" ]]; then wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/"$sqlvet_version"/sqlvet-"$sqlvet_version"-linux-amd64.tar.gz; fi
            if [[ "$OS_NAME" == "osx" ]]; then wget -q -O sqlvet.tar.gz https://github.com/houqp/sqlvet/releases/download/"$sqlvet_version"/sqlvet-"$sqlvet_version"-darwin-amd64.tar.gz; fi
            tar xf sqlvet.tar.gz sqlvet
            mv sqlvet ./bin/sqlvet

            echo "sqlvet version: "$(./bin/sqlvet --version)
            ./bin/sqlvet .
            echo "FINISHED sqlvet check"
        else
            echo "sqlvet is not supported on windows"
        fi
    fi
}

run_xmlencoderclose() {
    run_xmlencoderclose=false
    if [[ "$DISABLE_XMLENCODERCLOSE" != "" ]]; then
        run_xmlencoderclose=false
    fi
    if [[ "$EXPERIMENTAL" == *"xmlencoderclose"* ]];
    then
        run_xmlencoderclose=true
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        run_xmlencoderclose=false
    fi
    if [[ "$run_xmlencoderclose" == "true" ]]; then
        echo "STARTING xmlencoderclose check"

        # Install xmlencoderclose.
        go install github.com/adamdecaf/xmlencoderclose@latest

        # Find the linter.
        bin=$(resolve_go_tool xmlencoderclose)

        # Run xmlencoderclose.
        if [[ "$bin" != "" ]];
        then
            "$bin" -test ./...
            echo "FINISHED xmlencoderclose check"
        else
            echo "Can't find xmlencoderclose..."
        fi
    fi
}

run_nilaway() {
    run_nilaway=false
    if [[ "$EXPERIMENTAL" == *"nilaway"* ]];
    then
        run_nilaway=true
    fi
    if [[ "$SKIP_LINTERS" != "" ]];
    then
        run_nilaway=false
    fi
    if [[ "$run_nilaway" == "true" ]];
    then
        # nilaway can deliver false positives so it's not currently allowed inside of golangci-lint,
        # however this linter is useful so we offer it.
        #
        # https://github.com/golangci/golangci-lint/issues/4045
        echo "STARTING nilaway check"

        # Install nilaway.
        go install go.uber.org/nilaway/cmd/nilaway@latest

        # Find nilaway on PATH.
        bin=$(resolve_go_tool nilaway)

        nilaway_memory_limit="7168MiB"
        if [[ "$NILAWAY_MEMORY_LIMIT" != "" ]]; then
            nilaway_memory_limit="$NILAWAY_MEMORY_LIMIT"
        fi

        nilaway_packages="./..."
        if [[ "$NILAWAY_PACKAGES" != "" ]]; then
            nilaway_packages="$NILAWAY_PACKAGES"
        fi

        # Run nilaway.
        if [[ "$bin" != "" ]];
        then
            echo "Running nilaway with GOMEMLIMIT=""$nilaway_memory_limit"" in ""$nilaway_packages"
            GOMEMLIMIT="$nilaway_memory_limit" time "$bin" -test=false "$nilaway_packages"
            echo "FINISHED nilaway check"
        fi
    fi
}

# golangci-lint.
run_golangci_lint() {
    if [[ "$org" == "moov-io" ]];
    then
        STRICT_GOLANGCI_LINTERS=${STRICT_GOLANGCI_LINTERS:="yes"}
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        disable_golangci=true
    fi
    if [[ "$OS_NAME" != "windows" ]]; then
        if [[ "$disable_golangci" != "" ]];
        then
            echo "SKIPPING golangci-lint"
        else
            echo "STARTING golangci-lint checks"

            # Download golangci-lint.
            wget -qO- https://golangci-lint.run/install.sh | sh -s -- -b ./bin "$golangci_version"

            ./bin/golangci-lint version

            GOLANGCI_FIX_FLAG=""
            if [[ "$GOLANGCI_DO_FIX" == "true" ]]; then
                GOLANGCI_FIX_FLAG="--fix"
            fi

            # If the project has a committed .golangci.yml, use it directly and skip
            # dynamic config generation — the file controls all linter settings.
            if [[ -f ".golangci.yml" ]]; then
                ./bin/golangci-lint $GOLANGCI_FLAGS run $GOLANGCI_FIX_FLAG --verbose --timeout=5m $GOLANGCI_TAGS
            else
                # Build the linters list.
                # TODO(adam): re-add unused when they fix some bugs.
                enabled="$default_linters"

                if [ -n "$GOLANGCI_LINTERS" ]; then
                    # Append additional linters.
                    enabled="$enabled,$GOLANGCI_LINTERS"
                fi

                # If SET_GOLANGCI_LINTERS is set, it completely replaces the current set.
                if [ -n "$SET_GOLANGCI_LINTERS" ]; then
                    enabled="$SET_GOLANGCI_LINTERS"
                fi

                # Add strict linters if STRICT_GOLANGCI_LINTERS is set to "yes".
                if [[ "$STRICT_GOLANGCI_LINTERS" == "yes" ]]; then
                    enabled="$enabled,$strict_linters"
                fi

                # Add forbidigo unless skipped.
                if [[ "$SKIP_FORBIDIGO" != "yes" ]];
                then
                    enabled="$enabled,forbidigo"
                fi

                # Create config file in the project directory so golangci-lint v2
                # resolves file paths relative to the project root, not the config location.
                configFilepath=".golangci-lint-generated.yml"
                emit_golangci_config

                # Build --enable and --disable flags from env vars rather than config.
                GOLANGCI_ENABLE_FLAG="--enable=$enabled"

                disabled="depguard,errcheck"
                if [[ "$DISABLED_GOLANGCI_LINTERS" != "" ]]; then
                    disabled="$disabled,$DISABLED_GOLANGCI_LINTERS"
                fi
                GOLANGCI_DISABLE_FLAG="--disable=$disabled"

                ./bin/golangci-lint $GOLANGCI_FLAGS run --config="$configFilepath" $GOLANGCI_FIX_FLAG $GOLANGCI_ENABLE_FLAG $GOLANGCI_DISABLE_FLAG --verbose --timeout=5m $GOLANGCI_TAGS

                # Cleanup generated config (the EXIT trap is the safety net for
                # the failure path; this preserves the original happy-path timing).
                rm -f "$configFilepath"
                configFilepath=""
            fi

            echo "FINISHED golangci-lint checks"
        fi
    fi
}

# emit_golangci_config writes the dynamic golangci-lint config to
# $configFilepath using the "compute stanzas, then emit once" pattern: each
# conditional section is built into a string variable (compute phase), then the
# entire YAML is written in a single heredoc that interpolates them (emit
# phase). Empty stanzas render as blank lines, which YAML ignores. The output
# is semantically identical to the previous 3-heredoc + 6-echo>> approach.
emit_golangci_config() {
    # --- Compute phase: each conditional stanza -> a string variable ---

    local moovfinancial_forbid=""
    if [[ "$org" == "moovfinancial" ]]; then
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
    if [[ "$GOLANGCI_ALLOW_PRINT" != "yes" ]]; then
        print_forbid=$(cat <<'YAML'
        - pattern: ^fmt\.Print.*$
YAML
)
    fi

    local skip_paths=""
    if [[ "$GOLANGCI_SKIP_DIR" != "" ]]; then
        skip_paths+="      - $GOLANGCI_SKIP_DIR"$'\n'
    fi
    if [[ "$GOLANGCI_SKIP_FILES" != "" ]]; then
        skip_paths+="      - $GOLANGCI_SKIP_FILES"$'\n'
    fi

    # --- Emit phase: the entire YAML shape is visible in ONE heredoc ---
    cat > "$configFilepath" <<EOF
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
EOF
}

# === Tests phase ===

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

    gotest_packages="./..."
    if [ -n "$GOTEST_PKGS" ];
    then
        gotest_packages="$GOTEST_PKGS"
    fi

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
