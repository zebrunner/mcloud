# The devices of a JSON answer of GET /api/v1/nodes/relay of STF, the Android devices bound to an active node, a line
# per device (devices_of_json of adb-relay.sh): <serial>|<label of the node>|<address of the node>|<connectPort>; exits
# with 1 when the answer has no devices. A small JSON reader for the fields of the devices: the nginx image has no jq;
# mawk and BSD awk run it.

# value <text>: a value of the JSON at the current depth, the fields of a device are kept
function value(text) {
  if (depth == 3 && in_devices()) {
    if (key[3] == "serial") serial = text
    else if (key[3] == "label") label = text
    else if (key[3] == "address") address = text
    else if (key[3] == "connectPort") connect = text
  }
}
# in_devices: the current value is in the array "devices" of the object of the answer
function in_devices() {
  return type[1] == "{" && key[1] == "devices" && type[2] == "["
}
{ text = text $0 "\n" }
END {
  n = length(text)
  i = 1
  while (i <= n) {
    c = substr(text, i, 1)
    if (c == "{" || c == "[") {
      depth++
      type[depth] = c
      key[depth] = ""
      want_key[depth] = (c == "{")
      if (depth == 2 && in_devices()) found = 1
      if (depth == 3 && in_devices()) serial = label = address = connect = ""
      i++
    } else if (c == "}" || c == "]") {
      if (depth == 3 && c == "}" && in_devices()) {
        # a serial and a label are only shown in the log: no separator, no control character; relay.awk checks the
        # address
        gsub(/[^A-Za-z0-9._:-]/, "_", serial)
        gsub(/[^A-Za-z0-9._:-]/, "_", label)
        gsub(/\|/, "%7C", address)
        print serial "|" label "|" address "|" connect
      }
      depth--
      i++
    } else if (c == ",") {
      if (type[depth] == "{") want_key[depth] = 1
      i++
    } else if (c == ":") {
      want_key[depth] = 0
      i++
    } else if (c == "\"") {
      # a string: an escaped character is taken as it is (\" and \\ and \/ as JSON has them)
      string = ""
      j = i + 1
      while (1) {
        chunk = substr(text, j, 512)
        quote = index(chunk, "\"")
        backslash = index(chunk, "\\")
        if (backslash > 0 && (quote == 0 || backslash < quote)) {
          string = string substr(chunk, 1, backslash - 1) substr(chunk, backslash + 1, 1)
          j += backslash + 1
        } else if (quote > 0) {
          string = string substr(chunk, 1, quote - 1)
          j += quote
          break
        } else if (chunk == "") {
          exit 1
        } else {
          string = string chunk
          j += 512
        }
      }
      i = j
      if (type[depth] == "{" && want_key[depth]) key[depth] = string
      else value(string)
    } else if (index(" \t\r\n", c) > 0) {
      i++
    } else {
      # a number, true, false or null
      j = i
      while (j <= n && index(",}] \t\r\n", substr(text, j, 1)) == 0) j++
      value(substr(text, i, j - i))
      i = j
    }
  }
  exit (found ? 0 : 1)
}
