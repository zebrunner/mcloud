#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud.

scripts=(zebrunner.sh patch/*.sh configuration/adb-relay/*.sh configuration/mdm/*.sh tests/*.sh tests/e2e/*.sh)
# the static files of the Selenium grid console served by stf-proxy
generated=(configuration/stf-proxy/grid)
# no image
dockerfiles=()
tools=(ruff)

# project_checks: Python, docker-compose.yml with the settings of the *.original files
project_checks() {
  section "python"
  run_check "ruff check" ruff check --no-cache .
  run_check "ruff format" ruff format --check --no-cache .

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
    run_check "docker compose config with the profile adb-relay" compose_config --profile adb-relay
    run_check "docker compose config with the profile mdm" compose_config --profile mdm
    local networks
    networks="$(compose_networks)"
    check "the MDM services are not in infra, the network of the containers of the devices" "mcloud-mdm mdm
mcloud-mdm-hmdm mdm,mdm-db
mcloud-mdm-hmdm-init mdm-db
mcloud-mdm-mqtt mdm
mcloud-mdm-mysql mdm-db
mcloud-mdm-nanohub mdm,mdm-db
mcloud-mdm-postgres mdm-db" "$(grep '^mcloud-mdm' <<< "$networks")"
    check "stf-proxy and stf-api reach the MDM" "stf-api default,mdm
stf-proxy default,mdm" "$(grep -E '^stf-(proxy|api) ' <<< "$networks")"
    check "the token of the admin, the secret of the grid and of LDAP reach no STF unit but the sign-in" \
      "stf-auth LDAP_BIND_CREDENTIALS" "$(compose_secrets)"
    check "every MDM service has an env file of its own, none gets mdm.env" "" \
      "$(grep -n 'path: mdm.env' docker-compose.yml)"
    check "the databases of the MDM have no internet" "true" \
      "$(grep -A3 '^  mdm-db:' docker-compose.yml | sed -n 's/^ *internal: //p')"
  else
    skip_check "docker compose config" "requires docker compose"
  fi
}
