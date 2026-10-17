#!/bin/bash
# The helpers of zebrunner.sh: the settings, random values, file edits and the questions to the user.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

# export_settings: saves the ZBR* variables of the setup into backup/settings.env for the next setup
export_settings() {
  export -p | grep "ZBR" > backup/settings.env
}

# random_string [<length>]: letters and digits, 48 of them by default
random_string() {
  local length=48
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    length="$1"
  fi
  local result=""
  # finite chunks of /dev/urandom: with SIGPIPE ignored (e.g. CI runners) `tr < /dev/urandom | head` never ends;
  # LC_ALL=C as tr fails on random bytes with a UTF-8 locale
  while [[ ${#result} -lt $length ]]; do
    result+="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9')"
  done
  echo "${result:0:$length}"
}

# echo_warning <message>: a warning for the user
echo_warning() {
  echo "
      WARNING! $1"
}

# echo_telegram: where to get help
echo_telegram() {
  echo "
      For more help join telegram channel: https://t.me/zebrunner
      "
}

# replace <file> <old> <new>: replaces every occurrence of a text in a file
replace() {
  local file="$1"
  local old="$2"
  local new="$3"
  local content
  content="$(< "$file")"
  # unquoted assignment and quoted replacement: & of the new text stays as it is in bash 5.2+ and in bash 3.2
  content=${content//"$old"/"$new"}
  printf '%s\n' "$content" > "$file"
}

# confirm <message> <question> <default y|n>: asks until the answer is y or n; 0 for y, 1 for n
confirm() {
  local message="$1"
  local question="$2"
  local default="$3"
  local response

  while true; do
    if [[ -n "$message" ]]; then
      echo "$message"
    fi

    read -r -p "${question} y/n [${default}]:" response
    if [[ -z "$response" ]]; then
      response="$default"
    fi

    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      return 0
    fi

    if [[ "$response" == "n" || "$response" == "N" ]]; then
      return 1
    fi

    echo "Please answer y (yes) or n (no)."
    echo
  done
}
