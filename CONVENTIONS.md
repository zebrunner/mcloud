# Conventions

The conventions of the style, the formatting and the tooling of the Zebrunner MCloud repositories:

- [appium](https://github.com/zebrunner/appium)
- [mcloud-android-connector](https://github.com/zebrunner/mcloud-android-connector)
- [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector)
- [mcloud-device](https://github.com/zebrunner/mcloud-device)
- [mcloud-grid](https://github.com/zebrunner/mcloud-grid)
- [mcloud-agent](https://github.com/zebrunner/mcloud-agent)
- [mcloud](https://github.com/zebrunner/mcloud)

Outside of them: [stf](https://github.com/zebrunner/stf), the fork of DeviceFarmer STF, keeps the tooling of upstream (the npm scripts, its own linters, `ZEBRUNNER.md`), its `Makefile` has the targets of [Makefile](#makefile) without the shared block: `help`, `check`, `lint` and `test` over the npm scripts, `build` and `push` of the image. artifacts-uploader (the uploader image) has no conventions.

This file is the same in all of them: a change of a convention is made in every repository, and a new repository starts with a copy of it and of the shared files listed below. Most of the rules are checked by `make lint`; the rest is kept by review. The rules that come from the kind of a project (Java, Ansible) are in [Project rules](#project-rules).

## Contents

- [Repository layout](#repository-layout)
- [Shared files](#shared-files)
- [Checks](#checks)
- [All files](#all-files)
- [Shell scripts](#shell-scripts)
- [Tests](#tests)
- [Dockerfile](#dockerfile)
- [YAML and GitHub Actions](#yaml-and-github-actions)
- [Markdown](#markdown)
- [Makefile](#makefile)
- [License](#license)
- [Git](#git)
- [Project rules](#project-rules)
- [New repository checklist](#new-repository-checklist)

## Repository layout

| Path | What it is |
| --- | --- |
| `Dockerfile` | the image (mcloud-agent and mcloud have none) |
| `entrypoint.sh`, `util/`, `bin/` | the scripts and binaries of the image (`files/` in appium, `src/` in mcloud-grid, `roles/` in mcloud-agent) |
| `tests/lib.sh` | the shared helpers of the test scripts; `tests/project_lib.sh` the helpers of the project |
| `tests/lint.sh` | the static checks of `make lint`; `tests/lint_project.sh` the settings and the checks of the project |
| `tests/<subject>_test.sh` | a test script; the docker ones are listed in `DOCKER_TESTS` of the `Makefile` |
| `tests/requirements-lint.txt` | the pinned linters, installed into `.venv` by `make lint` |
| `Makefile` | the entry point of all the checks: `make help` |
| `.github/workflows/ci.yml` | CI, runs the same checks as `make check` |
| `.github/dependabot.yml` | weekly updates of the actions, the base image and the linters |
| `.editorconfig` | the formatting of every file type, also the style of shfmt |
| `.gitignore`, `.dockerignore` | what git and the docker build context skip |
| `.hadolint.yaml`, `.shellcheckrc`, `.yamllint`, `.pymarkdown` | the configuration of the linters |
| `README.md` | the user documentation of the image |
| `CONVENTIONS.md` | this file |
| `.mcloud-conventions` | the checksums of the shared files, written by the sync of mcloud-conventions |
| `LICENSE` | the Apache License 2.0, see [License](#license) |

## Shared files

The shared files live in [mcloud-conventions](https://github.com/zebrunner/mcloud-conventions) and are changed there only:

- the whole files, the same in every repository: `CONVENTIONS.md`, `LICENSE`, `.shellcheckrc`, `.pymarkdown`, `tests/lib.sh`, `tests/lint.sh`; in the images of shell scripts also the debug mode `util/debug.sh` and the logger `util/logger.sh` (`files/util/` in appium) with their tests `tests/debug_test.sh` and `tests/logger_test.sh`;
- the shared blocks of `.editorconfig`, `.gitignore`, `tests/requirements-lint.txt` and `Makefile`: the lines between `# >>> mcloud-conventions` and `# <<< mcloud-conventions`, the other lines are the project part.

A merge into mcloud-conventions syncs them: its workflow opens (or updates) the pull request `mcloud-conventions-sync` into `develop` of every repository it changes, which is reviewed and merged like any other one. The sync also writes `.mcloud-conventions`, the checksums of the shared files and blocks, and `make lint` fails when one of them is changed in the repository.

The project parts of the shared files:

- `tests/lint.sh`: the settings and the checks of the project are in `tests/lint_project.sh`: `scripts`, `sources`, `generated`, `tab_files`, `dockerfiles`, `tools`, and the function `project_checks` for the project sections, which run after `markdown`;
- `tests/lib.sh`: the helpers of the project tests are in `tests/project_lib.sh`, which `tests/lib.sh` sources when it exists;
- `.github/workflows/ci.yml`: the `lint` job is the reusable workflow `zebrunner/mcloud-conventions/.github/workflows/lint.yml@v1`.

These files have a shared part and a project part kept by review:

| File | Project part |
| --- | --- |
| `.yamllint` | the rules after the shared ones (mcloud-agent) |
| `.dockerignore` | the comment with the paths the image build needs |
| `.hadolint.yaml` | the ignored rules, each one with its reason |
| `.github/workflows/ci.yml` | the jobs after `lint`, the timeouts, the OS matrix |
| `.github/dependabot.yml` | the ecosystems of the project (e.g. `maven`); `docker` only when the base image can be updated without a manual change; `pip` only for the project linters |

## Checks

`make check` runs everything CI runs, every step runs and the failed ones fail the target:

| Target | What it runs | Needs |
| --- | --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, shellcheck, shfmt, the text file checks below, the [license](#license) and the project checks | Python 3 (the tools are installed into `.venv`); on macOS `brew install hadolint` |
| `make test` | the tests without docker and devices, the tools are stubs (see [Project rules](#project-rules)) | bash, the tools of the project |
| `make docker` | the tests of the image: its build, contents and startup | Docker |

- The linters are pinned in `tests/requirements-lint.txt` as `name==version` and updated by Dependabot: the shared ones in mcloud-conventions, the project ones in the repository.
- The `shared files` section checks the shared files and blocks against `.mcloud-conventions`, see [Shared files](#shared-files).
- shellcheck runs with `--severity=info`: every finding is fixed, or disabled on the line above with the reason (see [Shell scripts](#shell-scripts)).
- shfmt takes its style from `.editorconfig`, it has no flags of its own.
- The text file checks of `tests/lint.sh` cover every text file but `.git`, `.venv`, `.idea` and the `generated` paths: no non-ASCII and control characters, no CR, no trailing whitespace, a final newline, tabs only in `tab_files`.
- Every check prints `ok   - <description>` or `FAIL - <description>` with the details, and with `JUNIT_DIR` set it is also written as JUnit XML, which CI shows in the job summary and as annotations.

## All files

- UTF-8 with ASCII characters only: `-`, `...`, `->` instead of the typographic dash, ellipsis or arrow.
- LF line ends, a final newline, no trailing whitespace.
- Indentation by spaces, 2 per level: shell, YAML, JSON, JavaScript; 4 for Java. Tabs only in the `Makefile` (and `pom.xml`).
- The continuation lines of a Dockerfile instruction are indented by 4 spaces (see [Dockerfile](#dockerfile)).
- Generated files (e.g. the Appium patch of appium) are kept byte for byte: `.editorconfig` unsets the formatting for them and `tests/lint.sh` lists them in `generated`.
- The line length is not limited for shell and Markdown, YAML allows 160 characters; keep the code lines readable, around 120 characters.
- The comments are in English, short and to the point: why the code does something, not what it does.

## Shell scripts

### Format

The format is the one of shfmt with `.editorconfig`: 2 spaces, a space after a redirect operator (`> /dev/null`, `2> /dev/null`, `<<< "$x"`), `then` and `do` on the line of `if`, `for` and `while`, a long pipeline is split after `|` or `&&` with the next line indented.

```bash
#!/bin/bash

# wait_for <seconds> <command...>: runs the command every second until it succeeds, fails after the timeout
wait_for() {
  local timeout="$1"
  local start="$SECONDS"
  until "${@:2}" > /dev/null 2>&1; do
    if [[ $((SECONDS - start)) -ge "$timeout" ]]; then
      return 1
    fi
    sleep 1
  done
}
```

### Rules

- The shebang is `#!/bin/bash`, the scripts are bash scripts; `/bin/sh` code is only in the Dockerfile (`RUN`, the shell form of `HEALTHCHECK`).
- Tests with `[[ ]]`, never `[ ]` or `test`; arithmetic with `$(( ))` or `(( ))`.
- Command substitution with `$( )`, never backticks.
- Functions are defined as `name() {`, without the `function` keyword, and use `local` for their variables.
- A function has a comment line above it: `# name <arguments>: what it does or returns`.
- The expansions are quoted (`"$var"`, `"${array[@]}"`) unless word splitting is intended, and then a comment says why.
- Braces when the name is followed by a name character or for an expansion with an operator: `"${name}_suffix"`, `"${VAR:-default}"`, `"${var%%.*}"`; `"$var"` and `"${var}"` are both fine otherwise, keep one of them within a file.
- Another script is sourced with `.` or `source` and a `# shellcheck source=<path relative to the script>` line above it when its path is the one inside the image.
- A shellcheck finding is disabled only on the line above the code with the reason: `# <reason>` and `# shellcheck disable=SC2016`.
- The scripts of the image do not use `set -e`: they check the status of the commands that can fail and exit with the code of [Exit codes](#exit-codes). A tool script of `scripts/` that must stop on the first error starts with `set -euo pipefail`.
- Long scripts are split into sections with a `#### <Section>` comment line.

### Naming

| What | Style | Example |
| --- | --- | --- |
| env vars of the image, exported vars, constants | `UPPER_SNAKE_CASE` | `DEVICE_UDID`, `MIN_ANDROID` |
| variables and functions of the scripts of an image | `lowerCamelCase` | `isConfigValid`, `exitIfAdbServerStopped()` |
| variables and functions of the [host scripts](#host-scripts) | `snake_case` | `create_containers()` |
| variables and functions of `tests/`, `scripts/` | `snake_case` | `check_contains()`, `diff_file` |
| file names | `kebab-case.sh`; `<subject>_test.sh` for the tests | `build-patch.sh`, `entrypoint_test.sh` |

The env vars of tools keep the names of the tools (e.g. `npm_config_cache`).

### Logging

- Every shell script of an image (the exceptions: [Project rules](#project-rules)) sources `util/logger.sh` itself (`. /opt/...` with a `# shellcheck source=` line) and logs with `logger <LEVEL> <message>`: `[dd/mm/YYYY HH:MM:SS] [LEVEL] message`, the levels are `DEBUG`, `INFO`, `WARN`, `ERROR` and `LOGGER_LEVEL` sets the minimum one.
- The messages are sentences: `logger "ERROR" "Device ${DEVICE_UDID} is not connected!"`.
- A script whose stdout is data (e.g. a JSON generator) logs to stderr: `logger "ERROR" "..." >&2`.
- `echo` is for data only: files, pipes, the output of a generator.
- `DEBUG=true`, `DEBUG_TIMEOUT` and `VERBOSE=true` of `util/debug.sh` are supported by every shell entrypoint.

### Host scripts

The scripts that run on the hosts, not in an image (`zebrunner.sh` and `patch/*.sh` of mcloud-agent and mcloud, the script templates of mcloud-agent):

- bash 3.2 compatible: macOS runs them too;
- `snake_case`, see [Naming](#naming);
- the messages are for a person at the terminal (`echo`), not the log lines of `util/logger.sh`.

### Exit codes

The entrypoint of a container started with a restart policy exits with:

- `0` for a problem a restart does not fix (an invalid configuration, a device that needs a person), so the restarts stop;
- `1` for a problem a restart may fix, so the container is started again;
- another code only when a caller expects it (e.g. `101` of appium), documented in the README.

The configuration is validated before anything starts: every invalid variable is logged, then the entrypoint exits with `0`.

## Tests

- A test script sources `tests/lib.sh` first, goes to `$REPO` and ends with `finish`:

  ```bash
  #!/bin/bash
  # Tests of util/logger.sh: the levels and the format.
  source "$(dirname "$0")/lib.sh"
  cd "$REPO" || exit 1

  section "levels"
  check "INFO is the default level" "1" "$(LOGGER_LEVEL= bash -c 'source util/logger.sh; logger DEBUG x; echo $?')"

  finish
  ```

- The checks are grouped by `section`; the assertions are `check`, `check_contains`, `check_not_contains`, `run_check`, or `pass`/`fail` for the rest; `skip_check` records a check that cannot run, `skip` the whole script (`require_cmd`, `require_os`).
- The tools of the image are replaced by stubs (`stub`, `record_stub`, `calls`) in `${WORK}/bin` at the front of `PATH`, so `make test` needs no docker and no device.
- The temporary files go to `$WORK`, removed on exit; a script frees its other resources (containers, ...) in its own `cleanup()`, which replaces the empty one of `tests/lib.sh`: never a new `trap ... EXIT`.
- The docker tests build the image once, `IMAGE` overrides its tag and `REBUILD=true` forces a new build.
- `tests/lib.sh`, `tests/lint.sh`, `util/debug.sh` and `util/logger.sh` run on the macOS system bash 3.2 (no `mapfile`, no associative arrays, no `${var^^}`); a test of a script of the image may need bash 4+ like the image (`brew install bash`).

## Dockerfile

```dockerfile
FROM alpine:3.24.1@sha256:<digest>

# the defaults of the configuration, all of them are documented in README.md
ENV DEVICE_UDID="" \
    POLLING_SEC=5 \
    # Debug mode
    DEBUG=false \
    DEBUG_TIMEOUT=3600 \
    VERBOSE=false

WORKDIR /opt/zebrunner/

# gcompat is needed by the glibc build of the tool
RUN apk add --no-cache \
        bash=5.3.9-r1 gcompat=1.1.0-r4 && \
    wget -q -O /tmp/tool.zip https://example.com/tool-1.2.3.zip && \
    echo "<sha256>  /tmp/tool.zip" > /tmp/tool.sha256 && \
    sha256sum -c /tmp/tool.sha256 && \
    rm -rf /tmp/tool.zip /tmp/tool.sha256

COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ARG VERSION=dev
LABEL org.opencontainers.image.title="Zebrunner MCloud <name>" \
      org.opencontainers.image.description="<one line>" \
      org.opencontainers.image.source="https://github.com/zebrunner/<repository>" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}"

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --retries=3 \
    CMD ["sh", "-c", "<check>"]
```

- Everything is pinned: the base image by version (and digest where Dependabot updates it), the packages by version (`name=version-rN` for apk), the drivers and the npm packages by version, a download by its version and SHA-256 checked with `sha256sum -c`.
- The comments are `#` lines, the instructions are upper case.
- The continuation lines are indented by 4 spaces, the package names of an install command by 8; `&& \` ends a continued line.
- `${VAR}` with braces for the variables in the instructions; an empty default is `""`.
- `ENV` lists every variable of the configuration with its default, grouped by `#` comments; each one is documented in the README.
- `ENTRYPOINT`, `CMD` and `HEALTHCHECK` in the exec form; `sh -c` inside it when an env var is expanded.
- The layers go from the rarely to the often changed ones, the downloads are removed in the `RUN` that made them.
- The OCI labels with `ARG VERSION=dev`, the build passes the version: `--build-arg VERSION=<tag>`; `org.opencontainers.image.licenses="Apache-2.0"` (see [License](#license)).
- A hadolint rule is ignored for one instruction with `# hadolint ignore=<rule>` above it, for the whole file in `.hadolint.yaml`; both with the reason in a comment.
- `.dockerignore` keeps the build context to the files the image needs: `.git`, `.github`, `.idea`, `.venv`, `tests`, `*.md`, `.DS_Store` are excluded everywhere.

## YAML and GitHub Actions

- Every YAML file starts with `---`, 2 spaces, lines up to 160 characters, booleans only `true` and `false`, strings in double quotes when they need quotes (yamllint `--strict` with `.yamllint`).
- A comment is `#` and a space, at least one space after the content.
- The workflow is `.github/workflows/ci.yml`: `push` and `pull_request` on `develop`, `main`, `master` and `workflow_dispatch`; `concurrency` cancels the outdated runs of a pull request; `permissions: contents: read`.
- The `lint` job is the reusable workflow of mcloud-conventions: `uses: zebrunner/mcloud-conventions/.github/workflows/lint.yml@v1` (`with: java-version` for the Maven checks).
- The other jobs are `tests`, `docker` (those that apply, plus the project ones), each with `timeout-minutes` (10 unless the project needs more) and a JUnit report step `mikepenz/action-junit-report` with `annotate_only: true`, `detailed_summary: true`, `require_tests: true`.
- The `tests` job runs the tests of `make test`; the jobs upload their JUnit XML as artifacts (`junit-docker` of the `docker` job).
- A job that pulls from public.ecr.aws logs docker in first with `uses: zebrunner/mcloud-conventions/.github/actions/ecr-public-login@v1` and `permissions: contents: read, id-token: write` of the job: the anonymous pulls are limited to 1 per second per IP of the runners.
- The `actions/*` are referenced by their major version tag, the other actions by the full commit SHA with the version in a comment: `uses: mikepenz/action-junit-report@<sha> # v6.6.0`.
- `.github/dependabot.yml` updates `github-actions`, `docker` and the ecosystem of the project weekly, `pip` (`directory: /tests`) only for the project linters, each with a comment of what it covers.

## Markdown

- pymarkdown with `.pymarkdown`: the line length is not limited, the allowed HTML is `p`, `a`, `img`, `b`, `br`.
- A paragraph or a list item is one line, no hard wraps.
- `-` for the list items, 2 spaces for a nested list.
- Tables with `| --- |` delimiters and spaces around the cell content.
- Fenced code blocks with the language: `bash`, `dockerfile`, `yaml`, `json`.
- The names of variables, files, commands and values are in backticks.
- The README sections, in this order, those that apply:
  1. `# <Title>`: what the image does, its base and platforms
  2. `## Image contents`: the components and their versions
  3. `## Build`
  4. `## Run`
  5. `## Configuration`: a table `| Variable | Default | Description |` with every env var of the Dockerfile
  6. the sections of the project (e.g. `## Startup`, `## Device type`, `## Limitations`, `## Troubleshooting`)
  7. `## Exit codes and health`
  8. `## Development`: the `make` targets and what they check, a link to this file
  9. `## Support`
  10. `## License`: `[Apache License 2.0](LICENSE)`

## Makefile

- The shared block follows the comment of the first line (what `make check` runs): `SHELL := /bin/bash`, `VENV` and its `bin` in `PATH`, `make help` as the default goal (it lists the targets with their `## <description>` comments) and the `.venv/.installed` stamp of `lint`. The project part after it: the variables of the project (`DOCKER_TESTS`, the image), `.PHONY`, the targets.
- The targets are `help`, `check`, `lint`, `test`, `docker`, then the project ones; all of them are `.PHONY`.
- `check` runs `lint`, `test` and `docker` (plus the project targets), every one of them, and fails when one failed.
- In the images of shell scripts `test` runs every `tests/*_test.sh` but the ones of `DOCKER_TESTS`, `docker` runs `DOCKER_TESTS`: a new test script is picked up without a change of the `Makefile`.
- `lint` installs `tests/requirements-lint.txt` into `.venv` once (the stamp `.venv/.installed`).
- The repositories of an image have `build` and `push` after the checks, not run by `check`: `make build VERSION=<tag>` builds `public.ecr.aws/zebrunner/<image>:<tag>` in the local docker (for the platform of the machine, `linux/amd64` for an amd64-only image), `make push VERSION=<tag>` builds the platforms of `PLATFORMS` with `docker buildx` (the builder `mcloud`, docker-container driver) and pushes them. `VERSION` is the tag and `--build-arg VERSION` (`dev` by default, `push` refuses it), `IMAGE_REPO` overrides the repository; both pass `--provenance=false`, as the docker tests. The tests of `make test` check their commands with a docker stub (`tests/make_test.sh`) where it runs the shell tests.
- The recipes are indented with a tab, `SHELL := /bin/bash`.

## License

All the repositories are licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0):

- `LICENSE`: the text of the license, the same file in all the repositories;
- `README.md`: the last section is `## License` with `[Apache License 2.0](LICENSE)`;
- `Dockerfile`: the label `org.opencontainers.image.licenses="Apache-2.0"`.

`make lint` checks the three of them. The code taken from another project keeps its license and notices (e.g. the Appium patch of appium: Apache-2.0). The images also contain the programs of their base images and packages under their own licenses (e.g. GPL for bash and busybox), they are not changed by the license of the repository.

## Git

- `develop` is the branch of the work, the pull requests go into it; `main` gets the releases.
- A branch is named in `kebab-case` by its subject: `fix-issue-288`, `style-conventions`.
- The commit messages are [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <summary>`, the summary in lower case without a final period, the types `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore`.
- A formatting-only commit is listed in `.git-blame-ignore-revs` (GitHub skips it in blame; locally: `git config blame.ignoreRevsFile .git-blame-ignore-revs`).
- `make check` passes before a push.

## Project rules

The rules above are the same for every repository; these ones come from the kind of the project:

| Repository | Kind | Its own rules |
| --- | --- | --- |
| appium, mcloud-android-connector, mcloud-ios-connector, mcloud-device | a docker image of shell scripts | `make test` runs `tests/*_test.sh` but `DOCKER_TESTS`, `make docker` the image tests |
| mcloud-grid | a docker image of a Java 11 application (Maven, Selenium 3 hub) | see [Java](#java) |
| mcloud-agent | Ansible playbooks and the scripts of the farm hosts (Linux and macOS), no image | see [Ansible and host scripts](#ansible-and-host-scripts) |
| mcloud | a docker compose deployment and its [host scripts](#host-scripts), no image | the project checks are described in its README |

### Java

- Java: 4 spaces, the rules of `config/checkstyle/checkstyle.xml` and SpotBugs (`config/spotbugs/exclude.xml`) in `make lint`; `pom.xml` keeps its tabs (`tab_files` of `tests/lint.sh`).
- `make test` is `mvn verify`: the unit and integration tests with the JaCoCo coverage; Maven runs in docker (`tests/mvn.sh`) when the machine has no JDK.
- The entrypoint logs JSON lines with the fields of the `JsonLogFormatter` of the hub, so the logs of the container stay one format: it does not use `util/logger.sh`.

### Ansible and host scripts

- The playbooks: `ansible-lint --strict` and `ansible-playbook --syntax-check`; `.yamllint` adds the rules ansible-lint needs and the `*.yml.original` files.
- The templates of the scripts (`zebrunner-farm`, `zebrunner-device-listener`) are rendered with the example settings, then checked like the other scripts (`render`, `render_farm` of `tests/project_lib.sh`).
- `zebrunner.sh` and the templates run on the farm hosts: see [Host scripts](#host-scripts).
- Python (the test fakes): ruff (`ruff.toml`).
- The tests run on Linux and macOS (the CI matrix); `make docker` runs the checks in the Linux image of `tests/Dockerfile`.

## New repository checklist

1. Create `.editorconfig`, `.gitignore`, `tests/requirements-lint.txt` and `Makefile` with the markers of the shared block and the project part.
2. Add the repository to `sync/targets.yml` of mcloud-conventions: its sync brings the [shared files](#shared-files) and `.mcloud-conventions`.
3. Set the project parts: `tests/lint_project.sh`, `.dockerignore` comment, `.hadolint.yaml`, `DOCKER_TESTS`, the `lint` job of the reusable workflow and the other jobs.
4. Write `tests/<subject>_test.sh` for the scripts of the image and `tests/image_test.sh` for the image.
5. Write the README with the sections above.
6. `make check`.
