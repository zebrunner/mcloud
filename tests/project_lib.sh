#!/bin/bash
# The helpers of the mcloud tests, sourced by tests/lib.sh (CONVENTIONS.md): a copy of the repository and its compose.
# Keep it compatible with the macOS system bash 3.2.

# copy_repo <destination>: the files of the repository without .git and the local settings of a deployment
copy_repo() {
  mkdir -p "$1"
  (cd "$REPO" && tar --exclude=.git --exclude=.venv --exclude=.idea -cf - .) | (cd "$1" && tar -xf -)
  (cd "$1" && rm -f .env variables.env .disabled backup/settings.env configuration/stf-proxy/nginx.conf \
    configuration/stf-proxy/ssl/ssl.crt configuration/stf-proxy/ssl/ssl.key configuration/stf-proxy/htpasswd/mcloud.htpasswd &&
    find . -name '*.bak' -delete)
}

# compose_config: `docker compose config` of docker-compose.yml with the settings of the *.original files;
# a variable that is not set fails it too
compose_config() {
  local dir="${WORK}/compose"
  mkdir -p "$dir"
  cp "${REPO}/docker-compose.yml" "$dir/"
  cp "${REPO}/.env.original" "${dir}/.env"
  cp "${REPO}/variables.env.original" "${dir}/variables.env"
  local output
  output="$(cd "$dir" && docker compose config --quiet 2>&1)" || {
    echo "$output"
    return 1
  }
  if [[ -n "$output" ]]; then
    echo "$output"
    return 1
  fi
}
