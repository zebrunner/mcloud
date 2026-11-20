#!/bin/bash
# The helpers of the mcloud tests, sourced by tests/lib.sh (CONVENTIONS.md): a copy of the repository and its compose.
# Keep it compatible with the macOS system bash 3.2.

# copy_repo <destination>: the files of the repository without .git and the local settings of a deployment
copy_repo() {
  mkdir -p "$1"
  (cd "$REPO" && tar --exclude=.git --exclude=.venv --exclude=.idea -cf - .) | (cd "$1" && tar -xf -)
  (cd "$1" && rm -f .env variables.env .disabled backup/settings.env configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.previous configuration/stf-proxy/nginx.conf.sha256 \
    configuration/adb-relay/stf-token \
    configuration/stf-proxy/ssl/ssl.crt configuration/stf-proxy/ssl/ssl.key configuration/stf-proxy/htpasswd/mcloud.htpasswd grid.env \
    configuration/stf-proxy/grid-auth.conf mdm.env configuration/stf-proxy/mdm/*.conf configuration/mdm/mqtt.conf \
    configuration/mdm/android/*.apk &&
    find . -name '*.bak' -delete)
}

# compose_config [<docker compose options>...]: `docker compose config` of docker-compose.yml with the settings of the
# *.original files (e.g. `--profile adb-relay`); a variable that is not set fails it too
compose_config() {
  local dir="${WORK}/compose"
  mkdir -p "$dir"
  cp "${REPO}/docker-compose.yml" "$dir/"
  cp "${REPO}/.env.original" "${dir}/.env"
  cp "${REPO}/variables.env.original" "${dir}/variables.env"
  local output
  output="$(cd "$dir" && docker compose "$@" config --quiet 2>&1)" || {
    echo "$output"
    return 1
  }
  if [[ -n "$output" ]]; then
    echo "$output"
    return 1
  fi
}

# unwrap: stdin with the text of every callout, status and fix of patch/ui.sh (ASCII, without colors, COLUMNS=80) on one
# line, the way zebrunner.sh wrote them before the wrapping: the checks of the messages do not depend on the wrapping
# (patch/ui.sh wraps at the spaces only, a longer word stays whole); the title of a callout stays on its own line
unwrap() {
  awk '
    mode == "callout" && /^  \| / {
      text = (text == "" ? $0 : text " " substr($0, 5))
      next
    }
    mode == "status" && /^        [^ ]/ || mode == "fix" && /^            [^ ]/ {
      sub(/^ +/, "")
      text = text " " $0
      next
    }
    {
      if (text != "") print text
      text = ""
      mode = ""
      if (/^  \| [A-Z][A-Z-]*$/) {
        print
        mode = "callout"
      } else if (/^   (ok  |info|warn|FAIL) /) {
        text = $0
        mode = "status"
      } else if (/^     `- fix /) {
        text = $0
        mode = "fix"
      } else {
        print
      }
    }
    END { if (text != "") print text }
  '
}

# compose_secrets: "<service> <name>" per service of docker-compose.yml that gets a secret of variables.env, with
# STF_TOKEN, GRID_AUTH_SECRET and LDAP_BIND_CREDENTIALS set in a copy of variables.env.original
compose_secrets() {
  local dir="${WORK}/compose-secrets"
  mkdir -p "$dir"
  cp "${REPO}/docker-compose.yml" "$dir/"
  cp "${REPO}/.env.original" "${dir}/.env"
  sed -e 's/^STF_TOKEN=.*/STF_TOKEN=admin-token/' -e 's/^GRID_AUTH_SECRET=.*/GRID_AUTH_SECRET=grid-secret/' \
    -e 's/^LDAP_BIND_CREDENTIALS=.*/LDAP_BIND_CREDENTIALS=ldap-password/' "${REPO}/variables.env.original" > "${dir}/variables.env"
  (cd "$dir" && docker compose --profile mdm --profile adb-relay config --format json 2> /dev/null) | python3 -c '
import json, sys
for name, service in sorted(json.load(sys.stdin)["services"].items()):
    for key, value in sorted((service.get("environment") or {}).items()):
        if key in ("STF_TOKEN", "GRID_AUTH_SECRET", "LDAP_BIND_CREDENTIALS") and value:
            print(name, key)
'
}

# compose_networks: "<service> <network,...>" per service of the profile mdm, the networks of docker-compose.yml
compose_networks() {
  local dir="${WORK}/compose"
  mkdir -p "$dir"
  cp "${REPO}/docker-compose.yml" "$dir/"
  cp "${REPO}/.env.original" "${dir}/.env"
  cp "${REPO}/variables.env.original" "${dir}/variables.env"
  (cd "$dir" && docker compose --profile mdm --profile adb-relay config --format json 2> /dev/null) | python3 -c '
import json, sys
for name, service in sorted(json.load(sys.stdin)["services"].items()):
    print(name, ",".join(sorted(service.get("networks") or ["host"])))
'
}
