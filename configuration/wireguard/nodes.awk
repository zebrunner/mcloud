# The nodes of a JSON answer of GET /api/v1/nodes of STF, a line per node (nodes_of_json of wireguard.sh):
# <label>|<status>|<address>|<wgPublicKey>, an empty field for a missing or null value; exits with 1 when the answer has
# no nodes. The JSON reader of configuration/adb-relay/devices.awk for the fields of the nodes: no jq is needed, mawk
# and BSD awk run it (tests/wireguard_test.sh).

# value <text>: a value of the JSON at the current depth, the fields of a node are kept
function value(text) {
  if (text == "null") text = ""
  if (depth == 3 && in_nodes()) {
    if (key[3] == "label") label = text
    else if (key[3] == "status") status = text
    else if (key[3] == "address") address = text
    else if (key[3] == "wgPublicKey") wg_key = text
  }
}
# in_nodes: the current value is in the array "nodes" of the object of the answer
function in_nodes() {
  return type[1] == "{" && key[1] == "nodes" && type[2] == "["
}
# field <text>: a field of the line: no separator, no control character (wireguard.sh checks the values)
function field(text) {
  gsub(/[^A-Za-z0-9._:\/+=-]/, "_", text)
  return text
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
      if (depth == 2 && in_nodes()) found = 1
      if (depth == 3 && in_nodes()) label = status = address = wg_key = ""
      i++
    } else if (c == "}" || c == "]") {
      if (depth == 3 && c == "}" && in_nodes()) {
        print field(label) "|" field(status) "|" field(address) "|" field(wg_key)
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
