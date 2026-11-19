#!/bin/bash
# Tests of patch/utility.sh: confirm, random_string, replace, set_line, export_settings and the messages.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
# shellcheck source=../patch/utility.sh
source patch/utility.sh
# shellcheck source=../patch/ui.sh
source patch/ui.sh
# the plain ASCII output, also when the tests run on a terminal with a UTF-8 locale
# shellcheck disable=SC2034 # read by ui_init
UI_COLOR=never UI_ASCII=true
ui_init

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
check "the message is a fact of patch/ui.sh" "   info the message" "$(printf 'y\n' | confirm "the message" "question?" n)"
# prompt_of <default> <question>: the arguments confirm gives ui_prompt, read -p shows its prompt on a terminal only
prompt_of() {
  (
    # the prompt of read -p, recorded on stderr
    # shellcheck disable=SC2329
    ui_prompt() {
      echo "$1|$2" >&2
    }
    { printf 'y\n' | confirm "" "$2" "$1" > /dev/null; } 2>&1
  )
}
check "the hint of the default y" "Start now?|[Y/n]" "$(prompt_of y "Start now?")"
check "the hint of the default n" "Do you want to continue?|[y/N]" "$(prompt_of n "Do you want to continue?")"
check "the leading spaces of the question are removed" "Start now?|[Y/n]" "$(prompt_of y "      Start now?")"
check "the prompt of patch/ui.sh" "  > Start now? [Y/n] " "$(UI_COLOR=never UI_ASCII=true bash -c 'source patch/ui.sh; ui_prompt "Start now?" "[Y/n]"')"

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

section "set_line"
printf 'A=1\nAB=2\n# A=3\n' > "${WORK}/file"
set_line "${WORK}/file" "A=x&y"
check "the line of the variable is replaced, not the ones of other names" "A=x&y
AB=2
# A=3" "$(cat "${WORK}/file")"
set_line "${WORK}/file" "C=new value"
check "a missing variable is added at the end" "C=new value" "$(tail -1 "${WORK}/file")"
printf 'A=1' > "${WORK}/file"
set_line "${WORK}/file" "A=2"
check "a last line without a newline" "A=2" "$(cat "${WORK}/file")"
check "the final newline is written" "" "$(tail -c 1 "${WORK}/file")"

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
check "echo_warning is a callout of patch/ui.sh" "
  | WARNING
  | text" "$(echo_warning text)"
check_not_contains "echo_warning has no WARNING! prefix" "WARNING!" "$(echo_warning text)"
check "echo_telegram link" "
  For more help join telegram channel: https://t.me/zebrunner" "$(echo_telegram)"

finish
