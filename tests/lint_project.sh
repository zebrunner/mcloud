#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud.

scripts=(zebrunner.sh patch/*.sh tests/*.sh tests/e2e/*.sh)
# the static files of the Selenium grid console served by stf-proxy
generated=(configuration/stf-proxy/grid)
# no image
dockerfiles=()

# project_checks: docker-compose.yml with the settings of the *.original files
project_checks() {
  section "compose"
  check "every image is pinned by a TAG_* of .env.original" "" \
    "$(grep -E '^[[:space:]]*image:' docker-compose.yml | grep -vE ':\$\{TAG_[A-Z_]+\}"?$')"
  local tag
  while read -r tag; do
    check_contains "${tag} is set in .env.original" "${tag}=" "$(grep -E "^${tag}=.+" .env.original)"
    check "the default of ${tag} in README.md is the one of .env.original" \
      "| \`${tag}\` | \`$(sed -n "s/^${tag}=//p" .env.original)\` |" \
      "$(grep -oE "^\| \`${tag}\` \| \`[^\`]*\` \|" README.md)"
  done < <(grep -oE 'TAG_[A-Z_]+' docker-compose.yml | sort -u)
  if docker compose version > /dev/null 2>&1; then
    run_check "docker compose config with .env.original and variables.env.original" compose_config
  else
    skip_check "docker compose config" "requires docker compose"
  fi
}
