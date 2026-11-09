# What adb-relay does with the device lines of devices.awk (relay_devices of adb-relay.sh): a line per Android device of
# an active node of STF, present or not (the node refuses the port of an absent one),
# `relay|<port>|<address>|<serial>|<label>` or `skip|<port>|<address>|<serial>|<label>|<reason>`; the variables first,
# last and reserved are the arguments of relay_devices. mawk and BSD awk run it.

BEGIN {
  FS = "|"
  reserved_count = split(reserved, ranges, " ")
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
{
  serial = $1
  label = $2
  address = $3
  port = ($4 ~ /^[0-9]+$/) ? $4 + 0 : ""
  reason = ""
  if (port == "") reason = "no remote debug port in STF"
  else if (!node_address(address)) reason = "the address " address " of its node is not one to relay to"
  else if (port < 1024 || port > 65535) reason = "the port is not 1024-65535"
  else if (first != "" && (port < first + 0 || port > last + 0)) reason = "the port is not in ADB_RELAY_PORTS " first "-" last
  else if (reserved_port(port)) reason = "the port is one of MCloud or of ADB_RELAY_HOSTS"
  lines++
  line[lines] = port "|" address "|" serial "|" label
  why[lines] = reason
  if (reason == "") {
    devices[port]++
    owners[port] = owners[port] (owners[port] == "" ? "" : ", ") serial
  }
}
END {
  for (k = 1; k <= lines; k++) {
    split(line[k], fields, "|")
    # e.g. two devices of two nodes with one port: the relay cannot tell which one is meant
    if (why[k] == "" && devices[fields[1]] > 1) {
      why[k] = "the port is the one of the devices " owners[fields[1]] " of STF, none of them is relayed: change" \
        " connect_port of mcloud-agent of one of them"
    }
    if (why[k] == "") print "relay|" line[k]
    else print "skip|" line[k] "|" why[k]
  }
}
