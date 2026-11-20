#!/usr/bin/env bash

# tmux-config wrapper, install.sh links it as ~/.local/bin/tmux (Linux only).
# Runs the real tmux (next one in PATH) without LD_LIBRARY_PATH.
#
# Why: with LD_LIBRARY_PATH pointing at a dir with another ncurses (e.g. conda's
# $CONDA_PREFIX/lib), system tmux loads that libtinfo instead of the one it was built
# against. tmux 3.2a (Rocky Linux 9, built against ncurses 6.2) with conda's ncurses 6.5+
# segfaults on every copy (mouse drag, double click, "y"): tparm() returns NULL while
# building the OSC 52 clipboard sequence, and the whole server with all sessions dies.
#
# LD_LIBRARY_PATH is handed over in TMUX_CONFIG_LD_LIBRARY_PATH, and tmux.conf puts it
# back into the environment of new panes, so programs inside tmux see no difference.
# To stop using the wrapper: rm ~/.local/bin/tmux

self="${BASH_SOURCE[0]}"

IFS=: read -ra dirs <<< "$PATH"
for dir in "${dirs[@]}"; do
  bin="${dir:-.}/tmux"
  # Skip ourselves (-ef follows symlinks, i.e. ~/.local/bin/tmux -> this file)
  if [ -f "$bin" ] && [ -x "$bin" ] && ! [ "$bin" -ef "$self" ]; then
    if [ -n "${LD_LIBRARY_PATH-}" ]; then
      export TMUX_CONFIG_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
      unset LD_LIBRARY_PATH
    fi
    exec "$bin" "$@"
  fi
done

printf "tmux: command not found (tmux-config wrapper %s found no other tmux in PATH)\n" "$self" >&2
exit 127
