#!/bin/bash
# The completion of zebrunner.sh (mcloud, mcloud-agent) and zebrunner-farm in bash and zsh (CONVENTIONS.md#completion):
#   bash: eval "$(./zebrunner.sh completion bash)" in ~/.bashrc, or this file in a bash-completion folder
#   zsh:  eval "$(./zebrunner.sh completion zsh)" in ~/.zshrc (bashcompinit)
# Every program answers `<program> __complete <index> <words...>` with its candidates, one per line: the words after
# the program, the index of the one to complete (1 is the first one after the program). It answers at once and
# changes nothing (no docker, no network, no file written). The completion runs only a program of the current user or
# of root that others cannot write: a TAB in a strange folder does not run its zebrunner.sh.
# Compatible with the macOS system bash 3.2 (CONVENTIONS.md).

# _zebrunner_program <word>: the path of the program of the command line, nothing when it may not run
_zebrunner_program() {
  local program="$1"
  # a path as typed: ~ is not expanded in the command line
  # shellcheck disable=SC2088
  if [[ "$program" == "~/"* ]]; then
    program="${HOME}/${program#\~/}"
  fi
  if [[ "$program" != */* ]]; then
    program="$(command -v "$program" 2> /dev/null)" || return 1
  fi
  [[ -f "$program" && -x "$program" ]] || return 1
  # owned by the current user or by root, not writable by the group or the others
  [[ -n "$(find "$program" -maxdepth 0 \( -user "$(id -u)" -o -user 0 \) ! -perm -g+w ! -perm -o+w 2> /dev/null)" ]] ||
    return 1
  printf '%s\n' "$program"
}

# _zebrunner_complete: the completion function of bash (complete -F), the words from COMP_LINE: the word breaks of
# bash (: and =) split no udid (192.168.1.50:5555) and no option
_zebrunner_complete() {
  # zsh (bashcompinit): the arrays from 0 and the word splitting of bash
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    emulate -L ksh
  fi
  COMPREPLY=()
  local line="${COMP_LINE:0:$COMP_POINT}"
  # the words split at the spaces without read -a (zsh has read -A) and without the expansion of the globs
  local words=()
  local rest="$line"
  local word
  while true; do
    rest="${rest#"${rest%%[! ]*}"}"
    [[ -n "$rest" ]] || break
    word="${rest%% *}"
    words+=("$word")
    rest="${rest#"$word"}"
  done
  [[ "${#words[@]}" -ge 1 ]] || return 0
  local index=$((${#words[@]} - 1))
  local current="${words[$index]}"
  # after a space: a new word
  if [[ "$line" == *" " ]]; then
    index=${#words[@]}
    current=""
    words+=("")
  fi
  [[ "$index" -ge 1 ]] || return 0
  local program
  program="$(_zebrunner_program "${words[0]}")" || return 0
  local candidates candidate
  candidates="$("$program" __complete "$index" "${words[@]:1}" 2> /dev/null)" || return 0
  # the part of the current word before the word of bash (after its last : or =), not in the reply
  local skip=$((${#current} - ${#COMP_WORDS[COMP_CWORD]}))
  [[ "$skip" -ge 0 ]] || skip=0
  while IFS= read -r candidate; do
    if [[ -n "$candidate" && "$candidate" == "$current"* ]]; then
      COMPREPLY+=("${candidate:$skip}")
    fi
  done <<< "$candidates"
}

# zsh: complete of bashcompinit, which needs compdef of compinit (usually loaded by ~/.zshrc already)
if [[ -n "${ZSH_VERSION:-}" ]]; then
  if ! whence compdef > /dev/null 2>&1; then
    autoload -U +X compinit && compinit -i
  fi
  autoload -U +X bashcompinit && bashcompinit
fi
complete -o default -F _zebrunner_complete zebrunner.sh ./zebrunner.sh zebrunner-farm
