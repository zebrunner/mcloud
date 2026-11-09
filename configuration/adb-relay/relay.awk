# What adb-relay does with the device lines of devices.awk (relay_devices of adb-relay.sh): a line per Android device of
# STF, present or not (the device host refuses the port of an absent one), `relay|<port>|<host>|<serial>` or `skip|<port>|<host>|<serial>|<reason>`; the variables agent_hosts, first,
# last and reserved are the arguments of relay_devices. mawk and BSD awk run it.

BEGIN {
  FS = "|"
  gsub(/ /, "", agent_hosts)
  count = split(agent_hosts, hosts, ",")
  for (k = 1; k <= count; k++) if (hosts[k] != "") agent[hosts[k]] = 1
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
$2 != "Android" { next }
{
  serial = $1
  url = $3
  screen = $4
  connect = $5
  host = ""
  if (match(url, /\/d\/[^\/]+\//)) host = substr(url, RSTART + 3, RLENGTH - 4)
  if (screen !~ /^[0-9]+$/) {
    path = url
    sub(/\/+$/, "", path)
    screen = ""
    if (match(path, /\/[0-9]+$/)) screen = substr(path, RSTART + 1)
  }
  port = ""
  if (connect ~ /^[0-9]+$/) port = connect + 0
  else if (screen ~ /^[0-9]+$/) port = screen + 1
  reason = ""
  if (host == "") reason = "no device host in its display URL"
  else if (port == "") reason = "no port in its display URL"
  else if (host !~ /^[A-Za-z0-9.-]+$/ || !(host in agent)) reason = "its device host " host " is not in AGENT_HOSTS"
  else if (port < 1024 || port > 65535) reason = "the port is not 1024-65535"
  else if (first != "" && (port < first + 0 || port > last + 0)) reason = "the port is not in ADB_RELAY_PORTS " first "-" last
  else if (reserved_port(port)) reason = "the port is one of MCloud or of ADB_RELAY_HOSTS"
  lines++
  line[lines] = port "|" host "|" serial
  why[lines] = reason
  if (reason == "") {
    devices[port]++
    owners[port] = owners[port] (owners[port] == "" ? "" : ", ") serial
  }
}
END {
  for (k = 1; k <= lines; k++) {
    split(line[k], fields, "|")
    # e.g. a stale device of STF and a new one with its port: the relay cannot tell which one is meant
    if (why[k] == "" && devices[fields[1]] > 1) {
      why[k] = "the port is the one of the devices " owners[fields[1]] " of STF, none of them is relayed: remove the gone" \
        " one in STF (Settings, Devices) or change connect_port of mcloud-agent"
    }
    if (why[k] == "") print "relay|" line[k]
    else print "skip|" line[k] "|" why[k]
  }
}
