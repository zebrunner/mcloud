#!/bin/bash
# Tests of patch/utility.sh: confirm, random_string, replace, export_settings and the messages.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
# shellcheck source=../patch/utility.sh
source patch/utility.sh

section "confirm"
# answer <stdin text> <default>: the exit code of confirm
answer() {
  printf '%b' "$1" | confirm "" "question?" "$2" > /dev/null
  echo "$?"
}
check "y confirms" "0" "$(answer 'y\n' n)"
check "Y confirms" "0" "$(answer 'Y\n' n)"
check "n declines" "1" "$(answer 'n\n' y)"
check "N declines" "1" "$(answer 'N\n' y)"
check "an empty answer takes the default y" "0" "$(answer '\n' y)"
check "an empty answer takes the default n" "1" "$(answer '\n' n)"
check "another answer is asked again" "0" "$(answer 'maybe\ny\n' n)"
check_contains "another answer is explained" "Please answer y (yes) or n (no)." "$(printf 'maybe\ny\n' | confirm "" "question?" n)"
check_contains "the message is shown" "the message" "$(printf 'y\n' | confirm "the message" "question?" n)"

section "random_string"
check "the default length" "48" "$(random_string | tr -d '\n' | wc -c | tr -d ' ')"
check "a custom length" "64" "$(random_string 64 | tr -d '\n' | wc -c | tr -d ' ')"
check "letters and digits only" "" "$(random_string 200 | tr -d 'a-zA-Z0-9\n')"
check "an invalid length takes the default" "48" "$(random_string abc | tr -d '\n' | wc -c | tr -d ' ')"
check "two strings differ" "different" "$([[ "$(random_string)" != "$(random_string)" ]] && echo different)"
# CI runners set a UTF-8 LC_ALL, tr fails on random bytes with it
[[ "$(uname)" == "Darwin" ]] && utf8=en_US.UTF-8 || utf8=C.UTF-8
check "a UTF-8 locale" "5" \
  "$(LC_ALL="$utf8" /bin/bash -c "source '${REPO}/patch/utility.sh'; random_string 5" 2> /dev/null | tr -d '\n' | wc -c | tr -d ' ')"

section "replace"
printf 'a=old\nb=old\n' > "${WORK}/file"
replace "${WORK}/file" "old" "new"
check "every occurrence is replaced" "a=new
b=new" "$(cat "${WORK}/file")"
check "the final newline is kept" "" "$(tail -c 1 "${WORK}/file")"
printf 'SECRET=password\n' > "${WORK}/file"
replace "${WORK}/file" "SECRET=password" 'SECRET=a&b\c'
check "the new text is taken as it is" 'SECRET=a&b\c' "$(cat "${WORK}/file")"

section "export_settings"
mkdir -p "${WORK}/settings/backup"
(
  cd "${WORK}/settings" || exit 1
  export ZBR_HOSTNAME=mcloud.example.com
  export OTHER=value
  export_settings
)
check_contains "the ZBR variables are saved" 'ZBR_HOSTNAME="mcloud.example.com"' "$(cat "${WORK}/settings/backup/settings.env")"
check_not_contains "the other variables are not saved" "OTHER" "$(cat "${WORK}/settings/backup/settings.env")"

section "messages"
check_contains "echo_warning prefix" "WARNING! text" "$(echo_warning text)"
check_contains "echo_telegram link" "https://t.me/zebrunner" "$(echo_telegram)"

finish
