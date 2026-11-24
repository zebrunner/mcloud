#!/bin/bash
# Tests of the completion of zebrunner.sh (CONVENTIONS.md#completion): the candidates of `__complete` per position,
# without side effects (docker and curl fail the test when called, no file is written), `completion bash|zsh` and the
# completion of patch/completion.sh in bash.
source "$(dirname "$0")/lib.sh"

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"
# the tools of the side effects: a call is recorded, the test fails on it
for tool in docker curl sudo openssl python3; do
  stub "$tool" "(IFS='|'; echo \"${tool}|\$*\") >> '${WORK}/calls.log'; exit 1"
done

# complete <index> <words...>: the candidates of zebrunner.sh of the copy on one line, stderr included, without the
# user's environment and without stdin
complete() {
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb \
    /bin/bash "${MCLOUD}/zebrunner.sh" __complete "$@" < /dev/null 2>&1 | tr '\n' ' ' | sed 's/ $//'
}

# files: the files of the copy with their modification times, to see that nothing is written
files() {
  (cd "$MCLOUD" && find . -exec ls -ld {} + | awk '{print $1, $5, $6, $7, $8, $9}' | sort)
}

commands="setup start stop restart down shutdown backup restore version doctor node-invite nodes help completion"

section "candidates"
before="$(files)"
start_time="$SECONDS"
reset_calls
check "the commands and the options of the first word" "${commands} --help -h" "$(complete 1 "")"
check "the first word with a prefix: every candidate, the shell keeps the ones of the prefix" \
  "${commands} --help -h" "$(complete 1 no)"
check "the subcommands of nodes" "list check revoke delete" "$(complete 2 nodes "")"
check "the labels of the nodes are not offered: only the STF API knows them" "" "$(complete 3 nodes check "")"
check "nothing after the label of a node" "" "$(complete 4 nodes revoke lab-1 "")"
check "the arguments of node-invite are free text" "" "$(complete 2 node-invite "")"
check "the address of node-invite is free text" "" "$(complete 3 node-invite lab-1 "")"
check "the commands of help" "$commands" "$(complete 2 help "")"
check "the shells of completion" "bash zsh" "$(complete 2 completion "")"
check "an option after a command: its help" "--help -h" "$(complete 2 shutdown -)"
check "an option after a subcommand: its help" "--help -h" "$(complete 3 nodes check --h)"
for command in setup start stop restart down shutdown backup restore version doctor; do
  check "nothing after ${command}" "" "$(complete 2 "$command" "")"
done
check "nothing after an unknown command" "" "$(complete 2 unknown "")"
check "nothing for an invalid index" "" "$(complete x setup)"
check "nothing for index 0" "" "$(complete 0 setup)"
check "nothing without an index" "" "$(complete)"
check "a word with a glob is not expanded" "" "$(complete 2 '*' "")"
env -i PATH="${WORK}/bin:/usr/bin:/bin" /bin/bash "${MCLOUD}/zebrunner.sh" __complete 1 "" > /dev/null 2>&1
check "__complete succeeds" "0" "$?"
check "__complete calls no tool (docker, curl, ...)" "" "$(cat "${WORK}/calls.log")"
check "__complete writes no file" "$before" "$(files)"
check "__complete answers at once" "yes" "$([[ $((SECONDS - start_time)) -le 10 ]] && echo yes)"

section "set up"
# a set-up copy: the completion still runs nothing of it
cp "${REPO}/.env.original" "${MCLOUD}/.env"
cp "${REPO}/variables.env.original" "${MCLOUD}/variables.env"
touch "${MCLOUD}/.disabled"
before="$(files)"
reset_calls
check "the commands of a set-up copy" "${commands} --help -h" "$(complete 1 "")"
check "the subcommands of nodes of a set-up copy" "list check revoke delete" "$(complete 2 nodes "")"
check "the labels of a set-up copy are not asked from the STF API" "" "$(complete 3 nodes check "")"
check "__complete of a set-up copy calls no tool" "" "$(cat "${WORK}/calls.log")"
check "__complete of a set-up copy writes no file" "$before" "$(files)"
rm -f "${MCLOUD}/.env" "${MCLOUD}/variables.env" "${MCLOUD}/.disabled"

section "completion bash|zsh"
for shell in bash zsh; do
  output="$(/bin/bash "${MCLOUD}/zebrunner.sh" completion "$shell" 2> "${WORK}/stderr")"
  check "completion ${shell} succeeds" "0" "$?"
  check "completion ${shell} prints patch/completion.sh" "$(cat "${REPO}/patch/completion.sh")" "$output"
  check "completion ${shell} prints no hint without a terminal" "" "$(cat "${WORK}/stderr")"
done
output="$(TERM=dumb /bin/bash "${MCLOUD}/zebrunner.sh" completion fish 2>&1)"
check "completion of another shell fails with 2" "2" "$?"
check_contains "completion of another shell names bash and zsh" "The completion is for bash or zsh." "$output"
TERM=dumb /bin/bash "${MCLOUD}/zebrunner.sh" completion > /dev/null 2>&1
check "completion without a shell fails with 2" "2" "$?"
check "completion calls no tool" "" "$(cat "${WORK}/calls.log")"

section "bash"
# patch/completion.sh in bash with the command line of a TAB in the folder of the copy
# tab <command line>: COMPREPLY of the completion of the line, on one line
tab() {
  (
    cd "$MCLOUD" || exit 1
    PATH="${WORK}/bin:${PATH}"
    # shellcheck source=../patch/completion.sh
    source "${REPO}/patch/completion.sh"
    COMP_LINE="$1"
    COMP_POINT=${#1}
    read -r -a COMP_WORDS <<< "$1"
    # after a space: a new empty word
    if [[ "$1" == *" " ]]; then
      COMP_WORDS+=("")
    fi
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    _zebrunner_complete
    echo "${COMPREPLY[*]}"
  )
}
chmod go-w "${MCLOUD}/zebrunner.sh"
check "a TAB completes a command" "node-invite nodes" "$(tab "./zebrunner.sh nod")"
check "a TAB completes a command of a common prefix" "restart restore" "$(tab "./zebrunner.sh re")"
check "a TAB after a space offers every command" "${commands} --help -h" "$(tab "./zebrunner.sh ")"
check "a TAB completes a subcommand of nodes" "check" "$(tab "./zebrunner.sh nodes ch")"
check "a TAB completes the shell of completion" "zsh" "$(tab "./zebrunner.sh completion z")"
chmod o+w "${MCLOUD}/zebrunner.sh"
check "a zebrunner.sh the others can write is not run" "" "$(tab "./zebrunner.sh nod")"
chmod o-w "${MCLOUD}/zebrunner.sh"
check "the completion calls no tool" "" "$(cat "${WORK}/calls.log")"

finish
