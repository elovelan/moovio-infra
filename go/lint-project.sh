#!/usr/bin/env bash
# Callers pass whitespace-separated flag strings (GOTAGS, GOTEST_FLAGS,
# GOBUILD_FLAGS, GOLANGCI_FLAGS, ...) which are intentionally word-split
# when expanded into commands below.
# shellcheck disable=SC2086
set -e

# Variable conventions
#
#   UPPERCASE   Environment provided by the caller (GOTAGS, SKIP_LINTERS,
#               COVER_THRESHOLD, ...). Read-only: the script never reassigns
#               them, so a name always means what the caller set.
#   lowercase   State owned by this script. The environment facts below are
#               filled in once by configure() and read-only afterwards; the
#               test-phase state is set by run_tests. Everything else is local
#               to the function that computes it.

# Pinned tool versions. golangci-lint defaults to the latest release unless
# GOLANGCI_LINT_VERSION is set.
gitleaks_version=8.17.0
golangci_version="${GOLANGCI_LINT_VERSION:-latest}"
sqlvet_version=v1.1.5

# Environment facts, set by configure().
go_version=""          # host Go version, e.g. 1.24.1 (also pinned in the generated golangci config)
uname=""               # lower-cased 'uname -s': linux or darwin (used in release download URLs)
OS_NAME=""             # linux, osx or windows; exported so child processes see it too
org=""                 # GitHub org from the module path: moov-io or moovfinancial
build_tags_flag=""     # "-tags $GOTAGS" for go build/test, or empty
golangci_tags_flag=""  # "--build-tags $GOTAGS" for golangci-lint, or empty
race_flag=""           # "-race" unless disabled by the caller or the target platform

# Test-phase state, set by run_tests and read by run_submodule_tests and
# check_coverage_threshold.
gotest=""              # "go test" or the gotest wrapper when installed
gotest_packages=""     # package pattern under test, GOTEST_PKGS or ./...
coverage_profile=""    # path of the merged coverage profile
covered_statements=0   # coverage percentage (or the sum of per-package percentages under PROFILE_GOTEST)
maximum_coverage=0     # 100 (or 100 per package under PROFILE_GOTEST)

# Files created by this script that must not be left behind in the project,
# even when a check fails and set -e exits early.
generated_files=()

main() {
    mkdir -p ./bin/
    trap cleanup EXIT
    configure

    if [[ "$SKIP_LINTERS" != "" ]]; then
        echo "SKIPPING linters for $OS_NAME"
    else
        echo "running go linters for $OS_NAME"
    fi

    local golangci_default=true
    if [[ "$OS_NAME" == "windows" ]]; then
        golangci_default=false
    fi

    # ONLY_GOLANGCI=yes runs golangci-lint (and its --fix via GOLANGCI_DO_FIX=true) and nothing else.
    if [[ "$ONLY_GOLANGCI" == "yes" ]]; then
        run_check golangci "$golangci_default"
        echo "SKIPPING Go tests from env var"
        return
    fi

    if [[ "$org" == "moov-io" ]]; then
        check_no_moovfinancial_dependencies
    fi
    # Set SKIP_RETRACTED=yes to skip this check, e.g. in test-only CI jobs
    # where the `go list -m -u all` network round-trip is wasted time.
    if [[ "$SKIP_RETRACTED" != "yes" ]]; then
        check_no_retracted_modules
    fi
    if [[ "$SKIP_LINTERS" == "" ]]; then
        build
    fi

    # gitleaks is on by default for moov-io projects (except Windows), opt-in elsewhere.
    local gitleaks_default=true
    if [[ "$OS_NAME" == "windows" || "$org" != "moov-io" ]]; then
        gitleaks_default=false
    fi
    run_check gitleaks "$gitleaks_default"

    # A dedicated govulncheck workflow handles scanning (including weekly
    # scheduled runs); skip here to avoid running twice on PRs.
    local govulncheck_default=true
    if [[ -f ".github/workflows/govulncheck.yml" ]]; then
        govulncheck_default=false
    fi
    run_check govulncheck "$govulncheck_default"

    run_check sqlvet false
    run_check xmlencoderclose false
    run_check nilaway false
    run_check golangci "$golangci_default"

    if [[ "$SKIP_TESTS" == "yes" ]]; then
        echo "SKIPPING Go tests from env var"
        return
    fi

    run_tests
    if [[ "$SKIP_SUBMODULE_TESTS" == "" ]]; then
        run_submodule_tests
    fi
    if [[ "$COVER_THRESHOLD" != "" && "$COVER_THRESHOLD" != "disabled" ]]; then
        check_coverage_threshold
    else
        echo "Skipping code coverage threshold, consider setting COVER_THRESHOLD. (Example: 85.0)"
    fi
    echo "finished running Go tests"
}

# Fill in the "environment facts" declared at the top of the file from the
# host, the module and the caller's environment. Sets nothing else.
configure() {
    go_version=$(go version | grep -Eo '[0-9]\.[0-9]+\.?[0-9]?')
    echo "Detected Go version $go_version"

    uname=$(uname -s | tr '[:upper:]' '[:lower:]')

    # TRAVIS_OS_NAME is the only way to select windows; local dev derives from uname.
    OS_NAME=$TRAVIS_OS_NAME
    if [[ "$OS_NAME" == "" ]]; then
        if [[ "$uname" == "darwin" ]]; then
            OS_NAME=osx
        else
            OS_NAME=linux
        fi
    fi
    export OS_NAME

    org=$(go mod why | head -n1  | awk -F'/' '{print $2}')

    if [[ "$GOTAGS" != "" ]]; then
        build_tags_flag="-tags $GOTAGS"
        golangci_tags_flag="--build-tags $GOTAGS"
    fi

    race_flag='-race'
    if [[ "$CGO_ENABLED" == "0" || "$GOOS" == "js" || "$GOARCH" == "wasm" || "$DISABLE_GORACE" != "" ]]; then
        race_flag=''
    fi
}

# ---------------------------------------------------------------------------
# Dependency checks and build
# ---------------------------------------------------------------------------

# Fail the build if a moov-io (OSS) project depends on moovfinancial code.
check_no_moovfinancial_dependencies() {
    if go list -m all | grep moovfinancial;
    then
        echo "Found github.com/moovfinancial dependencies in OSS. Please remove"
        exit 1
    fi
}

# Verify no retracted module versions are in the build.
check_no_retracted_modules() {
    local retracted_mods skip_modules dep skip skip_mod

    # shellcheck disable=SC2207 # module paths never contain whitespace or globs
    retracted_mods=($(go list -m -u all | grep retracted | cut -f1 -d' '))
    skip_modules=(
        "github.com/moby/sys/user"
    )
    for dep in "${retracted_mods[@]}"
    do
        # Check if the project actually uses this mod
        if go mod why "$dep" | grep -q "module does not need package";
        then
            echo "INFO: $dep is retracted, but not used in this project"
        else
            # Check if the module is in skip_modules
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

# Build the source code (to discover compile errors prior to linting)
build() {
    echo "Building Go source code"
    go build $race_flag $build_tags_flag $GOBUILD_FLAGS ./...
    echo "SUCCESS: Go code built without errors"
}

# ---------------------------------------------------------------------------
# Linters. Each check_<name> function runs unconditionally; run_check decides
# whether to call it.
# ---------------------------------------------------------------------------

# Run check_<name> if should_run allows it. Checks that are on by default
# announce when they have been turned off so the gap is visible in CI logs.
run_check() {
    local name="$1" default="$2"

    if should_run "$name" "$default"; then
        "check_$name"
    elif [[ "$default" == "true" ]]; then
        echo "SKIPPING $name"
    fi
}

# Decide whether the named check runs. It is enabled when its default is
# "true" or when it is listed in EXPERIMENTAL, and always disabled when
# SKIP_LINTERS, SKIP_<NAME> or DISABLE_<NAME> (upper-cased) is set to a
# non-blank value.
should_run() {
    local name="$1" enabled="$2" upper skip_var disable_var

    if [[ "$EXPERIMENTAL" == *"$name"* ]]; then
        enabled=true
    fi
    if [[ "$SKIP_LINTERS" != "" ]]; then
        enabled=false
    fi
    upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')
    skip_var="SKIP_$upper"
    disable_var="DISABLE_$upper"
    if [[ "${!skip_var}" != "" || "${!disable_var}" != "" ]]; then
        enabled=false
    fi

    [[ "$enabled" == "true" ]]
}

# gitleaks (secret scanning, in-progress of a rollout)
check_gitleaks() {
    local dirs dir

    download_tool gitleaks "https://github.com/zricethezav/gitleaks/releases/download/v${gitleaks_version}/gitleaks_${gitleaks_version}_${uname}_x64.tar.gz"

    echo "gitleaks version: $(./bin/gitleaks version)"

    # Find directories and optionally exclude one
    if [ -n "$GITLEAKS_EXCLUDE" ]; then
        # shellcheck disable=SC2207 # directory names are split on whitespace (pre-existing)
        dirs=($(find . -mindepth 1 -type d | sort -u | grep -v ".git" | grep -v "$GITLEAKS_EXCLUDE"))

        for dir in "${dirs[@]}"; do
            echo "Running gitleaks on $dir"
            ./bin/gitleaks detect --no-git --verbose --no-banner --source "$dir"
        done
    else
        ./bin/gitleaks detect --no-git --verbose
    fi

    echo "FINISHED gitleaks check"
}

# govulncheck parses the compiled/used code for known vulnerabilities.
check_govulncheck() {
    local bin

    echo "STARTING govulncheck check"

    # Install the latest govulncheck release
    go install golang.org/x/vuln/cmd/govulncheck@latest
    bin=$(find_go_tool govulncheck)

    if [[ "$bin" != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED govulncheck check"
    else
        echo "Can't find govulncheck..."
    fi
}

check_sqlvet() {
    local sqlvet_os

    # Download only on linux or macOS
    if [[ "$OS_NAME" != "windows" ]]; then
        sqlvet_os="$OS_NAME"
        if [[ "$OS_NAME" == "osx" ]]; then
            sqlvet_os="darwin"
        fi
        download_tool sqlvet "https://github.com/houqp/sqlvet/releases/download/${sqlvet_version}/sqlvet-${sqlvet_version}-${sqlvet_os}-amd64.tar.gz"

        echo "sqlvet version: $(./bin/sqlvet --version)"
        ./bin/sqlvet .
        echo "FINISHED sqlvet check"
    else
        echo "sqlvet is not supported on windows"
    fi
}

check_xmlencoderclose() {
    local bin

    echo "STARTING xmlencoderclose check"

    # Install xmlencoderclose
    go install github.com/adamdecaf/xmlencoderclose@latest
    bin=$(find_go_tool xmlencoderclose)

    if [[ "$bin" != "" ]];
    then
        "$bin" -test ./...
        echo "FINISHED xmlencoderclose check"
    else
        echo "Can't find xmlencoderclose..."
    fi
}

# nilaway can deliver false positives so it's not currently allowed inside of
# golangci-lint, however this linter is useful so we offer it.
#
# https://github.com/golangci/golangci-lint/issues/4045
check_nilaway() {
    local bin nilaway_memory_limit nilaway_packages

    echo "STARTING nilaway check"

    # Install nilaway
    go install go.uber.org/nilaway/cmd/nilaway@latest
    bin=$(find_go_tool nilaway)

    nilaway_memory_limit="${NILAWAY_MEMORY_LIMIT:-7168MiB}"
    nilaway_packages="${NILAWAY_PACKAGES:-./...}"

    if [[ "$bin" != "" ]];
    then
        echo "Running nilaway with GOMEMLIMIT=$nilaway_memory_limit in $nilaway_packages"
        # Export in a subshell rather than prefixing the command: a VAR=value
        # prefix would turn bash's 'time' keyword into a lookup for an external
        # time(1) binary, which not every machine has.
        (export GOMEMLIMIT="$nilaway_memory_limit"; time "$bin" -test=false "$nilaway_packages")
        echo "FINISHED nilaway check"
    fi
}

# Download a golangci-lint release binary into ./bin/golangci-lint.
# Fetched directly from GitHub releases instead of the upstream install.sh,
# whose checksum verification breaks on releases that include sbom assets.
# If ./bin/golangci-lint already exists and matches the requested version it is
# reused, so callers can pre-place their own build (for example one made with
# 'golangci-lint custom' to link in module plugins).
install_golangci_lint() {
    local version="$1" arch name release_url sha_cmd

    # Resolve "latest" to a tag via the GitHub releases redirect.
    if [[ "$version" == "latest" ]]; then
        version=$(curl -sSfL -o /dev/null -w '%{url_effective}' \
            https://github.com/golangci/golangci-lint/releases/latest \
            | grep -Eo 'v[0-9][0-9.]*$')
    fi

    # Reuse a pre-existing binary of the requested version instead of
    # downloading the release build. A custom build reports its version with
    # a leading 'v' and a build suffix (e.g. v2.13.1-custom-gcl-<hash>), so
    # the match allows both forms. The trailing character guard keeps v2.13.1
    # from matching a v2.13.10 binary.
    if [[ -x "./bin/golangci-lint" ]] &&
        ./bin/golangci-lint version 2>/dev/null | grep -qE "version v?${version#v}($|[^0-9.])"; then
        echo "Reusing existing ./bin/golangci-lint for ${version}"
        return
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
    esac
    name="golangci-lint-${version#v}-${uname}-${arch}"
    release_url="https://github.com/golangci/golangci-lint/releases/download/${version}"

    wget -q -O "./bin/${name}.tar.gz" "${release_url}/${name}.tar.gz"
    wget -q -O ./bin/golangci-lint-checksums.txt "${release_url}/golangci-lint-${version#v}-checksums.txt"

    # The anchored grep keeps the sbom checksum line from matching.
    sha_cmd="sha256sum"
    command -v sha256sum >/dev/null 2>&1 || sha_cmd="shasum -a 256"
    (cd ./bin && grep " ${name}.tar.gz\$" golangci-lint-checksums.txt | $sha_cmd -c -)

    tar -xzf "./bin/${name}.tar.gz" -C ./bin --strip-components=1 "${name}/golangci-lint"
    rm -f "./bin/${name}.tar.gz" ./bin/golangci-lint-checksums.txt
}

# Run golangci-lint, either with the project's committed .golangci.yml or with
# a config generated from the GOLANGCI_* / STRICT_GOLANGCI_LINTERS options.
check_golangci() {
    local fix_flag="" strict enabled disabled config

    echo "STARTING golangci-lint checks"

    install_golangci_lint "$golangci_version"

    ./bin/golangci-lint version

    if [[ "$GOLANGCI_DO_FIX" == "true" ]]; then
        fix_flag="--fix"
    fi

    # If the project has a committed .golangci.yml, use it directly and skip
    # dynamic config generation — the file controls all linter settings.
    if [[ -f ".golangci.yml" ]]; then
        ./bin/golangci-lint $GOLANGCI_FLAGS run $fix_flag --verbose --timeout=5m $golangci_tags_flag
        echo "FINISHED golangci-lint checks"
        return
    fi

    # Strict linters default on for moov-io projects; STRICT_GOLANGCI_LINTERS overrides either way.
    strict="$STRICT_GOLANGCI_LINTERS"
    if [[ "$org" == "moov-io" ]];
    then
        strict="${STRICT_GOLANGCI_LINTERS:-yes}"
    fi

    # Build the linters list
    # TODO(adam): re-add unused when they fix some bugs
    enabled="asciicheck,bidichk,bodyclose,durationcheck,exhaustive,fatcontext,forcetypeassert,gosec,misspell,nolintlint,protogetter,rowserrcheck,sqlclosecheck,testifylint,wastedassign"

    if [ -n "$GOLANGCI_LINTERS" ]; then
        # Append additional linters
        enabled="$enabled,$GOLANGCI_LINTERS"
    fi

    # If SET_GOLANGCI_LINTERS is set, it completely replaces the current set
    if [ -n "$SET_GOLANGCI_LINTERS" ]; then
        enabled="$SET_GOLANGCI_LINTERS"
    fi

    if [[ "$strict" == "yes" ]]; then
        enabled="$enabled,dupword,exptostd,gocheckcompilerdirectives,iface,mirror,nilnesserr,sloglint,testableexamples,usetesting"
    fi

    # Add forbidigo unless skipped
    if [[ "$SKIP_FORBIDIGO" != "yes" ]];
    then
        enabled="$enabled,forbidigo"
    fi

    disabled="depguard,errcheck"
    if [[ "$DISABLED_GOLANGCI_LINTERS" != "" ]]; then
        disabled="$disabled,$DISABLED_GOLANGCI_LINTERS"
    fi

    # Create config file in the project directory so golangci-lint v2
    # resolves file paths relative to the project root, not the config location.
    config=".golangci-lint-generated.yml"
    generated_files+=("$config")
    write_golangci_config "$config"

    # --enable and --disable come from env vars rather than the config
    ./bin/golangci-lint $GOLANGCI_FLAGS run --config="$config" $fix_flag "--enable=$enabled" "--disable=$disabled" --verbose --timeout=5m $golangci_tags_flag

    # Cleanup generated config
    rm -f "$config"

    echo "FINISHED golangci-lint checks"
}

# Write the generated golangci-lint config to $1.
write_golangci_config() {
    local config="$1"

    cat <<EOF > "$config"
version: "2"
run:
  tests: false
  go: "$go_version"
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
        - pkg: ^math/rand$
        - pkg: ^plugin$
        - pattern: ^panic$
        - pattern: .*\.Call.*$
          pkg: reflect
EOF
    # Add Moov Financial specific overrides
    if [[ "$org" == "moovfinancial" ]];
    then
        # Prevent UUID direct inspections (including ozzo validators) in
        # favor of moovfinancial/go-libs/mvalidation
        cat <<'EOF' >> "$config"
        - pattern: .*\.IsUUID
          pkg: github.com/moovfinancial/go-libs/mvalidation
          msg: Update to moovfinancial/go-libs/mvalidation IsID[(id type goes here)]
        - pattern: is.UUID[\d]{0,}
          pkg: github.com/go-ozzo/ozzo-validation/v4/is
          msg: Update to moovfinancial/go-libs/mvalidation IsID[(id type goes here)]
EOF
    fi

    # Add some specific overrides
    if [[ "$GOLANGCI_ALLOW_PRINT" != "yes" ]];
    then
        echo "        - pattern: ^fmt\.Print.*$" >> "$config"
    fi

    # Enable staticcheck with auto-fixable rules only: all S1* (simplifications)
    # and a curated subset of QF* (quickfixes). SA* and ST* require manual fixes
    # but should be considered to be turned on at some point...
    cat <<EOF >> "$config"
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
EOF
    if [[ "$GOLANGCI_SKIP_DIR" != "" ]];
    then
        echo "      - $GOLANGCI_SKIP_DIR" >> "$config"
    fi
    if [[ "$GOLANGCI_SKIP_FILES" != "" ]];
    then
        echo "      - $GOLANGCI_SKIP_FILES" >> "$config"
    fi

    # forbidigo requires broader path exclusions than other linters; use
    # linter-specific exclusion rules (supported since golangci-lint v2).
    cat <<EOF >> "$config"
    rules:
      - linters: [forbidigo]
        path: '^(main\.go|cmd/|docs/|examples/|scripts/)'
EOF
}

# ---------------------------------------------------------------------------
# Tests and coverage
# ---------------------------------------------------------------------------

# Run 'go test' for the module. Sets the test-phase state declared at the top
# of the file.
run_tests() {
    local flags parallel modname pkgs pkg dir coverage

    if [[ "$VENDOR_FOR_TESTS" == "yes" ]];
    then
        echo "Vendoring deps before running tests"
        go mod tidy
        go mod vendor
    fi

    # Clear cross-compilation targets so the test binaries run on this host.
    # This is the one place the caller's environment is deliberately changed.
    GOARCH=''
    GOOS=''

    gotest_packages="./..."
    if [ -n "$GOTEST_PKGS" ];
    then
        gotest_packages="$GOTEST_PKGS"
    fi

    covered_statements=0
    maximum_coverage=0
    coverage_profile=$(mktemp -d)"/coverage.txt"

    # Find "gotest" or "go test"
    gotest=$(command -v go)" test"
    if command -v gotest > /dev/null 2>&1;
    then
        gotest=$(command -v gotest)
    fi

    echo "======"

    if [[ "$OS_NAME" == "windows" ]]; then
        # Just run short tests on Windows as we don't have Docker support in tests worked out for the database tests
        echo "Running $gotest on $OS_NAME with extra flags: $GOTEST_FLAGS"
        $gotest $build_tags_flag "$gotest_packages" "$race_flag" -short -coverprofile="$coverage_profile" -covermode=atomic $GOTEST_FLAGS
        return
    fi

    # Extra 'go test' flags: the caller's GOTEST_FLAGS verbatim, otherwise the
    # EXPERIMENTAL shuffle/parallel defaults.
    flags="$GOTEST_FLAGS"
    if [[ "$flags" == "" ]]; then
        if [[ "$EXPERIMENTAL" == *"shuffle"* ]]; then
            flags="$flags -test.shuffle=on"
        fi
        if [[ "$EXPERIMENTAL" == *"parallel"* || "$GOTEST_PARALLEL" != "" ]]; then
            parallel="${GOTEST_PARALLEL:-8}"
            flags="$flags -parallel=$parallel"
        fi
    fi

    if [[ "$COVER_THRESHOLD" == "disabled" ]]; then
        echo "Running $gotest on $OS_NAME with coverage disabled and extra flags: $flags"
        $gotest $build_tags_flag "$gotest_packages" "$race_flag" -count 1 $flags
        return
    fi

    if [[ "$PROFILE_GOTEST" != "yes" ]]; then
        echo "Running $gotest on $OS_NAME with coverage and extra flags: $flags"
        $gotest $build_tags_flag "$gotest_packages" "$race_flag" -coverprofile="$coverage_profile" -covermode=atomic -count 1 $flags
        return
    fi

    # PROFILE_GOTEST=yes: test package by package, writing cpu/mem profiles and
    # a coverage profile next to each one, and average the coverage.
    echo "Running $gotest on $OS_NAME package by package and extra flags: $flags"
    modname=$(go list .)
    # shellcheck disable=SC2207 # package paths never contain whitespace or globs
    pkgs=($(go list ./...))
    for pkg in "${pkgs[@]}"
    do
        dir=${pkg#"$modname"/}
        if [[ "$pkg" == "$dir" ]];
        then
            dir="."
        fi

        $gotest $build_tags_flag "$pkg" "$race_flag" \
           -covermode=atomic \
           -coverprofile="$dir"/coverage.txt \
           -test.cpuprofile="$dir"/cpu.out \
           -test.memprofile="$dir"/mem.out \
           -count 1 $flags

        coverage=$(go tool cover -func="$dir"/coverage.txt | grep total | grep -Eo '[0-9]+\.[0-9]+')
        if (( $(echo "$coverage > 0" | bc -l) ));
        then
            covered_statements=$(echo "$covered_statements" + "$coverage" | bc)
            maximum_coverage=$((maximum_coverage+100))
        fi
    done
}

# Run Go tests in every nested module (directories with their own go.mod).
run_submodule_tests() {
    local submodules mod_file dir

    submodules=$(find . -mindepth 2 -name go.mod)
    if [ -n "$submodules" ]; then
        echo "Testing Submodules..."

        for mod_file in $submodules; do
            dir=$(dirname "$mod_file")
            (cd "$dir" && $gotest $build_tags_flag "$gotest_packages" "$race_flag")
        done
    fi
}

# Fail if statement coverage is below COVER_THRESHOLD.
check_coverage_threshold() {
    local avgCoverage

    if [[ -f "$coverage_profile" && "$PROFILE_GOTEST" != "yes" ]];
    then
        # Ignore test directories in coverage analysis
        grep -v -E "/client/" < "$coverage_profile" | grep -v -E "/pkg*/*test" | grep -v -E "/internal*/*test" | grep -v -E "/examples/" | grep -v -E "/gen/"  > coverage.txt
        covered_statements=$(go tool cover -func=coverage.txt | grep -E '^total:' | grep -Eo '[0-9]+\.[0-9]+')
        maximum_coverage=100
    fi

    avgCoverage=$(printf "%.1f" "$(echo "($covered_statements / $maximum_coverage)*100" | bc -l)")
    echo "Project has $avgCoverage% statement coverage."

    if (( $(echo "$avgCoverage < $COVER_THRESHOLD" | bc -l) )); then
        echo "ERROR: statement coverage is not sufficient, $COVER_THRESHOLD% is required"
        exit 1
    else
        echo "SUCCESS: project has sufficient statement coverage (over $COVER_THRESHOLD%)"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Remove the generated_files declared at the top of the file (EXIT trap).
cleanup() {
    if [[ ${#generated_files[@]} -gt 0 ]]; then
        rm -f "${generated_files[@]}"
    fi
}

# Download a release tarball containing a single binary named $name and
# place it at ./bin/$name.
download_tool() {
    local name="$1" url="$2"

    wget -q -O "$name.tar.gz" "$url"
    tar xf "$name.tar.gz" "$name"
    mv "$name" "./bin/$name"
    rm -f "$name.tar.gz"
}

# Print the path of a Go tool that was just installed with 'go install': the
# binary in GOBIN (or GOPATH/bin when GOBIN is unset), which is not always on
# PATH, falling back to whatever PATH provides. Prints nothing if the tool
# cannot be found.
find_go_tool() {
    local name="$1" install_dir gopath

    install_dir=$(go env GOBIN)
    if [[ -z "$install_dir" ]]; then
        gopath=$(go env GOPATH)
        install_dir="${gopath%%:*}/bin"
    fi

    if [[ -x "$install_dir/$name" ]]; then
        echo "$install_dir/$name"
    elif command -v "$name" > /dev/null 2>&1; then
        command -v "$name"
    fi
}

main "$@"
