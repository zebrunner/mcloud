# What adb-relay does with the device lines of devices.awk (relay_devices of adb-relay.sh): a line per Android device of
# an active node of STF, present or not (the node refuses the port of an absent one),
# `relay|<port>|<address>|<serial>|<label>` or `skip|<port>|<address>|<serial>|<label>|<reason>`; the variables first,
# last, reserved, busy and current are the arguments of relay_devices. mawk and BSD awk run it.

BEGIN {
  FS = "|"
  reserved_count = split(reserved, ranges, " ")
  busy_count = split(busy, busy_list, " ")
  for (k = 1; k <= busy_count; k++) in_use[busy_list[k] + 0] = 1
  # the devices the relay has: <port>/<serial>/<label>
  current_count = split(current, current_list, " ")
  for (k = 1; k <= current_count; k++) {
    relayed_now[current_list[k]] = 1
    split(current_list[k], current_fields, "/")
    relayed_port[current_fields[1] + 0] = 1
  }
}
# reserved_port <port>: the port is one of the ports not to relay
function reserved_port(port, k, bounds) {
  for (k = 1; k <= reserved_count; k++) {
    if (split(ranges[k], bounds, "-") == 1) bounds[2] = bounds[1]
    if (port >= bounds[1] + 0 && port <= bounds[2] + 0) return 1
  }
  return 0
}
# node_address <address>: an IPv4 address or a host name, not of this server or of the link (the registry of STF
# refuses them too: the relay is in the network of the host)
function node_address(address, octets) {
  if (address ~ /^[0-9.]+$/) {
    if (address !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || split(address, octets, ".") != 4) return 0
    if (octets[1] + 0 > 255 || octets[2] + 0 > 255 || octets[3] + 0 > 255 || octets[4] + 0 > 255) return 0
    if (octets[1] + 0 == 0 || octets[1] + 0 == 127 || octets[1] + 0 >= 224) return 0
    if (octets[1] + 0 == 169 && octets[2] + 0 == 254) return 0
    return 1
  }
  if (address == "localhost" || address ~ /\.localhost$/) return 0
  return address ~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/
}
# before <a> <b>: the device a (index) comes before b for a port of two devices: the one the relay has, then the first
# by the label of its node and its serial, so a node cannot take the port of a device of another node
function before(a, b) {
  if (keep[a] != keep[b]) return keep[a]
  return order[a] < order[b]
}
{
  serial = $1
  label = $2
  address = $3
  port = ($4 ~ /^[0-9]+$/) ? $4 + 0 : ""
  reason = ""
  if (port == "") reason = "no remote debug port in STF"
  else if (!node_address(address)) reason = "the address " address " of its node is not one to relay to"
  else if (port < 1024 || port > 65535) reason = "the port is not 1024-65535"
  else if (first == "") reason = "ADB_RELAY_PORTS is not set: no port is relayed"
  else if (port < first + 0 || port > last + 0) reason = "the port is not in ADB_RELAY_PORTS " first "-" last
  else if (reserved_port(port)) reason = "the port is one of MCloud"
  else if ((port in in_use) && !(port in relayed_port)) reason = "the port is in use by another program of this server"
  lines++
  line[lines] = port "|" address "|" serial "|" label
  why[lines] = reason
  keep[lines] = ((port "/" serial "/" label) in relayed_now) ? 1 : 0
  order[lines] = label "|" serial
  if (reason == "" && (!(port in winner) || before(lines, winner[port]))) winner[port] = lines
}
END {
  for (k = 1; k <= lines; k++) {
    split(line[k], fields, "|")
    # e.g. two devices of two nodes with one port: one of them is relayed, the other one is skipped
    if (why[k] == "" && winner[fields[1]] != k) {
      split(line[winner[fields[1]]], first_fields, "|")
      why[k] = "the port is the one of the device " first_fields[3] " of the node " first_fields[4] \
        ", relayed instead: change connect_port of mcloud-agent of one of them"
    }
    if (why[k] == "") print "relay|" line[k]
    else print "skip|" line[k] "|" why[k]
  }
}
