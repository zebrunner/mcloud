#!/bin/bash
# The terminal output of the host scripts (CONVENTIONS.md#terminal-output): the banner, the sections, the statuses, the
# callouts, the prompts, the help and the spinner of zebrunner.sh of mcloud and mcloud-agent; sourced: . patch/ui.sh
# The colors: on a terminal without NO_COLOR and TERM=dumb, UI_COLOR=always|never overrides it. The Unicode glyphs: with
# a UTF-8 locale, UI_ASCII=true forces the ASCII ones. This file is ASCII, the glyphs are the bytes of their UTF-8.
# Compatible with the macOS system bash 3.2 (CONVENTIONS.md).

# the UI_ variables are used by the scripts that source this file
# shellcheck disable=SC2034

# ui_rgb <38|48> <r> <g> <b> <xterm-256>: the escape of a foreground (38) or background (48) color, 24-bit when the
# terminal has it (COLORTERM)
ui_rgb() {
  case "${COLORTERM:-}" in
  truecolor | 24bit) printf '\033[%s;2;%s;%s;%sm' "$1" "$2" "$3" "$4" ;;
  *) printf '\033[%s;5;%sm' "$1" "$5" ;;
  esac
}

# ui_init: the colors, the glyphs and the width for the stdout and the locale; sourcing runs it, a script runs it again
# after it redirects its stdout
ui_init() {
  # 1 when the last output of ui.sh ended with an empty line (a section, a paragraph): a callout adds no other one
  UI_BLANK=0
  UI_TTY=0
  if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    UI_TTY=1
  fi
  UI_COLOR_ON=0
  case "${UI_COLOR:-auto}" in
  always) UI_COLOR_ON=1 ;;
  never) ;;
  *) if [[ "$UI_TTY" -eq 1 && -z "${NO_COLOR:-}" ]]; then UI_COLOR_ON=1; fi ;;
  esac

  UI_RESET="" UI_BOLD="" UI_INVERSE="" UI_ACCENT="" UI_OK="" UI_WARN="" UI_FAIL="" UI_MUTED="" UI_DARK=""
  UI_BADGE="" UI_BADGE_OK="" UI_BADGE_WARN="" UI_BADGE_FAIL=""
  if [[ "$UI_COLOR_ON" -eq 1 ]]; then
    local black
    black="$(ui_rgb 38 10 10 10 232)"
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_INVERSE=$'\033[7m'
    UI_ACCENT="$(ui_rgb 38 163 230 53 148)"
    UI_OK="$(ui_rgb 38 74 222 128 78)"
    UI_WARN="$(ui_rgb 38 251 191 36 214)"
    UI_FAIL="$(ui_rgb 38 248 113 113 203)"
    UI_MUTED="$(ui_rgb 38 120 120 135 244)"
    UI_DARK="$(ui_rgb 38 70 70 80 239)"
    UI_BADGE="$(ui_rgb 48 163 230 53 148)${black}${UI_BOLD}"
    UI_BADGE_OK="$(ui_rgb 48 74 222 128 78)${black}${UI_BOLD}"
    UI_BADGE_WARN="$(ui_rgb 48 251 191 36 214)${black}${UI_BOLD}"
    UI_BADGE_FAIL="$(ui_rgb 48 248 113 113 203)${black}${UI_BOLD}"
  fi

  UI_UNICODE=0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UNICODE=1 ;;
  esac
  if [[ "${UI_ASCII:-false}" == "true" ]]; then
    UI_UNICODE=0
  fi
  if [[ "$UI_UNICODE" -eq 1 ]]; then
    # U+2501 heavy line, U+2500 thin line, U+25CF black circle, U+25CB white circle, U+2514 U+2500 the branch of a
    # fix, U+2503 heavy bar, U+25B8 pointer, U+00B7 middle dot, U+280B... the braille spinner
    UI_HEAVY=$'\xe2\x94\x81'
    UI_THIN=$'\xe2\x94\x80'
    UI_DOT=$'\xe2\x97\x8f'
    UI_CIRCLE=$'\xe2\x97\x8b'
    UI_BRANCH=$'\xe2\x94\x94\xe2\x94\x80'
    UI_BAR=$'\xe2\x94\x83'
    UI_POINTER=$'\xe2\x96\xb8'
    UI_SEP=$'\xc2\xb7'
    UI_SPINNER=$'\xe2\xa0\x8b \xe2\xa0\x99 \xe2\xa0\xb9 \xe2\xa0\xb8 \xe2\xa0\xbc \xe2\xa0\xb4 \xe2\xa0\xa6 \xe2\xa0\xa7 \xe2\xa0\x87 \xe2\xa0\x8f'
  else
    UI_HEAVY="="
    UI_THIN="-"
    UI_DOT="*"
    UI_CIRCLE="o"
    UI_BRANCH="\`-"
    UI_BAR="|"
    UI_POINTER=">"
    UI_SEP="-"
    UI_SPINNER="| / - \\"
  fi

  # the width of the content: the terminal (COLUMNS, tput) up to 80 columns, 2 columns of margin on each side
  local cols="${COLUMNS:-}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="$(tput cols 2> /dev/null)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$cols" -le 80 ]] || cols=80
  UI_WIDTH=$((cols - 4))
  [[ "$UI_WIDTH" -ge 40 ]] || UI_WIDTH=40
}

# ui_repeat <text> <count>: the text repeated
ui_repeat() {
  local out=""
  local i=0
  while [[ "$i" -lt "$2" ]]; do
    out+="$1"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ui_pad <text> <width>: the text with spaces up to the width, with one space when it is longer
ui_pad() {
  local n=$(($2 - ${#1}))
  [[ "$n" -ge 1 ]] || n=1
  printf '%s%s' "$1" "$(ui_repeat ' ' "$n")"
}

# ui_upper <text>: the text in upper case
ui_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# ui_wrap <text> <width>: the text wrapped at the spaces to the width, one line per line; the lines of the text stay
# lines, a line within the width stays as it is (the spaces of its columns), a longer word (a path, a URL, a command)
# stays whole on its own line, so it can be copied
ui_wrap() {
  local text line word
  local words=()
  while IFS= read -r text || [[ -n "$text" ]]; do
    if [[ ${#text} -le "$2" ]]; then
      printf '%s\n' "$text"
      continue
    fi
    line=""
    words=()
    # the words without the expansion of the globs (e.g. a * of a message)
    read -r -a words <<< "$text"
    for word in ${words[@]+"${words[@]}"}; do
      if [[ -z "$line" ]]; then
        line="$word"
      elif [[ $((${#line} + 1 + ${#word})) -le "$2" ]]; then
        line+=" ${word}"
      else
        printf '%s\n' "$line"
        line="$word"
      fi
    done
    printf '%s\n' "$line"
  done <<< "$1"
}

# ui_hang <first prefix> <width of the prefix> <text> <width>: the text wrapped to the width after the prefix, the next
# lines indented by the width of the prefix
ui_hang() {
  local head="$1"
  local line
  while IFS= read -r line; do
    printf '%s%s\n' "$head" "$line"
    head="$(ui_repeat ' ' "$2")"
  done <<< "$(ui_wrap "$3" "$4")"
}

# ui_badge <text> [<colors>]: the text on the accent (or the colors), '[ text ]' without colors
ui_badge() {
  if [[ "$UI_COLOR_ON" -eq 1 ]]; then
    printf '%s %s %s' "${2:-$UI_BADGE}" "$1" "$UI_RESET"
  else
    printf '[ %s ]' "$1"
  fi
}

# ui_badge_width <text>: the columns of the badge of the text
ui_badge_width() {
  if [[ "$UI_COLOR_ON" -eq 1 ]]; then
    echo $((${#1} + 2))
  else
    echo $((${#1} + 4))
  fi
}

# ui_banner <product> [<version>]: the badge ZEBRUNNER, the product and the version at the right, a heavy line under
ui_banner() {
  local version="${2:-}"
  printf '\n  %s %s%s%s' "$(ui_badge ZEBRUNNER)" "$UI_BOLD" "$1" "$UI_RESET"
  if [[ -n "$version" ]]; then
    local gap=$((UI_WIDTH - $(ui_badge_width ZEBRUNNER) - 1 - ${#1} - ${#version}))
    [[ "$gap" -ge 1 ]] || gap=1
    printf '%s%s%s%s' "$(ui_repeat ' ' "$gap")" "$UI_MUTED" "$version" "$UI_RESET"
  fi
  printf '\n  %s%s%s\n' "$UI_ACCENT" "$(ui_repeat "$UI_HEAVY" "$UI_WIDTH")" "$UI_RESET"
  UI_BLANK=0
}

# ui_section <title> [<counter>] [<detail>]: the title as a badge, a thin line and the counter (e.g. 1/3) at the
# right, an empty line; the detail (e.g. a folder) muted under it, then an empty line
ui_section() {
  local title counter="${2:-}"
  title="$(ui_upper "$1")"
  local line=$((UI_WIDTH - $(ui_badge_width "$title") - 1))
  if [[ -n "$counter" ]]; then
    line=$((line - ${#counter} - 1))
  fi
  [[ "$line" -ge 3 ]] || line=3
  printf '\n  %s %s%s%s' "$(ui_badge "$title")" "$UI_DARK" "$(ui_repeat "$UI_THIN" "$line")" "$UI_RESET"
  if [[ -n "$counter" ]]; then
    printf ' %s%s%s' "$UI_MUTED" "$counter" "$UI_RESET"
  fi
  printf '\n\n'
  if [[ -n "${3:-}" ]]; then
    local detail
    while IFS= read -r detail; do
      printf '  %s%s%s\n' "$UI_MUTED" "$detail" "$UI_RESET"
    done <<< "$(ui_wrap "$3" "$UI_WIDTH")"
    printf '\n'
  fi
  UI_BLANK=1
}

# ui_rule: a thin line over the width
ui_rule() {
  printf '  %s%s%s\n' "$UI_DARK" "$(ui_repeat "$UI_THIN" "$UI_WIDTH")" "$UI_RESET"
  UI_BLANK=0
}

# ui_status <ok|info|warn|fail> <message> [<fix>]: a colored dot (the word without colors), the message and the fix
# under it, both wrapped to the width under themselves
ui_status() {
  local mark
  local mark_width=1
  if [[ "$UI_COLOR_ON" -eq 1 ]]; then
    case "$1" in
    ok) mark="${UI_OK}${UI_DOT}" ;;
    warn) mark="${UI_WARN}${UI_DOT}" ;;
    fail) mark="${UI_FAIL}${UI_DOT}" ;;
    *) mark="${UI_MUTED}${UI_CIRCLE}" ;;
    esac
    mark+="$UI_RESET"
  else
    mark_width=4
    case "$1" in
    ok) mark="ok  " ;;
    warn) mark="warn" ;;
    fail) mark="FAIL" ;;
    *) mark="info" ;;
    esac
  fi
  local indent=$((3 + mark_width + 1))
  ui_hang "   ${mark} " "$indent" "$2" $((UI_WIDTH + 2 - indent))
  if [[ -n "${3:-}" ]]; then
    # '     <branch> fix ': 12 columns, the branch is 2 of them in Unicode and in ASCII
    ui_hang "     ${UI_MUTED}${UI_BRANCH}${UI_RESET} ${UI_BOLD}fix${UI_RESET} " 12 "$3" $((UI_WIDTH + 2 - 12))
  fi
  UI_BLANK=0
}

# ui_ok <message>: a passed check or a done step
ui_ok() {
  ui_status ok "$@"
}

# ui_info <message>: a fact, not a problem
ui_info() {
  ui_status info "$@"
}

# ui_warn <message> [<fix>]: a problem that may break something
ui_warn() {
  ui_status warn "$@"
}

# ui_fail <message> [<fix>]: a problem that breaks something
ui_fail() {
  ui_status fail "$@"
}

# ui_callout <warn|error|note> <text> [<title>]: an empty line (not after a section or a paragraph), then a bar at the
# left of the title (WARNING, ERROR, NOTE by default) and of the text wrapped to the width
ui_callout() {
  local color title line
  case "$1" in
  error) color="$UI_FAIL" title="ERROR" ;;
  note) color="$UI_ACCENT" title="NOTE" ;;
  *) color="$UI_WARN" title="WARNING" ;;
  esac
  title="${3:-$title}"
  if [[ "$UI_BLANK" -ne 1 ]]; then
    printf '\n'
  fi
  printf '  %s%s%s %s%s%s%s\n' "$color" "$UI_BAR" "$UI_RESET" "$color" "$UI_BOLD" "$title" "$UI_RESET"
  while IFS= read -r line; do
    printf '  %s%s%s %s\n' "$color" "$UI_BAR" "$UI_RESET" "$line"
  done <<< "$(ui_wrap "$2" $((UI_WIDTH - 2)))"
  UI_BLANK=0
}

# ui_paragraph <text>: a paragraph wrapped to the width, an empty line after it
ui_paragraph() {
  ui_hang "  " 2 "$1" "$UI_WIDTH"
  printf '\n'
  UI_BLANK=1
}

# ui_step <number> <text>: a numbered step of a list, the text wrapped under itself, an empty line after it
ui_step() {
  local number="${1}."
  ui_hang "   ${UI_ACCENT}${number}${UI_RESET} " $((4 + ${#number})) "$2" $((UI_WIDTH - 2 - ${#number}))
  printf '\n'
  UI_BLANK=1
}

# ui_table_head <text>: the header of a table muted, the same text without colors (the rows are printf of the caller)
ui_table_head() {
  printf '%s%s%s\n' "$UI_MUTED" "$1" "$UI_RESET"
  UI_BLANK=0
}

# ui_muted <text>: a line of secondary text, e.g. where to get help
ui_muted() {
  printf '  %s%s%s\n' "$UI_MUTED" "$1" "$UI_RESET"
  UI_BLANK=0
}

# ui_prompt <question> [<hint>]: the prompt of read -p, without a newline:
# read -r -p "$(ui_prompt "Start now?" "[Y/n]")" answer
ui_prompt() {
  printf '  %s%s%s %s' "$UI_ACCENT" "$UI_POINTER" "$UI_RESET" "$1"
  if [[ -n "${2:-}" ]]; then
    printf ' %s%s%s' "$UI_MUTED" "$2" "$UI_RESET"
  fi
  printf ' '
}

# ui_usage <command line>: the first line of a help, e.g. ui_usage "./zebrunner.sh <command> [options]"
ui_usage() {
  printf '\n  %s%s%s %s%s%s\n' "$UI_ACCENT" "$UI_POINTER" "$UI_RESET" "$UI_BOLD" "$1" "$UI_RESET"
  UI_BLANK=0
}

# ui_help_group <name>: the title of a group of commands of a help
ui_help_group() {
  printf '\n  %s\n' "$(ui_badge "$(ui_upper "$1")" "$UI_INVERSE")"
  UI_BLANK=0
}

# ui_help_cmd <command> <arguments> <description>: a command of a help; the description is wrapped under itself, it
# starts on the next line after long arguments
ui_help_cmd() {
  local cmd_width=12
  local args_width=20
  local indent=$((3 + cmd_width + args_width))
  local desc_width=$((UI_WIDTH + 2 - indent))
  [[ "$desc_width" -ge 20 ]] || desc_width=20
  local head line
  if [[ ${#1} -ge "$cmd_width" || ${#2} -ge "$args_width" ]]; then
    head="   ${UI_BOLD}${1}${UI_RESET}"
    if [[ -n "$2" ]]; then
      head+=" ${UI_MUTED}${2}${UI_RESET}"
    fi
    printf '%s\n' "$head"
    head="$(ui_repeat ' ' "$indent")"
  else
    head="$(printf '   %s%s%s%s%s%s' "$UI_BOLD" "$(ui_pad "$1" "$cmd_width")" "$UI_RESET" "$UI_MUTED" \
      "$(ui_pad "$2" "$args_width")" "$UI_RESET")"
  fi
  while IFS= read -r line; do
    printf '%s%s\n' "$head" "$line"
    head="$(ui_repeat ' ' "$indent")"
  done <<< "$(ui_wrap "$3" "$desc_width")"
  UI_BLANK=0
}

# ui_summary <passed> <warnings> <problems>: an empty line, a thin line and the counts as badges
ui_summary() {
  printf '\n'
  ui_rule
  if [[ "$UI_COLOR_ON" -eq 1 ]]; then
    printf '  %s %s %s\n' "$(ui_badge "$1 OK" "$UI_BADGE_OK")" "$(ui_badge "$2 WARN" "$UI_BADGE_WARN")" \
      "$(ui_badge "$3 FAIL" "$UI_BADGE_FAIL")"
  else
    printf '  %s ok, %s warn, %s fail\n' "$1" "$2" "$3"
  fi
  UI_BLANK=0
}

# ui_spin <message> <command...>: runs a command that needs no input with a spinner on a terminal, then ui_ok or
# ui_fail with the output of the command; the status of the command
ui_spin() {
  local message="$1"
  shift
  local output status pid
  local i=0
  local frames
  read -r -a frames <<< "$UI_SPINNER"
  output="$(mktemp)"
  if [[ "$UI_TTY" -eq 1 ]]; then
    "$@" > "$output" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null; do
      printf '\r\033[K   %s%s%s %s' "$UI_ACCENT" "${frames[$((i % ${#frames[@]}))]}" "$UI_RESET" "$message"
      i=$((i + 1))
      sleep 0.1
    done
    wait "$pid"
    status=$?
    printf '\r\033[K'
  else
    "$@" > "$output" 2>&1
    status=$?
  fi
  if [[ "$status" -eq 0 ]]; then
    ui_ok "$message"
  else
    ui_fail "$message"
    sed 's/^/     /' "$output"
  fi
  rm -f "$output"
  return "$status"
}

ui_init
