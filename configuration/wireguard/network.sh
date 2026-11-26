#!/bin/bash
# The IPv4 arithmetic of the WireGuard tunnel of the nodes (README.md#wireguard-tunnel-of-the-nodes): the network of
# NODES_WG_NETWORK, the address of the server (its first host) and the addresses of the nodes. Sourced by zebrunner.sh
# and by configuration/wireguard/wireguard.sh in the container, so the two agree on every address; keep it compatible
# with the macOS system bash 3.2 and with the bash of the alpine image.

# The docker networks of the devices on a node (mcloud-agent): the tunnel must not overlap them, the node would route
# the addresses of the tunnel into its device containers
WG_DEVICE_NETWORKS="10.233.0.0/16"
# a WireGuard key: base64 of 32 bytes (wg genkey, wg pubkey); used by the scripts sourcing this file
# shellcheck disable=SC2034
WG_KEY_REGEX='^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'

# wg_ip_int <address>: the 32-bit number of an IPv4 address, fails for another value
wg_ip_int() {
  local octets=()
  local octet
  if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  IFS='.' read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    if ((10#$octet > 255)); then
      return 1
    fi
  done
  echo $(((10#${octets[0]} << 24) + (10#${octets[1]} << 16) + (10#${octets[2]} << 8) + 10#${octets[3]}))
}

# wg_int_ip <number>: the IPv4 address of a 32-bit number
wg_int_ip() {
  echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

# wg_in_range <number> <first of a network> <prefix>: the address is in the network
wg_in_range() {
  local size=$((1 << (32 - $3)))
  (($1 >= $2 && $1 < $2 + size))
}

# wg_overlap <first> <prefix> <first> <prefix>: two networks share an address (the first addresses are the network
# addresses, so the larger network holds the other one or none of it)
wg_overlap() {
  local larger="$2"
  if (($4 < larger)); then
    larger="$4"
  fi
  local size=$((1 << (32 - larger)))
  (($1 / size == $3 / size))
}

# wg_network <cidr>: `<first> <last> <prefix>` of a network of the tunnel, <first> and <last> the numbers of its network
# and broadcast addresses; fails for a value that is not <network address>/<16-30> (no host bits) of a private range
# (10/8, 172.16/12, 192.168/16, 100.64/10: the addresses of the tunnel would hide public hosts otherwise) or that
# overlaps WG_DEVICE_NETWORKS
wg_network() {
  local address prefix first size device
  if [[ ! "$1" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
    return 1
  fi
  address="${BASH_REMATCH[1]}"
  prefix=$((10#${BASH_REMATCH[2]}))
  if ((prefix < 16 || prefix > 30)) || ! first="$(wg_ip_int "$address")"; then
    return 1
  fi
  size=$((1 << (32 - prefix)))
  if ((first % size != 0)); then
    return 1
  fi
  # a network of /16 or smaller is in a private range when its first address is
  if ! wg_in_range "$first" $((10 << 24)) 8 && ! wg_in_range "$first" $(((172 << 24) + (16 << 16))) 12 &&
    ! wg_in_range "$first" $(((192 << 24) + (168 << 16))) 16 && ! wg_in_range "$first" $(((100 << 24) + (64 << 16))) 10; then
    return 1
  fi
  for device in $WG_DEVICE_NETWORKS; do
    if wg_overlap "$first" "$prefix" "$(wg_ip_int "${device%/*}")" "${device#*/}"; then
      return 1
    fi
  done
  echo "$first $((first + size - 1)) $prefix"
}

# wg_server_address <cidr>: the WireGuard address of the server, the first host of the network
wg_server_address() {
  local network
  network="$(wg_network "$1")" || return 1
  wg_int_ip $((${network%% *} + 1))
}

# wg_node_address <cidr> <address>: succeeds for an address of a node in the network: not its network, broadcast or
# server address
wg_node_address() {
  local network first last number
  network="$(wg_network "$1")" || return 1
  number="$(wg_ip_int "$2")" || return 1
  read -r first last _ <<< "$network"
  ((number > first + 1 && number < last))
}
