#!/bin/bash
# The helpers of zebrunner.sh: the settings, random values, file edits and the questions to the user; the messages are
# printed by patch/ui.sh, which the scripts source with this file. Keep it compatible with the macOS system bash 3.2
# (CONVENTIONS.md).

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

# echo_warning <message>: a warning for the user, a callout of patch/ui.sh
echo_warning() {
  ui_callout warn "$1"
}

# echo_telegram: where to get help
echo_telegram() {
  echo
  ui_muted "For more help join telegram channel: https://t.me/zebrunner"
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

# set_line <file> <name>=<value>: the line of a variable of an env file, added at its end when the file has none
set_line() {
  local file="$1"
  local line="$2"
  local current
  local found=0
  local content=""
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == "${line%%=*}="* ]]; then
      current="$line"
      found=1
    fi
    content+="${current}"$'\n'
  done < "$file"
  if [[ "$found" -eq 0 ]]; then
    content+="${line}"$'\n'
  fi
  printf '%s' "$content" > "$file"
}

# confirm <message> <question> <default y|n>: asks until the answer is y or n; 0 for y, 1 for n. The message (e.g. the
# values to confirm) is shown before the question, the hint of the question is [Y/n] or [y/N] by the default
confirm() {
  local message="$1"
  local question="$2"
  local default="$3"
  local hint="[y/N]"
  local response
  # the leading spaces of the question are of the earlier output style
  question="${question#"${question%%[![:space:]]*}"}"
  if [[ "$default" == "y" || "$default" == "Y" ]]; then
    hint="[Y/n]"
  fi

  while true; do
    if [[ -n "$message" ]]; then
      ui_info "$message"
    fi

    read -r -p "$(ui_prompt "$question" "$hint")" response
    if [[ -z "$response" ]]; then
      response="$default"
    fi

    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      return 0
    fi

    if [[ "$response" == "n" || "$response" == "N" ]]; then
      return 1
    fi

    ui_warn "Please answer y (yes) or n (no)."
  done
}
