#!/bin/bash
# Static checks of the project files, every linter run is a check (also in JUnit XML with JUNIT_DIR);
# the tools: pip install -r tests/requirements-lint.txt (hadolint on macOS: brew install hadolint).
# The same file in all the MCloud repositories, synced from zebrunner/mcloud-conventions (CONVENTIONS.md):
# the settings and the checks of the project are in tests/lint_project.sh.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# The settings of the project, tests/lint_project.sh changes them
# the shell scripts: bash -n, shellcheck and the rules of CONVENTIONS.md
scripts=()
# the scripts formatted by shfmt, the scripts when it is empty (e.g. templates that are checked after rendering)
sources=()
# the generated files kept byte for byte and the build output: no text file checks
generated=()
# the files indented with tabs
tab_files=(Makefile)
# the Dockerfiles of hadolint
dockerfiles=(Dockerfile)
# the tools of the project checks
tools=()
# the checksums of the shared files written by the sync of mcloud-conventions, empty in mcloud-conventions itself
manifest=.mcloud-conventions

# project_checks: the sections of the project, after markdown; they may add rendered scripts to scripts
# (the default, tests/lint_project.sh usually redefines it)
# shellcheck disable=SC2329
project_checks() {
  :
}

# shellcheck source=lint_project.sh
source tests/lint_project.sh

# sha256: the SHA-256 of stdin
sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum | cut -d ' ' -f 1
  else
    shasum -a 256 | cut -d ' ' -f 1
  fi
}

# shared_sum <path>[#block]: the SHA-256 of a shared file, or of the shared block of a file (the marker lines included)
shared_sum() {
  local file="${1%#block}"
  [[ -f "$file" ]] || return 0
  if [[ "$1" == *"#block" ]]; then
    sed -n '/^# >>> mcloud-conventions/,/^# <<< mcloud-conventions/p' "$file" | sha256
  else
    sha256 < "$file"
  fi
}

missing=""
for tool in actionlint hadolint pymarkdown shellcheck shfmt yamllint "${tools[@]}"; do
  command -v "$tool" > /dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  fail "lint tools are installed" "missing:${missing}" \
    "missing tools:${missing} (pip install -r tests/requirements-lint.txt, hadolint on macOS: brew install hadolint)"
  finish
fi

section "yaml"
run_check "yamllint" yamllint --strict .

section "GitHub workflows"
# the files are listed: actionlint looks for the project by .git otherwise, and the sources may come without it
run_check "actionlint" actionlint .github/workflows/*.yml

section "Dockerfile"
for dockerfile in "${dockerfiles[@]}"; do
  run_check "hadolint ${dockerfile}" hadolint "$dockerfile"
done

section "markdown"
run_check "pymarkdown" pymarkdown scan ./*.md

section "README"
if [[ -f Dockerfile ]]; then
  # every env var of the image is documented
  env_vars="$(sed -n -E 's/^(ENV)?[[:space:]]+([A-Z][A-Z0-9_]*)=.*/\2/p; s/^ENV ([A-Z][A-Z0-9_]*)=.*/\1/p' Dockerfile | sort -u)"
  check "README documents every env var of the Dockerfile" "" \
    "$(for var in $env_vars; do grep -qF "\`${var}\`" README.md || echo "${var} is missing in README.md"; done)"
  check_contains "the image is labeled Apache-2.0" 'org.opencontainers.image.licenses="Apache-2.0"' "$(cat Dockerfile)"
fi
# the license of CONVENTIONS.md: LICENSE and the README section
check_contains "LICENSE is the Apache License 2.0" "Apache License" "$(head -3 LICENSE 2> /dev/null)"
check_contains "README links LICENSE" "[Apache License 2.0](LICENSE)" "$(cat README.md)"

project_checks

section "shell"
[[ ${#sources[@]} -gt 0 ]] || sources=("${scripts[@]}")
for script in "${scripts[@]}"; do
  run_check "bash -n ${script#"${WORK}/"}" bash -n "$script"
done
run_check "shellcheck" shellcheck --severity=info "${scripts[@]}"
# style of .editorconfig
run_check "shfmt" shfmt -d "${sources[@]}"
# the rules of CONVENTIONS.md that shfmt and shellcheck do not check, the comment lines are skipped
check "tests use [[ ]] only" "" \
  "$(grep -nE '(^|[[:space:];&|(!])\[[[:space:]]' "${scripts[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
check "functions are defined without the function keyword" "" \
  "$(grep -nE '^[[:space:]]*function[[:space:]]' "${scripts[@]}")"

section "shared files"
# the shared files are changed in zebrunner/mcloud-conventions, its sync brings them here with their checksums
if [[ -z "$manifest" ]]; then
  pass "the shared files are the sources of mcloud-conventions"
elif [[ ! -f "$manifest" ]]; then
  fail "${manifest} lists the shared files" "${manifest} is missing" "the sync of zebrunner/mcloud-conventions writes it"
else
  while read -r sum path; do
    [[ -z "$sum" || "$sum" == "#"* ]] && continue
    if [[ "$(shared_sum "$path")" == "$sum" ]]; then
      pass "${path} is the one of mcloud-conventions"
    else
      fail "${path} is the one of mcloud-conventions" "${path} is changed here" \
        "a shared file is changed in https://github.com/zebrunner/mcloud-conventions, its sync opens a pull request here"
    fi
  done < "$manifest"
fi

section "text files"
# every text file of the project but the generated ones
prune=(-name .git -o -name .venv -o -name .idea)
for path in "${generated[@]}"; do
  prune+=(-o -path "./${path}")
done
text_files=()
while IFS= read -r file; do
  grep -Iq '' "$file" 2> /dev/null && text_files+=("$file")
done < <(find . \( "${prune[@]}" \) -prune -o -type f -print | sort)
check "ASCII characters only" "" "$(LC_ALL=C grep -n '[^[:print:][:space:]]' "${text_files[@]}")"
check "LF line ends" "" "$(grep -l $'\r' "${text_files[@]}")"
check "no trailing whitespace" "" "$(grep -nE '[[:blank:]]+$' "${text_files[@]}")"
check "a final newline" "" "$(for file in "${text_files[@]}"; do [[ -z "$(tail -c 1 "$file")" ]] || echo "$file"; done)"
tabbed="$(grep -l $'\t' "${text_files[@]}")"
for file in "${tab_files[@]}"; do
  tabbed="$(grep -vxF "./${file}" <<< "$tabbed")"
done
check "tabs only in ${tab_files[*]}" "" "$tabbed"

[[ "$FAILED" -eq 0 ]] && echo "lint: ok"
finish
