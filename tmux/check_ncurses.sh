#!/usr/bin/env bash

# Check that the tmux server uses the ncurses (libtinfo) its binary is linked to, and not
# another one picked up via LD_LIBRARY_PATH (e.g. conda's), which crashes tmux 3.2a on
# every copy, see tmux-wrapper.sh. Linux only, does nothing elsewhere.
#
# Usage: check_ncurses.sh [-S socket] [--notify]
#   -S socket  server to check (default: the one from $TMUX, or the default one)
#   --notify   also show the warning in tmux: now to attached clients, later on attach
# Prints a warning and exits 1 when the server has a foreign ncurses loaded, else exits 0

set -u

tmux_cmd=(tmux)
notify=0
while [ $# -gt 0 ]; do
  case "$1" in
    -S) tmux_cmd+=(-S "$2"); shift 2 ;;
    --notify) notify=1; shift ;;
    *) shift ;;
  esac
done

[ "$(uname -s)" = "Linux" ] && type ldd &>/dev/null || exit 0

# While tmux.conf loads on server start there are no sessions yet, and "display" fails,
# then take server pid from $TMUX ("socket,pid,session"), set for "run" jobs
pid=$("${tmux_cmd[@]}" display -p '#{pid}' 2>/dev/null)
if [ -z "$pid" ] && [ ${#tmux_cmd[@]} -eq 1 ] && [ -n "${TMUX-}" ]; then
  pid=$(cut -d, -f2 <<< "$TMUX")
fi
[ -n "$pid" ] && [ -r "/proc/$pid/maps" ] || exit 0

ncurses_libs='/lib(tinfo|ncurses)[^/]*[.]so'

# ncurses libs mapped in the server process (real paths, symlinks resolved)
loaded=$(awk -v re="$ncurses_libs" '$6 ~ re { print $6 }' "/proc/$pid/maps" | sort -u)
# ncurses libs the tmux binary resolves to without LD_LIBRARY_PATH
expected=$(env -u LD_LIBRARY_PATH -u LD_PRELOAD ldd "/proc/$pid/exe" 2>/dev/null |
  awk -v re="$ncurses_libs" '$2 == "=>" && $3 ~ re { print $3 }' |
  while read -r lib; do readlink -f "$lib"; done | sort -u)

# Can't tell what's expected, don't guess
[ -n "$loaded" ] && [ -n "$expected" ] || exit 0

foreign=$(comm -23 <(printf "%s\n" "$loaded") <(printf "%s\n" "$expected") | paste -sd ' ' -)
[ -n "$foreign" ] || exit 0

msg="tmux server (pid $pid) loaded $foreign instead of $(paste -sd ' ' - <<< "$expected"), \
likely via LD_LIBRARY_PATH (e.g. conda). Copying text can crash it. \
Restart it without LD_LIBRARY_PATH: tmux kill-server, then start tmux via ~/.local/bin/tmux"
printf "WARNING: %s\n" "$msg"

if [ "$notify" = 1 ]; then
  # Hooks: "tmux attach" fires client-attached, "tmux new" fires session-created (a
  # detached "tmux new -d" has no client to show it, that's fine). Index 90 keeps other
  # hooks. Delayed, as on "tmux new" the client isn't ready to show messages yet.
  # No "#" or quotes in msg, so it's safe as a format and inside quotes
  hook_cmd="run -bC -d 0.5 \"display-message -d 0 '${msg//[\'\"]/}'\""
  for hook in client-attached session-created; do
    "${tmux_cmd[@]}" set-hook -g "$hook[90]" "$hook_cmd"
  done
  "${tmux_cmd[@]}" list-clients -F '#{client_name}' 2>/dev/null |
    while read -r client; do
      "${tmux_cmd[@]}" display-message -c "$client" -d 0 "$msg" || true
    done
fi

exit 1
