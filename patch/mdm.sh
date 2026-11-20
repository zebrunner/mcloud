#!/bin/bash
# The MDM of the devices (README.md#mdm): mcloud-mdm with NanoHUB (iOS) and Headwind MDM (Android), the services of the
# profile mdm of docker-compose.yml. Its settings are MDM_* of .env; ./zebrunner.sh setup and start write the secrets
# (mdm.env), the locations of stf-proxy (configuration/stf-proxy/mdm) and the configuration of the MQTT proxy
# (configuration/mdm/mqtt.conf). Sourced by zebrunner.sh and by the tests after patch/utility.sh and patch/ui.sh; keep it
# compatible with the macOS system bash 3.2 (CONVENTIONS.md).

MDM_ENV="mdm.env"
# the env files of the MDM services, each with the secrets of its service only (write_mdm_service_envs)
MDM_ENV_DIR="configuration/mdm/env"
MDM_SERVICES="mcloud-mdm mcloud-mdm-nanohub mcloud-mdm-mysql mcloud-mdm-hmdm mcloud-mdm-postgres mcloud-mdm-hmdm-init"
MDM_PROXY_DIR="configuration/stf-proxy/mdm"
MDM_MQTT_CONF="configuration/mdm/mqtt.conf"
MDM_AGENT_APK="configuration/mdm/android/mcloud-mdm-agent.apk"

# mdm_setting <name>: the value of a setting of .env
mdm_setting() {
  sed -n "s/^$1=//p" .env 2> /dev/null | tail -n 1
}

# mdm_secret <name>: the value of a secret of mdm.env
mdm_secret() {
  sed -n "s/^$1=//p" "$MDM_ENV" 2> /dev/null | tail -n 1
}

# mdm_addresses: the valid addresses of MDM_SITE_ADDRESSES of .env (IPv4 or IPv6, with or without a prefix length), one
# per line; the invalid ones are reported and skipped
mdm_addresses() {
  local value
  local address
  value="$(mdm_setting MDM_SITE_ADDRESSES)"
  for address in ${value//,/ }; do
    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ || "$address" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/[0-9]{1,3})?$ ]]; then
      echo "$address"
    else
      echo_warning "'${address}' of MDM_SITE_ADDRESSES of .env is not an address (203.0.113.10 or 203.0.113.0/24): skipped." >&2
    fi
  done
}

# mdm_check: succeeds when the MDM runs (MDM_ENABLED=true of .env with an https STF_URL); the problems are reported
# mdm_env_keys: the settings of the MDM and the tags of its images of .env.original that the .env of an earlier MCloud
# has not (docker compose reads the tags of the profile mdm even when it is off), with their defaults
mdm_env_keys() {
  local line
  [[ -f .env && -f .env.original ]] || return 0
  if [[ -s .env && -n "$(tail -c 1 .env)" ]]; then
    echo >> .env
  fi
  while IFS= read -r line; do
    if ! grep -q "^${line%%=*}=" .env; then
      printf '%s\n' "$line" >> .env
    fi
  done < <(grep -E '^(MDM_[A-Z_]+|TAG_MDM[A-Z_]*|TAG_NANOHUB|TAG_HMDM)=' .env.original)
}

mdm_check() {
  local enabled
  local url
  enabled="$(mdm_setting MDM_ENABLED)"
  case "$enabled" in
  true) ;;
  "" | false)
    return 1
    ;;
  *)
    echo_warning "MDM_ENABLED of .env is '${enabled}', not true or false: the MDM is off."
    return 1
    ;;
  esac
  url="$(mdm_setting STF_URL)"
  if [[ "$url" != https://* ]]; then
    echo_warning "MDM_ENABLED=true needs https, STF_URL of .env is ${url}: the devices reach the MDM over https only, the MDM is off (README.md#mdm)."
    return 1
  fi
  # the invalid addresses are reported here, once a start
  if [[ -z "$(mdm_addresses)" ]]; then
    echo_warning "MDM_SITE_ADDRESSES of .env has no address: no device and no node reaches the MDM. Set the fixed public addresses of the sites of the devices (README.md#mdm)."
  fi
  if [[ ! -f "$MDM_AGENT_APK" ]]; then
    echo_warning "${MDM_AGENT_APK} is missing: no Android device is enrolled. Put the agent there (make agent of zebrunner/mcloud-mdm, README.md#mdm)."
  fi
  return 0
}

# write_mdm_env: mdm.env, the secrets of the MDM services, for the owner only; the ones of the previous mdm.env are kept
# (a new password of a database would lock its services out of it)
write_mdm_env() {
  local token
  local admin_token
  local api_key
  local mysql_password
  local hmdm_password
  local hmdm_secret
  local hmdm_sql_password
  token="$(mdm_secret MDM_ENROLL_TOKEN)"
  admin_token="$(mdm_secret MDM_ADMIN_TOKEN)"
  api_key="$(mdm_secret NANOHUB_API_KEY)"
  mysql_password="$(mdm_secret MYSQL_PASSWORD)"
  hmdm_password="$(mdm_secret HMDM_PASSWORD)"
  hmdm_secret="$(mdm_secret HMDM_SHARED_SECRET)"
  hmdm_sql_password="$(mdm_secret SQL_PASS)"
  : "${token:=$(random_string 48)}"
  : "${admin_token:=$(random_string 48)}"
  : "${api_key:=$(random_string 48)}"
  : "${mysql_password:=$(random_string 32)}"
  : "${hmdm_password:=$(random_string 32)}"
  : "${hmdm_secret:=$(random_string 32)}"
  : "${hmdm_sql_password:=$(random_string 32)}"
  # the access token of STF (STF_TOKEN of variables.env, the one of the grid): the names, nodes and users of the devices
  # in the admin UI; read again at every start
  local stf_token
  stf_token="$(sed -n "s/^STF_TOKEN=//p" variables.env 2> /dev/null | tail -n 1)"
  stf_token="${stf_token//[\'\"]/}"
  if ! (umask 077 && {
    echo "# written by ./zebrunner.sh setup and start (README.md#mdm): the secrets of the MDM services, kept from setup to"
    echo "# setup; keep a copy in the store of the secrets: without HMDM_SHARED_SECRET and the server only a factory reset"
    echo "# removes the device owner of the Android agents"
    echo "# mcloud-mdm: the enrollment token of the nodes (stf-proxy sends it), the API key of NanoHUB"
    echo "MDM_ENROLL_TOKEN=${token}"
    echo "NANOHUB_API_KEY=${api_key}"
    echo "# mcloud-mdm: every request of the admin listener needs it (the password of the admin UI through the ssh tunnel,"
    echo "# stf-proxy sends it for MDM_ADMIN_PUBLIC=true, NanoHUB in its webhook URL)"
    echo "MDM_ADMIN_TOKEN=${admin_token}"
    echo "NANOHUB_WEBHOOK_URL=http://admin:${admin_token}@mcloud-mdm:8081/webhook"
    echo "# NanoHUB and MySQL"
    echo "MYSQL_PASSWORD=${mysql_password}"
    echo "NANOHUB_STORAGE_DSN=nanohub:${mysql_password}@tcp(mcloud-mdm-mysql:3306)/nanohub?parseTime=true"
    echo "# Headwind MDM: the password of its admin, the shared secret of the agents, the password of its PostgreSQL"
    echo "HMDM_PASSWORD=${hmdm_password}"
    echo "HMDM_SHARED_SECRET=${hmdm_secret}"
    echo "SHARED_SECRET=${hmdm_secret}"
    echo "SQL_PASS=${hmdm_sql_password}"
    echo "POSTGRES_PASSWORD=${hmdm_sql_password}"
    echo "PGPASSWORD=${hmdm_sql_password}"
    if [[ -n "$stf_token" ]]; then
      echo "# mcloud-mdm: the API of STF with STF_TOKEN of variables.env (written again at every start)"
      echo "MDM_STF_URL=http://stf-api:3000"
      echo "MDM_STF_TOKEN=${stf_token}"
    fi
  } 2> /dev/null > "$MDM_ENV"); then
    ui_callout error "${MDM_ENV} is not writable for $(id -un): remove it only if the MDM never ran (its databases keep the passwords), make it writable and run ./zebrunner.sh start (README.md#troubleshooting)."
    return 1
  fi
  chmod 600 "$MDM_ENV"
}

# mdm_service_secrets <service>: the names of the secrets of mdm.env a service reads, nothing else of mdm.env reaches it
mdm_service_secrets() {
  case "$1" in
  mcloud-mdm) echo "MDM_ENROLL_TOKEN NANOHUB_API_KEY MDM_ADMIN_TOKEN HMDM_PASSWORD HMDM_SHARED_SECRET MDM_STF_URL MDM_STF_TOKEN" ;;
  mcloud-mdm-nanohub) echo "NANOHUB_API_KEY NANOHUB_STORAGE_DSN NANOHUB_WEBHOOK_URL" ;;
  mcloud-mdm-mysql) echo "MYSQL_PASSWORD" ;;
  mcloud-mdm-hmdm) echo "SQL_PASS SHARED_SECRET" ;;
  mcloud-mdm-postgres) echo "POSTGRES_PASSWORD" ;;
  mcloud-mdm-hmdm-init) echo "PGPASSWORD HMDM_PASSWORD" ;;
  esac
}

# write_mdm_service_envs: configuration/mdm/env/<service>.env of every MDM service (docker-compose.yml) from mdm.env, for
# the owner only: a service gets its own secrets, not the admin token of STF or the passwords of the other services
write_mdm_service_envs() {
  local service
  local name
  local value
  mkdir -p "$MDM_ENV_DIR" && chmod 700 "$MDM_ENV_DIR"
  for service in $MDM_SERVICES; do
    if ! (umask 077 && {
      echo "# written by ./zebrunner.sh start from mdm.env (README.md#mdm): the secrets of ${service} only"
      for name in $(mdm_service_secrets "$service"); do
        value="$(mdm_secret "$name")"
        if [[ -n "$value" ]]; then
          echo "${name}=${value}"
        fi
      done
    } 2> /dev/null > "${MDM_ENV_DIR}/${service}.env"); then
      ui_callout error "${MDM_ENV_DIR}/${service}.env is not writable for $(id -un): remove it and run ./zebrunner.sh start (README.md#troubleshooting)."
      return 1
    fi
    chmod 600 "${MDM_ENV_DIR}/${service}.env"
  done
}

# write_mdm_proxy <on|off>: the locations of the MDM for stf-proxy and the configuration of the MQTT proxy (on), none
# of them (off); MDM_PROXY_CHANGED=1 when the files of stf-proxy changed (a running stf-proxy reads them again)
# read by zebrunner.sh
# shellcheck disable=SC2034
MDM_PROXY_CHANGED=""
write_mdm_proxy() {
  local before
  local after
  local addresses
  local address
  local token
  local admin_token
  MDM_PROXY_CHANGED=""
  before="$(cat "${MDM_PROXY_DIR}"/*.conf 2> /dev/null)"
  if [[ "$1" != "on" ]]; then
    rm -f "${MDM_PROXY_DIR}"/*.conf "$MDM_MQTT_CONF"
  else
    addresses="$(mdm_addresses 2> /dev/null)"
    token="$(mdm_secret MDM_ENROLL_TOKEN)"
    admin_token="$(mdm_secret MDM_ADMIN_TOKEN)"
    mkdir -p "$MDM_PROXY_DIR"
    {
      echo "# written by ./zebrunner.sh setup and start from MDM_SITE_ADDRESSES of .env (README.md#mdm): the sites of the"
      echo "# devices and of the nodes, the only addresses that reach the MDM"
      echo "geo \$mdm_device_site {"
      echo "  default 0;"
      for address in $addresses; do
        echo "  ${address} 1;"
      done
      echo "}"
    } > "${MDM_PROXY_DIR}/http-mdm.conf"
    if ! (umask 077 && mdm_locations "$token" "$admin_token" 2> /dev/null > "${MDM_PROXY_DIR}/server-mdm.conf"); then
      ui_callout error "${MDM_PROXY_DIR}/server-mdm.conf is not writable for $(id -un): remove it and run ./zebrunner.sh start (README.md#troubleshooting)."
      return 1
    fi
    chmod 600 "${MDM_PROXY_DIR}/server-mdm.conf"
    mdm_mqtt_conf "$addresses" > "$MDM_MQTT_CONF"
  fi
  after="$(cat "${MDM_PROXY_DIR}"/*.conf 2> /dev/null)"
  if [[ "$before" != "$after" ]]; then
    # shellcheck disable=SC2034
    MDM_PROXY_CHANGED=1
  fi
}

# mdm_locations <enrollment token> <admin token>: the locations of the MDM in the server of stf-proxy (mcloud-mdm proxy.conf)
mdm_locations() {
  # the variables of nginx
  # shellcheck disable=SC2016
  printf '%s\n' '# written by ./zebrunner.sh setup and start (README.md#mdm): the paths of the devices and of the nodes, from the' \
    '# addresses of MDM_SITE_ADDRESSES only; the API of NanoHUB, the device listener of mcloud-mdm and the web panel of' \
    '# Headwind MDM are not published' \
    '' \
    '# iOS: the MDM protocol (NanoHUB checks the signature of the device identity of every request)' \
    'location ~ ^/(mdm|checkin)$ {' \
    '  if ($mdm_device_site = 0) {' \
    '    return 403;' \
    '  }' \
    '  proxy_set_header Host $host;' \
    '  set $upstream_nanohub mcloud-mdm-nanohub:9004;' \
    '  proxy_pass http://$upstream_nanohub;' \
    '}' \
    '' \
    '# SCEP (one-time challenges) and the agent APK: no credentials of the client' \
    'location ~ ^/(scep|android/agent\.apk)$ {' \
    '  if ($mdm_device_site = 0) {' \
    '    return 403;' \
    '  }' \
    '  proxy_set_header Host $host;' \
    '  proxy_set_header Authorization "";' \
    '  proxy_set_header Cookie "";' \
    '  set $upstream_mdm mcloud-mdm:8080;' \
    '  proxy_pass http://$upstream_mdm;' \
    '}' \
    '' \
    '# the nodes: their node token (MCLOUD_NODE_TOKEN of mcloud-agent) checked by stf-api, then the enrollment token' \
    'location ~ ^/(mdm/(enroll|status|release)|android/(enroll|status|release))$ {' \
    '  if ($mdm_device_site = 0) {' \
    '    return 403;' \
    '  }' \
    '  auth_request /_mdm_node_auth;' \
    '  proxy_set_header Host $host;' \
    "  proxy_set_header Authorization \"Bearer $1\";" \
    '  set $upstream_mdm mcloud-mdm:8080;' \
    '  proxy_pass http://$upstream_mdm;' \
    '}' \
    'location = /_mdm_node_auth {' \
    '  internal;' \
    '  set $upstream_node_auth stf-api:3000;' \
    '  proxy_pass http://$upstream_node_auth/api/v1/nodes/self;' \
    '  proxy_pass_request_body off;' \
    '  proxy_pass_request_headers off;' \
    '  proxy_set_header Content-Length "";' \
    '  proxy_set_header Authorization $http_authorization;' \
    '  proxy_set_header Host stf-proxy;' \
    '  proxy_set_header X-Forwarded-Proto $forwarded_proto;' \
    '}' \
    '' \
    '# Android: the paths of the agents of Headwind MDM under /hmdm, the prefix stripped' \
    'location ~ ^/hmdm/(rest/public/sync/(configuration/[^/]+|info)|rest/(notification/polling|notifications/device)/[^/]+|rest/plugins/(deviceinfo/deviceinfo/public|deviceinfo/deviceinfo-plugin-settings/device|devicelog/log/list|devicelog/log/rules)/[^/]+|files/[^/]+)$ {' \
    '  if ($mdm_device_site = 0) {' \
    '    return 403;' \
    '  }' \
    '  # set before rewrite: break ends the directives of the rewrite module' \
    '  set $upstream_hmdm mcloud-mdm-hmdm:8080;' \
    '  rewrite ^/hmdm(/.*)$ $1 break;' \
    '  proxy_set_header Host $host;' \
    '  proxy_set_header X-Real-IP $remote_addr;' \
    '  proxy_pass http://$upstream_hmdm;' \
    '}' \
    '# the other paths of Headwind MDM (its web panel, the API of the admins): a regex after the one above, a prefix' \
    '# location with ^~ would hide it' \
    'location ~ ^/hmdm(/|$) {' \
    '  return 404;' \
    '}'
  if [[ "$(mdm_setting MDM_ADMIN_PUBLIC)" == "true" ]]; then
    # shellcheck disable=SC2016
    printf '%s\n' '' \
      '# MDM_ADMIN_PUBLIC=true: the admin UI of mcloud-mdm for the admins of STF; Host with its port, the UI compares it' \
      '# with the Origin of its POSTs' \
      'location = /mcloud/mdm {' \
      '  return 302 /mcloud/mdm/;' \
      '}' \
      'location ^~ /mcloud/mdm/ {' \
      '  auth_request /_hub_auth/admin;' \
      '  error_page 401 = @console_sign_in;' \
      '  set $upstream_mdm_admin mcloud-mdm:8081;' \
      '  rewrite ^/mcloud/mdm(/.*)$ $1 break;' \
      '  proxy_set_header Host $http_host;' \
      '  # the admin token of mcloud-mdm, never the one of a client' \
      "  proxy_set_header Authorization \"Bearer ${2}\";" \
      '  proxy_pass http://$upstream_mdm_admin;' \
      '}'
  fi
}

# mdm_mqtt_conf <addresses>: the nginx of mcloud-mdm-mqtt: MQTT over TLS of the Android agents with the certificate of
# stf-proxy, from the addresses only, to the MQTT of Headwind MDM
mdm_mqtt_conf() {
  local address
  echo "# written by ./zebrunner.sh setup and start (README.md#mdm): MQTT over TLS of the Android agents"
  echo "events {}"
  echo "stream {"
  echo "  server {"
  echo "    listen 31443 ssl;"
  echo "    ssl_certificate /etc/nginx/ssl/ssl.crt;"
  echo "    ssl_certificate_key /etc/nginx/ssl/ssl.key;"
  echo "    ssl_protocols TLSv1.2 TLSv1.3;"
  for address in $1; do
    echo "    allow ${address};"
  done
  echo "    deny all;"
  echo "    resolver 127.0.0.11 valid=30s;"
  # the variable of nginx
  # shellcheck disable=SC2016
  echo '    set $upstream_mqtt mcloud-mdm-hmdm:31000;'
  # shellcheck disable=SC2016
  echo '    proxy_pass $upstream_mqtt;'
  echo "  }"
  echo "}"
}

# write_mdm: everything of the MDM for the settings of .env; MDM_ON=1 when it runs (the profile mdm), read by
# zebrunner.sh
# shellcheck disable=SC2034
MDM_ON=""
write_mdm() {
  MDM_ON=""
  mdm_env_keys
  if mdm_check; then
    write_mdm_env || return 1
    write_mdm_service_envs || return 1
    write_mdm_proxy on || return 1
    # shellcheck disable=SC2034
    MDM_ON=1
  else
    write_mdm_proxy off
  fi
}
