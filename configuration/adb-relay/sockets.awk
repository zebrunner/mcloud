# The listening TCP sockets of /proc/net/tcp and /proc/net/tcp6 (stdin), a line per socket: `<port> <inode>`
# (listening_sockets of adb-relay.sh); the port is hex there. mawk and BSD awk run it (no strtonum).

# hex <text>: the number of a hex text, -1 for another text
function hex(text, k, n, digit) {
  n = 0
  for (k = 1; k <= length(text); k++) {
    digit = index("0123456789ABCDEF", toupper(substr(text, k, 1))) - 1
    if (digit < 0) return -1
    n = n * 16 + digit
  }
  return n
}
# the state 0A is LISTEN; the local address is <address>:<port>
$4 == "0A" {
  split($2, local, ":")
  print hex(local[2]), $10
}
