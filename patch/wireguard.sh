#!/bin/bash
# The WireGuard tunnel of the nodes on the server (README.md#wireguard-tunnel-of-the-nodes), sourced by zebrunner.sh:
# the key of the server, the values setup and start derive from the settings of .env, the files of the service
# wireguard and the addresses of the invites. Off (NODES_WIREGUARD=false, the default) nothing of it changes MCloud.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

# the files of the service wireguard (configuration/wireguard), written by setup and start: the private key of the
# server and STF_TOKEN (mode 600, empty without the tunnel), the --nodes-wg-* options of stf-api (empty without it)
WG_KEY_FILE="configuration/wireguard/private-key"
WG_TOKEN_FILE="configuration/wireguard/stf-token"
WG_STF_API_ENV="configuration/wireguard/stf-api.env"
# the DER prefixes of an X25519 key: PKCS#8 of a private key, SubjectPublicKeyInfo of a public key (RFC 8410), the 32
# bytes of the key follow
WG_PKCS8_PREFIX="302e020100300506032b656e04220420"

# env_setting <name>: the value of a setting of .env, the last line wins
env_setting() {
  sed -n "s/^${1}=//p" .env 2> /dev/null | tail -n 1
}

# wg_on: the tunnel is on, NODES_WIREGUARD of .env is true
wg_on() {
  [[ "$(env_setting NODES_WIREGUARD)" == "true" ]]
}

# wg_url_host: the host of STF_URL of .env, the public host of the server: the nodes enroll there over https and dial
# the UDP port of the tunnel there
wg_url_host() {
  local host
  host="$(env_setting STF_URL)"
  host="${host#*://}"
  host="${host%%/*}"
  echo "${host%:*}"
}

# wg_server: the WireGuard address of the server, the first host of NODES_WG_NETWORK; fails for an invalid network
wg_server() {
  wg_server_address "$(env_setting NODES_WG_NETWORK)"
}

# wg_secret: NODES_WG_PRIVATE_KEY of variables.env, without the quotes
wg_secret() {
  sed -n "s/^NODES_WG_PRIVATE_KEY=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" variables.env 2> /dev/null | tail -1
}

# hex_base64: the base64 of the bytes of the hex digits of stdin (a key: no argument of a process gets it)
hex_base64() {
  local hex
  hex="$(tr -d ' \n')"
  # \x escapes of the bytes for the printf of bash
  printf '%b' "$(sed 's/../\\x&/g' <<< "$hex")" | base64 | tr -d '\n'
}

# base64_hex: the hex digits of the bytes of the base64 of stdin
base64_hex() {
  local value
  value="$(tr -d ' \n')"
  # GNU base64 and the one of macOS 13+ decode with -d, older macOS with -D
  { base64 -d <<< "$value" 2> /dev/null || base64 -D <<< "$value" 2> /dev/null; } | od -An -v -tx1 | tr -d ' \n'
}

# wg_new_key: a new private key of WireGuard, base64 of 32 bytes as of wg genkey (clamped as X25519 does it): the secret
# of curve_pair, openssl or patch/curve_keygen.py; fails without them
wg_new_key() {
  local secret first last
  secret="$(curve_pair | sed -n 's/^secret=//p')"
  if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  first=$((0x${secret:0:2} & 248))
  last=$(((0x${secret:62:2} & 127) | 64))
  printf '%02x%s%02x\n' "$first" "${secret:2:60}" "$last" | hex_base64
}

# wg_public_key: the public key of the private key of stdin, base64 as of wg pubkey: by openssl (X25519 of OpenSSL
# 1.1.1+), by patch/curve_keygen.py without it (the LibreSSL of macOS); fails for a key that is not one
wg_public_key() {
  local private hex public=""
  private="$(tr -d ' \n')"
  if [[ ! "$private" =~ $WG_KEY_REGEX ]]; then
    return 1
  fi
  hex="$(base64_hex <<< "$private")"
  if [[ ! "$hex" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  # the SubjectPublicKeyInfo of the key ends with its 32 bytes
  public="$(printf '%b' "$(sed 's/../\\x&/g' <<< "${WG_PKCS8_PREFIX}${hex}")" |
    openssl pkey -inform DER -pubout -outform DER 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
  if [[ ${#public} -eq 88 ]]; then
    public="${public:24}"
  else
    public="$(printf '%s\n' "$hex" | python3 "${BASEDIR}/patch/curve_keygen.py" - 2> /dev/null | sed -n 's/^public=//p')"
  fi
  if [[ ! "$public" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  hex_base64 <<< "$public"
  echo
}

# check_wireguard: the settings of the tunnel of .env for start: warns about NODES_WIREGUARD that is not true or false
# (the tunnel is off then) and an invalid NODES_WG_SYNC_SECONDS; fails with the tunnel on for a network or a port the
# service wireguard cannot take: the ports of the nodes would be published on no address
check_wireguard() {
  local value
  value="$(env_setting NODES_WIREGUARD)"
  case "$value" in
  true) ;;
  "" | false)
    return 0
    ;;
  *)
    echo_warning "NODES_WIREGUARD of .env is '${value}', not true or false: the WireGuard tunnel of the nodes is off."
    return 0
    ;;
  esac
  value="$(env_setting NODES_WG_NETWORK)"
  if ! wg_network "$value" > /dev/null; then
    ui_callout error "The services are not started: NODES_WG_NETWORK of .env '${value}' is not a private network <address>/<16-30> without the host bits (e.g. 10.234.0.0/24), out of the networks of the devices of the nodes (${WG_DEVICE_NETWORKS}). Set it, then ./zebrunner.sh start (README.md#wireguard-tunnel-of-the-nodes)."
    return 1
  fi
  value="$(env_setting NODES_WG_PORT)"
  if [[ ! "$value" =~ ^[1-9][0-9]{0,4}$ ]] || ((value > 65535)); then
    ui_callout error "The services are not started: NODES_WG_PORT of .env '${value}' is not a UDP port 1-65535 (51820 by default). Set it, then ./zebrunner.sh start (README.md#wireguard-tunnel-of-the-nodes)."
    return 1
  fi
  value="$(env_setting NODES_WG_SYNC_SECONDS)"
  if [[ -n "$value" && ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo_warning "NODES_WG_SYNC_SECONDS of .env '${value}' is not a number of seconds: the tunnel reads the nodes every 5 seconds."
  fi
}

# check_wireguard_token: warns about an empty STF_TOKEN with the tunnel on (after start made one when it could): the
# service wireguard reads the peers with it
check_wireguard_token() {
  if wg_on && [[ -z "$(stf_token)" ]]; then
    echo_warning "STF_TOKEN of variables.env is empty: the WireGuard tunnel (NODES_WIREGUARD=true) lets no node in. Set an access token of STF there (Settings, Keys) and run ./zebrunner.sh start: the tunnel reads it on its next sync."
  fi
}

# ensure_wg_key: NODES_WG_PRIVATE_KEY of variables.env with the tunnel on: a new one when it is empty (also for a
# variables.env of an earlier MCloud), kept afterwards; fails for a value that is not a key and without the tools of
# the keys
ensure_wg_key() {
  local key
  if ! wg_on; then
    return 0
  fi
  key="$(wg_secret)"
  if [[ -n "$key" ]]; then
    if [[ ! "$key" =~ $WG_KEY_REGEX ]]; then
      ui_callout error "NODES_WG_PRIVATE_KEY of variables.env is not a WireGuard key (base64 of 32 bytes): empty it, ./zebrunner.sh start makes a new one; the nodes get its public key with a new invite (README.md#wireguard-tunnel-of-the-nodes)."
      return 1
    fi
    return 0
  fi
  if ! key="$(wg_new_key)"; then
    ui_callout error "The private key of the WireGuard tunnel is made with openssl (X25519, OpenSSL 1.1.1+) or python3, neither works here: install one of them (README.md#system-requirements)."
    return 1
  fi
  set_line variables.env "NODES_WG_PRIVATE_KEY=${key}"
  ui_ok "NODES_WG_PRIVATE_KEY of variables.env is a new private key of the WireGuard tunnel of the nodes"
}

# set_wg_settings: the values of .env derived from the settings of the tunnel (docker-compose.yml): NODES_ADDRESS (the
# ports of the nodes are published there), NODES_WG_ENDPOINT, NODES_WG_PUBLIC_KEY, NODES_WG_SERVER_ADDRESS; empty
# without the tunnel. The lines are added to the .env of an earlier MCloud
set_wg_settings() {
  local server=""
  local endpoint=""
  local public=""
  if wg_on && server="$(wg_server)"; then
    endpoint="$(wg_url_host):$(env_setting NODES_WG_PORT)"
    public="$(wg_secret | wg_public_key)"
  else
    server=""
  fi
  set_env_line NODES_ADDRESS "$server"
  set_env_line NODES_WG_ENDPOINT "$endpoint"
  set_env_line NODES_WG_PUBLIC_KEY "$public"
  set_env_line NODES_WG_SERVER_ADDRESS "$server"
}

# set_env_line <name> <value>: the line of a variable of .env, written only when it changes
set_env_line() {
  if ! grep -qx "${1}=${2}" .env; then
    set_line .env "${1}=${2}"
  fi
}

# write_private <file> <content>: a file readable for its owner only, written in place (the bind mount of its folder
# sees it); fails with the fix when it is not writable (e.g. written by root)
write_private() {
  # a new file is made for the owner only, an existing one keeps its inode
  if ! (umask 077 && printf '%s\n' "$2" 2> /dev/null > "$1"); then
    ui_callout error "${1} is not writable for $(id -un): remove it (rm -f ${1}) and run ./zebrunner.sh restart (README.md#troubleshooting)."
    return 1
  fi
  chmod 600 "$1"
}

# write_wireguard_files: the files of the service wireguard and of stf-api (configuration/wireguard): with the tunnel on
# the private key of the server and STF_TOKEN (readable for their owner only) and the --nodes-wg-* options of stf-api;
# empty without the tunnel, so an STF without these options, which refuses unknown ones, starts as before
write_wireguard_files() {
  local key=""
  local token=""
  local options=""
  if wg_on && [[ -n "$(env_setting NODES_WG_PUBLIC_KEY)" ]]; then
    key="$(wg_secret)"
    token="$(stf_token)"
    options="STF_API_NODES_WG_ENDPOINT=$(env_setting NODES_WG_ENDPOINT)
STF_API_NODES_WG_PUBLIC_KEY=$(env_setting NODES_WG_PUBLIC_KEY)
STF_API_NODES_WG_SERVER_ADDRESS=$(env_setting NODES_WG_SERVER_ADDRESS)
STF_API_NODES_WG_NETWORK=$(env_setting NODES_WG_NETWORK)"
  fi
  write_private "$WG_KEY_FILE" "$key" || return 1
  write_private "$WG_TOKEN_FILE" "$token" || return 1
  if ! {
    echo "# written by ./zebrunner.sh setup and start from the WireGuard settings of .env: the --nodes-wg-* options of"
    echo "# stf-api (README.md#wireguard-tunnel-of-the-nodes), none without the tunnel"
    if [[ -n "$options" ]]; then
      printf '%s\n' "$options"
    fi
  } 2> /dev/null > "$WG_STF_API_ENV"; then
    ui_callout error "${WG_STF_API_ENV} is not writable for $(id -un): remove it (rm -f ${WG_STF_API_ENV}) and run ./zebrunner.sh restart (README.md#troubleshooting)."
    return 1
  fi
}

# wg_invite_address <label>: the WireGuard address of an invite without one (the answer of GET /api/v1/nodes of stf_api in
# api_body): the address of the node of the label, otherwise the first host of NODES_WG_NETWORK after the server that
# is not the address of a node; fails when the network is full
wg_invite_address() {
  local label="$1"
  local network first last nodes line address number
  local used=" "
  network="$(env_setting NODES_WG_NETWORK)"
  read -r first last _ <<< "$(wg_network "$network")"
  # shellcheck disable=SC2154 # set by stf_api of zebrunner.sh
  nodes="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep '"label"')"
  while read -r line; do
    [[ -n "$line" ]] || continue
    address="$(json_value address <<< "$line")"
    if [[ "$(json_value label <<< "$line")" == "$label" ]] && wg_node_address "$network" "$address"; then
      echo "$address"
      return 0
    fi
    if number="$(wg_ip_int "$address")"; then
      used+="${number} "
    fi
  done <<< "$nodes"
  for ((number = first + 2; number < last; number++)); do
    if [[ "$used" != *" ${number} "* ]]; then
      wg_int_ip "$number"
      return 0
    fi
  done
  return 1
}
