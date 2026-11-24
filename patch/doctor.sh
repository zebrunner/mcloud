#!/bin/bash
# ./zebrunner.sh doctor: the diagnostics of the MCloud server (README.md#doctor), sourced by zebrunner.sh. Every check
# prints ok, warn or FAIL with its fix, the summary counts them; nothing is changed. The checks of a node are the ones
# of ./zebrunner.sh nodes check, the ones of the host of a node are ./zebrunner.sh doctor of mcloud-agent.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

DOCTOR_OK=0
DOCTOR_WARN=0
DOCTOR_FAIL=0
# the ports the nodes connect to on AGENTS_ADDRESS (docker-compose.yml, README.md#firewall): the grid (the
# registration of Appium) and ZeroMQ of STF (stf-triproxy-app, stf-triproxy-dev)
DOCTOR_NODE_PORTS="4446 7160 7250 7260 7270"
# the disk of docker: a warning and a failure from this usage, percent
DOCTOR_DISK_WARN=85
DOCTOR_DISK_FAIL=95
# the certificate of https: a warning when it expires within this many seconds (30 days)
DOCTOR_CERT_DAYS=30

# doctor_ok <message>: a passed check
doctor_ok() {
  DOCTOR_OK=$((DOCTOR_OK + 1))
  ui_ok "$1"
}

# doctor_warn <message> [<fix>]: a check that may break something
doctor_warn() {
  DOCTOR_WARN=$((DOCTOR_WARN + 1))
  ui_warn "$@"
}

# doctor_fail <message> [<fix>]: a check that breaks something
doctor_fail() {
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
  ui_fail "$@"
}

# doctor_value <file> <name>: the value of a variable of an env file, without its quotes; the last line wins
doctor_value() {
  sed -n "s/^${2}=//p" "$1" 2> /dev/null | tail -n 1 | sed -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/'
}

# version_at_least <version> <minimum>: succeeds when the version (e.g. 2.29.7, v2.24.0-desktop.1) is the minimum or
# newer, by its first three numbers
version_at_least() {
  local version="${1#v}"
  local minimum="$2"
  local i a b
  version="${version%%[-+]*}"
  for i in 1 2 3; do
    a="$(cut -d . -f "$i" <<< "$version")"
    b="$(cut -d . -f "$i" <<< "$minimum")"
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if ((10#$a > 10#$b)); then
      return 0
    fi
    if ((10#$a < 10#$b)); then
      return 1
    fi
  done
  return 0
}

# file_mode <file>: the permissions of a file, octal (GNU or BSD stat)
file_mode() {
  stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1" 2> /dev/null
}

# agents_ip: the address the ports of the nodes are published on, the loopback address for every address
agents_ip() {
  local address
  address="$(doctor_value .env AGENTS_ADDRESS)"
  case "$address" in
  "" | 0.0.0.0 | "::" | "[::]") echo 127.0.0.1 ;;
  *) echo "$address" ;;
  esac
}

# port_open <host> <port>: succeeds when a TCP connection to the port is accepted within 2 seconds: curl of telnet://
# waits for the server after the connection, so its time of the connection tells it, not its exit code
port_open() {
  local connected
  connected="$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 2 --max-time 2 "telnet://${1}:${2}" < /dev/null 2> /dev/null)"
  [[ -n "$connected" && ! "$connected" =~ ^[0.]+$ ]]
}

# host_has_address <address>: succeeds when the address is one of the network interfaces of this server; 2 when the
# addresses are unknown (no ip and no ifconfig)
host_has_address() {
  local addresses
  if command -v ip > /dev/null 2>&1; then
    addresses="$(ip -o addr show 2> /dev/null)"
  elif command -v ifconfig > /dev/null 2>&1; then
    addresses="$(ifconfig 2> /dev/null)"
  else
    return 2
  fi
  grep -qE "inet6? (addr:)?${1//./\\.}([/ ]|$)" <<< "$addresses"
}

# doctor_host: docker, docker compose, the disk of docker and the infra network; fails when docker does not answer
doctor_host() {
  local server compose root usage
  ui_section "Host"
  server="$(docker version --format '{{.Server.Version}}' 2> /dev/null)"
  if [[ -z "$server" ]]; then
    doctor_fail "Docker does not answer: its daemon does not run, or $(id -un) may not use it." \
      "start docker (sudo systemctl start docker); add $(id -un) to the group docker (sudo usermod -aG docker $(id -un)) and sign in again"
    return 1
  fi
  doctor_ok "Docker ${server}"
  compose="$(docker compose version --short 2> /dev/null)"
  if [[ -z "$compose" ]]; then
    doctor_fail "docker compose (the plugin of Docker, v2) is missing." "install the docker compose plugin (https://docs.docker.com/compose/install/linux/)"
  elif ! version_at_least "$compose" 2.24.0; then
    doctor_fail "docker compose ${compose}: docker-compose.yml needs 2.24.0 or newer (the optional env files of its services)." \
      "update the docker compose plugin"
  else
    doctor_ok "docker compose ${compose}"
  fi
  root="$(docker info --format '{{.DockerRootDir}}' 2> /dev/null)"
  root="${root:-/var/lib/docker}"
  usage="$(df -P "$root" 2> /dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
  if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
    ui_info "The disk of docker (${root}) is not checked: not readable from this server (e.g. the VM of Docker Desktop)."
  elif [[ "$usage" -ge "$DOCTOR_DISK_FAIL" ]]; then
    doctor_fail "The disk of docker (${root}) is ${usage}% full: the database of STF and the logs stop when it is full." \
      "docker system prune; smaller LOG_MAX_SIZE and LOG_MAX_FILE of .env; a bigger disk"
  elif [[ "$usage" -ge "$DOCTOR_DISK_WARN" ]]; then
    doctor_warn "The disk of docker (${root}) is ${usage}% full." "docker system prune; smaller LOG_MAX_SIZE and LOG_MAX_FILE of .env"
  else
    doctor_ok "The disk of docker (${root}): ${usage}% used"
  fi
  if docker network inspect infra > /dev/null 2>&1; then
    doctor_ok "The docker network infra exists"
  else
    doctor_warn "The docker network infra is missing: the services do not run." "./zebrunner.sh start creates it"
  fi
  return 0
}

# doctor_settings: STF_URL and AGENTS_ADDRESS of .env, the secrets of variables.env and the files of the secrets
doctor_settings() {
  local url host agents name value missing public private_files file mode
  local secrets_ok=1
  ui_section "Settings" "" ".env, variables.env"
  url="$(doctor_value .env STF_URL)"
  host="${url#*://}"
  host="${host%%/*}"
  host="${host%:*}"
  if [[ ! "$url" =~ ^https?://[^/:]+(:[0-9]{1,5})?$ ]]; then
    doctor_fail "STF_URL of .env '${url}' is not <http|https>://<host>[:<port>]." "./zebrunner.sh setup"
  elif [[ "$url" == http://* && "$host" != localhost && "$host" != 127.0.0.1 ]]; then
    doctor_warn "STF_URL ${url} is http: the passwords of the sign-in, the access tokens of the tests and the join strings of the nodes travel unencrypted." \
      "./zebrunner.sh setup with https and the certificate of ${host} (README.md#https)"
  else
    doctor_ok "STF_URL ${url}"
  fi
  if [[ "$(doctor_value variables.env STF_URL)" != "$url" ]]; then
    doctor_warn "STF_URL of variables.env is not the one of .env: the links of STF lead elsewhere." "./zebrunner.sh setup writes both"
  fi
  agents="$(doctor_value .env AGENTS_ADDRESS)"
  case "$agents" in
  "" | 0.0.0.0)
    doctor_warn "AGENTS_ADDRESS of .env is 0.0.0.0: the nodes reach MCloud at the host of STF_URL (${host}), which a node in the network of the server or on the server itself often does not reach (NAT hairpin)." \
      "set AGENTS_ADDRESS of .env to the LAN address of the server, then ./zebrunner.sh restart (README.md#devices-on-the-mcloud-server)"
    ;;
  *)
    host_has_address "$agents"
    case $? in
    0) doctor_ok "AGENTS_ADDRESS ${agents} is an address of this server" ;;
    1)
      doctor_fail "AGENTS_ADDRESS ${agents} of .env is not an address of this server: docker can't publish the ports of the nodes there." \
        "set AGENTS_ADDRESS of .env to an address of this server (its LAN address), then ./zebrunner.sh restart"
      ;;
    *) ui_info "AGENTS_ADDRESS ${agents} is not checked: no ip and no ifconfig on this server." ;;
    esac
    ;;
  esac
  value="$(doctor_value variables.env SECRET)"
  if [[ -z "$value" || "$value" == "password" ]]; then
    secrets_ok=0
    doctor_fail "SECRET of variables.env is empty or the default one: anyone can make the sessions and the access tokens of STF." \
      "./zebrunner.sh setup generates it for a new deployment; a change ends the sessions and invalidates the access tokens (README.md#configuration)"
  fi
  missing=""
  for name in STF_STORAGE_TOKEN RETHINKDB_ENV_AUTHKEY GRID_AUTH_SECRET; do
    if [[ -z "$(doctor_value variables.env "$name")" ]]; then
      missing="${missing:+${missing}, }${name}"
    fi
  done
  if [[ -n "$missing" ]]; then
    secrets_ok=0
    doctor_fail "Empty secrets of variables.env: ${missing}." "./zebrunner.sh setup generates them (GRID_AUTH_SECRET: ./zebrunner.sh start)"
  fi
  missing=""
  for name in STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY; do
    if [[ ! "$(doctor_value variables.env "$name")" =~ ^[0-9a-f]{64}$ ]]; then
      missing="${missing:+${missing}, }${name}"
    fi
  done
  if [[ -n "$missing" ]]; then
    secrets_ok=0
    doctor_fail "The CURVE keys of ZeroMQ of variables.env are not 64 hex characters: ${missing}; the nodes can't connect." \
      "./zebrunner.sh setup generates them (README.md#authentication-of-the-nodes)"
  elif command -v python3 > /dev/null 2>&1; then
    public="$(doctor_value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY | python3 "${BASEDIR}/patch/curve_keygen.py" - 2> /dev/null |
      sed -n 's/^public=//p')"
    if [[ -n "$public" && "$public" != "$(doctor_value variables.env STF_ZMQ_CURVE_SERVER_PUBLIC_KEY)" ]]; then
      secrets_ok=0
      doctor_fail "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of variables.env is not the public key of STF_ZMQ_CURVE_SERVER_SECRET_KEY: the nodes can't connect." \
        "./zebrunner.sh setup generates the pair; the nodes get the new public key with a new invite"
    fi
  fi
  if [[ "$(doctor_value .env AUTH_SYSTEM)" == "auth-mock" && -z "$(doctor_value variables.env STF_AUTH_MOCK_BASIC_AUTH_PASSWORD)" ]]; then
    secrets_ok=0
    doctor_fail "The mock sign-in has no password (STF_AUTH_MOCK_BASIC_AUTH_PASSWORD of variables.env): anyone signs in as any user." \
      "./zebrunner.sh setup generates it"
  fi
  if [[ "$secrets_ok" -eq 1 ]]; then
    doctor_ok "The secrets of variables.env are set"
  fi
  private_files=""
  for file in variables.env grid.env backup/settings.env configuration/stf-proxy/ssl/ssl.key configuration/adb-relay/stf-token; do
    mode="$(file_mode "$file")"
    if [[ -f "$file" && "$mode" =~ ^[0-7]*[0-7][1-7]$|^[0-7]*[1-7][0-7]$ ]]; then
      private_files="${private_files:+${private_files}, }${file} (${mode})"
    fi
  done
  if [[ -n "$private_files" ]]; then
    doctor_warn "Files with secrets are readable by other users of this server: ${private_files}." \
      "./zebrunner.sh start makes them readable for their owner only (README.md#files-and-secrets)"
  else
    doctor_ok "The files with secrets are readable for their owner only"
  fi
}

# doctor_tls: the certificate of stf-proxy for https: there, its key, the shared pair of Zebrunner CE, its expiry and
# its host
doctor_tls() {
  local dir="configuration/stf-proxy/ssl"
  local missing host end check subject issuer
  ui_section "TLS" "" "$dir"
  if ! grep -q '^[[:space:]]*ssl_certificate[[:space:]]' configuration/stf-proxy/nginx.conf 2> /dev/null; then
    ui_info "stf-proxy serves http: no certificate."
    return 0
  fi
  missing="$(certificate_missing)"
  if [[ -n "$missing" ]]; then
    doctor_fail "stf-proxy serves https and its certificate is missing: ${missing}; it does not start." \
      "put the certificate (PEM) of the host of STF_URL into ${dir}/ssl.crt and its key into ${dir}/ssl.key, then ./zebrunner.sh start (README.md#https)"
    return 0
  fi
  if [[ "$(file_sha256 "${dir}/ssl.crt")" == "$SHARED_SSL_CRT_SHA256" || "$(file_sha256 "${dir}/ssl.key")" == "$SHARED_SSL_KEY_SHA256" ]]; then
    doctor_fail "The certificate is the self-signed pair of the repository of Zebrunner CE, its private key is public: anyone can read and change the traffic of MCloud." \
      "replace it with the certificate of the host of STF_URL and its key (README.md#https)"
  fi
  if ! command -v openssl > /dev/null 2>&1; then
    doctor_warn "openssl is missing: the certificate is not checked." "install openssl"
    return 0
  fi
  if certificate_mismatch; then
    doctor_fail "${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM): stf-proxy does not start." \
      "put the key of that certificate there, then ./zebrunner.sh start (README.md#https)"
    return 0
  fi
  end="$(openssl x509 -noout -enddate -in "${dir}/ssl.crt" 2> /dev/null | sed 's/^notAfter=//')"
  if ! openssl x509 -noout -checkend 0 -in "${dir}/ssl.crt" > /dev/null 2>&1; then
    doctor_fail "The certificate expired on ${end}: the browsers, the tests and the nodes refuse it." \
      "renew it into ${dir}/ssl.crt and ssl.key, then ./zebrunner.sh restart; the nodes of a self-signed one get its pin with a new invite (README.md#https)"
  elif ! openssl x509 -noout -checkend $((DOCTOR_CERT_DAYS * 86400)) -in "${dir}/ssl.crt" > /dev/null 2>&1; then
    doctor_warn "The certificate expires on ${end}, within ${DOCTOR_CERT_DAYS} days." \
      "renew it into ${dir}/ssl.crt and ssl.key, then ./zebrunner.sh restart (README.md#https)"
  else
    doctor_ok "The certificate is valid until ${end}"
  fi
  host="$(doctor_value .env STF_URL)"
  host="${host#*://}"
  host="${host%%/*}"
  host="${host%:*}"
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    check="$(openssl x509 -noout -checkip "$host" -in "${dir}/ssl.crt" 2> /dev/null)"
  else
    check="$(openssl x509 -noout -checkhost "$host" -in "${dir}/ssl.crt" 2> /dev/null)"
  fi
  case "$check" in
  *"does NOT match"*)
    doctor_fail "The certificate is not of ${host}, the host of STF_URL: the browsers, the tests and the nodes refuse it." \
      "put the certificate of ${host} into ${dir}/ssl.crt and its key into ${dir}/ssl.key, then ./zebrunner.sh restart"
    ;;
  *"does match"*) doctor_ok "The certificate is of ${host}" ;;
  *) ui_info "The host of the certificate is not checked: the openssl of this server has no -checkhost." ;;
  esac
  subject="$(openssl x509 -noout -subject -in "${dir}/ssl.crt" 2> /dev/null | sed 's/^subject=//')"
  issuer="$(openssl x509 -noout -issuer -in "${dir}/ssl.crt" 2> /dev/null | sed 's/^issuer=//')"
  if [[ -n "$subject" && "$subject" == "$issuer" ]]; then
    ui_info "The certificate is self-signed: the nodes trust its pin (the join string), the browsers and the tests warn."
  fi
}

# doctor_services: every service of docker-compose.yml (with the profiles of ADB_RELAY and MDM_ENABLED) is created
# and runs (healthy where it has a healthcheck, stf-migrate exited with 0) without restarting again and again
doctor_services() {
  local profiles=()
  local services ps service line state health code name restarts dir
  local count=0
  local problems=0
  ui_section "Services" "" "docker compose ps"
  dir="$(docker ps -a --filter "label=com.docker.compose.project=$(compose_project)" \
    --filter "label=com.docker.compose.service=rethinkdb" --format '{{.Label "com.docker.compose.project.working_dir"}}' \
    2> /dev/null | head -1)"
  if [[ -n "$dir" && -d "$dir" && "$(cd "$dir" && pwd -P)" != "$(pwd -P)" ]]; then
    doctor_fail "The services of the docker compose project $(compose_project) are the MCloud of ${dir}, not of this folder: the checks below would be the ones of that MCloud." \
      "use that folder, or remove that MCloud first (./zebrunner.sh down in ${dir}) (README.md#troubleshooting)"
    return 1
  fi
  if [[ "$(doctor_value .env ADB_RELAY)" == "true" ]]; then
    profiles+=(--profile adb-relay)
  fi
  if [[ "$(doctor_value .env MDM_ENABLED)" == "true" ]]; then
    profiles+=(--profile mdm)
  fi
  if ! services="$(docker compose "${profiles[@]+"${profiles[@]}"}" config --services 2>&1)"; then
    doctor_fail "docker compose does not read docker-compose.yml: $(head -n 1 <<< "$services")" "./zebrunner.sh setup, then ./zebrunner.sh start"
    return 1
  fi
  ps="$(docker compose "${profiles[@]+"${profiles[@]}"}" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}|{{.Name}}' 2> /dev/null)"
  for service in $services; do
    line="$(grep "^${service}|" <<< "$ps" | head -n 1)"
    if [[ -z "$line" ]]; then
      problems=$((problems + 1))
      doctor_fail "${service} is not created." "./zebrunner.sh start"
      continue
    fi
    IFS='|' read -r _ state health code name <<< "$line"
    if [[ "$service" == "stf-migrate" ]]; then
      if [[ "$state" == "exited" && "$code" == "0" ]]; then
        count=$((count + 1))
      elif [[ "$state" == "exited" ]]; then
        problems=$((problems + 1))
        doctor_fail "stf-migrate, the migration of the database of STF, failed (exit ${code}): STF does not start." "docker logs ${name}"
      else
        count=$((count + 1))
      fi
      continue
    fi
    case "${state}:${health}" in
    running: | running:healthy)
      count=$((count + 1))
      ;;
    running:starting)
      problems=$((problems + 1))
      doctor_warn "${service} is starting." "run ./zebrunner.sh doctor again in a minute; docker logs ${name}"
      ;;
    running:unhealthy)
      problems=$((problems + 1))
      doctor_fail "${service} is unhealthy." "docker logs ${name}"
      ;;
    *)
      problems=$((problems + 1))
      doctor_fail "${service} is ${state}$([[ "$state" == "exited" ]] && echo " (exit ${code})")." "docker logs ${name}; ./zebrunner.sh start"
      continue
      ;;
    esac
    restarts="$(docker inspect --format '{{.RestartCount}}' "$name" 2> /dev/null)"
    if [[ "$restarts" =~ ^[0-9]+$ && "$restarts" -gt 3 ]]; then
      problems=$((problems + 1))
      doctor_warn "${service} restarted ${restarts} times." "docker logs ${name}"
    fi
  done
  if [[ "$problems" -eq 0 ]]; then
    doctor_ok "The ${count} services run (healthy where they have a healthcheck)"
  fi
}

# doctor_api: STF_TOKEN is a valid access token of an admin of STF, the grid has the same one and answers
doctor_api() {
  local token body email grid code
  ui_section "STF API" "" "STF_TOKEN of variables.env"
  token="$(stf_token)"
  if [[ -z "$token" ]]; then
    doctor_fail "STF_TOKEN of variables.env is empty: the grid reserves no device, the node commands and adb-relay do not work." \
      "./zebrunner.sh restart makes it (README.md#stf_token)"
  elif stf_api GET /api/v1/user; then
    # shellcheck disable=SC2154 # api_body and api_status are set by stf_api of zebrunner.sh
    body="$api_body"
    email="$(json_value email <<< "$body")"
    if [[ "$(json_value privilege <<< "$body")" == "admin" ]]; then
      doctor_ok "STF_TOKEN is an access token of the admin ${email}"
    else
      doctor_fail "STF_TOKEN is an access token of ${email}, not of an admin: the grid can't reserve the devices for every user." \
        "an access token of an admin of STF (Settings, Keys) as STF_TOKEN, or an empty STF_TOKEN and ./zebrunner.sh restart (README.md#stf_token)"
    fi
  else
    doctor_fail "The STF API with STF_TOKEN failed: $(api_reason)."
  fi
  grid="$(doctor_value grid.env STF_TOKEN)"
  if [[ -n "$token" && "$grid" != "$token" ]]; then
    doctor_warn "The grid has another STF_TOKEN than variables.env (grid.env)." "./zebrunner.sh restart"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$(agents_ip):4446/grid/api/proxy?id=none" 2> /dev/null)"
  if [[ "$code" == "200" ]]; then
    doctor_ok "The grid answers on $(agents_ip):4446"
  else
    doctor_fail "The grid does not answer on $(agents_ip):4446 (HTTP ${code:-000}): the nodes can't register Appium." \
      "docker logs mcloud-grid; docker logs stf-proxy; ./zebrunner.sh start"
  fi
}

# doctor_ports: STF_URL answers from this server, the ports of the nodes listen on AGENTS_ADDRESS (the firewall of the
# server is not seen from here)
doctor_ports() {
  local url code port closed ports
  ui_section "Ports" "" "README.md#firewall"
  url="$(doctor_value .env STF_URL)"
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${url}/" 2> /dev/null)"
  if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
    doctor_ok "STF_URL ${url} answers from this server (HTTP ${code})"
  else
    doctor_warn "STF_URL ${url} does not answer from this server: its name does not resolve here, or the router does not send its public address back inside (NAT hairpin); the users and the nodes outside may still reach it." \
      "curl -kI ${url} from the machine of a user; a node in the network of the server joins with AGENTS_ADDRESS (README.md#nodes-in-a-private-network)"
  fi
  ports="$DOCTOR_NODE_PORTS"
  if [[ "$(doctor_value .env MDM_ENABLED)" == "true" ]]; then
    ports="${ports} $(doctor_value .env MDM_MQTT_PORT)"
  fi
  closed=""
  for port in $ports; do
    if ! port_open "$(agents_ip)" "$port"; then
      closed="${closed:+${closed}, }${port}"
    fi
  done
  if [[ -n "$closed" ]]; then
    doctor_fail "Ports of the nodes do not listen on $(agents_ip): ${closed}." "./zebrunner.sh start; docker ps (README.md#firewall)"
  else
    doctor_ok "The ports of the nodes listen on $(agents_ip): ${ports// /, }"
  fi
  ui_info "The firewall of the server must let the nodes in on these ports and on STF_PORT, the users on STF_PORT; it is not seen from here (README.md#firewall)."
}

# doctor_nodes: the enrolled nodes; ./zebrunner.sh nodes check of every active one
doctor_nodes() {
  local nodes line label address status seen
  ui_section "Nodes" "" "./zebrunner.sh nodes"
  if [[ -z "$(stf_token)" ]]; then
    ui_info "The nodes are not checked: STF_TOKEN is empty."
    return 0
  fi
  if ! stf_api GET /api/v1/nodes; then
    # shellcheck disable=SC2154 # set by stf_api of zebrunner.sh
    if [[ "$api_status" == "404" ]]; then
      ui_info "The STF of TAG_STF has no registry of the nodes."
    else
      doctor_fail "The list of the nodes failed: $(api_reason)."
    fi
    return 0
  fi
  nodes="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep '"label"')"
  if [[ -z "$nodes" ]]; then
    doctor_warn "No node is enrolled: MCloud has no device." "./zebrunner.sh node-invite <label> <address> (README.md#nodes)"
    return 0
  fi
  while read -r line; do
    label="$(json_value label <<< "$line")"
    address="$(json_value address <<< "$line")"
    status="$(json_value status <<< "$line")"
    seen="$(json_time lastSeenAt <<< "$line")"
    if [[ "$status" != "active" ]]; then
      ui_info "Node ${label} (${address}) is ${status}."
    elif (nodes_check "$label" > /dev/null 2>&1); then
      doctor_ok "Node ${label} (${address}, last seen ${seen}): ./zebrunner.sh nodes check ${label} passes"
    else
      doctor_fail "Node ${label} (${address}, last seen ${seen}): a check of the node fails." "./zebrunner.sh nodes check ${label}"
    fi
  done <<< "$nodes"
}

# doctor: all the checks of the server (README.md#doctor); fails when one of them fails
doctor() {
  if ! require_setup; then
    return 1
  fi
  DOCTOR_OK=0
  DOCTOR_WARN=0
  DOCTOR_FAIL=0
  ui_banner "MCloud" "$(mcloud_tag)"
  if doctor_host; then
    doctor_settings
    doctor_tls
    if doctor_services; then
      doctor_api
      doctor_ports
      doctor_nodes
    fi
  else
    doctor_settings
    doctor_tls
    ui_info "The services, the STF API, the ports and the nodes are not checked: docker does not answer."
  fi
  ui_summary "$DOCTOR_OK" "$DOCTOR_WARN" "$DOCTOR_FAIL"
  [[ "$DOCTOR_FAIL" -eq 0 ]]
}
