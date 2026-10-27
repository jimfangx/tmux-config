#!/usr/bin/env sh

# Print the command line of the foreground job running in a pane, for the status bar
# (tmux's #{pane_current_command} only has the program name, "tail" for "tail -f x.log")
# Usage: pane_cmd.sh <pane_tty> [max_length]

tty="${1#/dev/}"
max="${2:-40}"

# Foreground process group leader is the process whose pid equals the tty's
# foreground process group id: the shell itself when idle, or the first command of a pipeline
ps -t "$tty" -o pid=,tpgid=,args= 2>/dev/null | awk -v max="$max" '
  $1 == $2 {
    sub(/^ *[0-9]+ +[0-9]+ +/, "")
    sub(/^-/, "")             # login shell, "-zsh"
    sub(/^[^ ]*\//, "")       # strip path of the program, keep its arguments
    if (length($0) > max) $0 = substr($0, 1, max - 1) "…"
    print
    exit
  }'
