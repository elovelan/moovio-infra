# Go project check script

`lint-project.sh` is configured through environment variables. Unless a specific
value is named below, "set" means any non-empty value.

## Overall execution

- `ONLY_GOLANGCI=yes`: Skip the dependency policy check, retracted-module check,
  source build, standalone tools, and tests. Only golangci-lint remains eligible
  to run; `SKIP_LINTERS` and `SKIP_GOLANGCI` can still disable it.
- `SKIP_LINTERS`: Skip the source build, golangci-lint, and all standalone
  linters/scanners. It does not skip module checks or tests.
- `SKIP_RETRACTED=yes`: Skip checking used dependencies for retracted versions.
- `EXPERIMENTAL`: String containing experimental feature names. Recognized names
  are `gitleaks`, `sqlvet`, `xmlencoderclose`, `nilaway`, `shuffle`, and
  `parallel`. The script uses substring matching; a comma-separated value is
  conventional. `govulncheck` is not experimental and runs by default.
- `TRAVIS_OS_NAME`: Override platform detection. The script otherwise derives
  `linux` or `osx` from `uname`; `windows` selects its Windows-specific paths.

## Build settings

- `GOTAGS`: Build tags passed to `go build`, golangci-lint, and all test runs.
- `GOBUILD_FLAGS`: Additional shell-split flags passed only to `go build`.
- `DISABLE_GORACE`: Omit the default `-race` flag from builds and tests.
  `CGO_ENABLED=0`, `GOOS=js`, or `GOARCH=wasm` also omits it. `GOOS` and
  `GOARCH` affect the initial build but are cleared before tests.

## Standalone tools

### gitleaks

gitleaks runs by default for non-Windows `moov-io` modules. The `gitleaks`
experimental name can enable it otherwise; the disable controls take precedence.

- `DISABLE_GITLEAKS`: Skip gitleaks.
- `GITLEAKS_EXCLUDE`: Regular expression passed to `grep -v` to remove matching
  directory paths. When set, the remaining directories are scanned separately.

### govulncheck

govulncheck runs by default, except when a dedicated
`.github/workflows/govulncheck.yml` exists.

- `DISABLE_GOVULNCHECK`: Skip govulncheck.

### sqlvet

sqlvet runs only when `EXPERIMENTAL` contains `sqlvet`. It has no tool-specific
environment options and is unsupported on Windows.

### xmlencoderclose

xmlencoderclose runs only when `EXPERIMENTAL` contains `xmlencoderclose`.

- `DISABLE_XMLENCODERCLOSE`: Skip xmlencoderclose.

### nilaway

nilaway runs only when `EXPERIMENTAL` contains `nilaway`.

- `DISABLE_NILAWAY`: Skip nilaway.
- `NILAWAY_MEMORY_LIMIT`: Set nilaway's `GOMEMLIMIT`. Defaults to `7168MiB`.
- `NILAWAY_PACKAGES`: Package selector passed to nilaway. Defaults to `./...`.

## golangci-lint

- `SKIP_GOLANGCI`: Skip golangci-lint.
- `GOLANGCI_LINT_VERSION`: Version to install or reuse. Defaults to `latest`.
- `GOLANGCI_FLAGS`: Additional shell-split arguments inserted before the `run`
  subcommand.
- `GOLANGCI_DO_FIX=true`: Pass `--fix`.

When the project contains `.golangci.yml`, that file controls linter settings.
The version, extra flags, fix flag, and `GOTAGS` still apply, but the
generated-config options below do not.

Without `.golangci.yml`, the script generates a config and applies these options
in order:

- `GOLANGCI_LINTERS`: Comma-separated linters appended to the default set.
- `SET_GOLANGCI_LINTERS`: Comma-separated linters replacing the set assembled so
  far. Strict linters and forbidigo are processed afterward and may still be
  appended.
- `STRICT_GOLANGCI_LINTERS=yes`: Append the strict linter set. This defaults to
  `yes` for `moov-io` modules; use another non-empty value such as `no` to
  disable it there.
- `SKIP_FORBIDIGO=yes`: Do not append forbidigo.
- `GOLANGCI_ALLOW_PRINT=yes`: Do not add the forbidigo rule that rejects
  `fmt.Print*`.
- `DISABLED_GOLANGCI_LINTERS`: Comma-separated linters appended to the disabled
  set. `depguard` and `errcheck` are always disabled by the generated config.
- `GOLANGCI_SKIP_DIR`: Add one directory/path expression to the generated
  exclusions.
- `GOLANGCI_SKIP_FILES`: Add one file/path expression to the generated
  exclusions.

## Tests

- `SKIP_TESTS=yes`: Skip all tests.
- `VENDOR_FOR_TESTS=yes`: Run `go mod tidy` and `go mod vendor` before tests.
- `GOTEST_PKGS`: Package selector passed to the primary and submodule test
  commands. Defaults to `./...`.
- `GOTEST_FLAGS`: Additional shell-split test flags. If non-empty, it takes
  precedence over the automatic `shuffle` and `parallel` experimental flags.
- `GOTEST_PARALLEL`: Add `-parallel=N` when `GOTEST_FLAGS` is empty. The
  `parallel` experiment also enables this and defaults `N` to `8`.
- `COVER_THRESHOLD`: Minimum statement coverage percentage required, for
  example `85.0`. Empty means no threshold; `disabled` runs tests without
  coverage collection on non-Windows platforms.
- `PROFILE_GOTEST=yes`: With coverage enabled, test each package separately and
  write `coverage.txt`, `cpu.out`, and `mem.out` in each package directory.
- `SKIP_SUBMODULE_TESTS`: Skip tests in nested modules.
