#!/usr/bin/env bash

# Safe to run multiple times: the first run installs, later runs pull in
# updates (this repo, TPM, plugins) and re-apply them.

set -e
set -u
set -o pipefail

is_app_installed() {
  type "$1" &>/dev/null
}

REPODIR="$(cd "$(dirname "$0")"; pwd -P)"
cd "$REPODIR";

if ! is_app_installed tmux; then
  printf "WARNING: \"tmux\" command is not found. \
Install it first\n"
  exit 1
fi

# Config needs tmux >= 3.2 (terminal-features, extended-keys). With 3.2 a few
# extras are skipped: cursor style, passthrough of escape sequences from apps
# "tmux 3.2a" -> "3 2", "tmux next-3.5" -> "3 5". Unknown formats (e.g. OpenBSD) aren't checked
tmux_version_at_least() {
  tmux -V | awk -v want_major="$1" -v want_minor="$2" '
    match($2, /[0-9]+\.[0-9]+/) {
      split(substr($2, RSTART, RLENGTH), v, ".")
      exit !(v[1] > want_major || (v[1] == want_major && v[2] >= want_minor))
    }'
}
if ! tmux_version_at_least 3 2; then
  printf "WARNING: $(tmux -V) is too old, this config needs tmux >= 3.2\n"
  exit 1
elif ! tmux_version_at_least 3 3; then
  printf "NOTE: $(tmux -V), some features need tmux >= 3.3 and are turned off: \
blinking bar cursor, passthrough of escape sequences from apps\n"
fi

# Pull latest tmux-config, then re-run the (possibly updated) install script once
if [ -z "${TMUX_CONFIG_PULLED-}" ] && git -C "$REPODIR" rev-parse --is-inside-work-tree &>/dev/null; then
  printf "Pull latest tmux-config\n"
  if git -C "$REPODIR" pull --ff-only; then
    export TMUX_CONFIG_PULLED=1
    exec bash "$REPODIR/install.sh" "$@"
  fi
  printf "WARNING: Cannot pull updates (no upstream, no network or diverged local commits). \
Installing current checkout\n"
fi

TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ ! -e "$TPM_DIR" ]; then
  printf "WARNING: Cannot found TPM (Tmux Plugin Manager) \
 at default location: \$HOME/.tmux/plugins/tpm.\n"
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  printf "Update TPM\n"
  git -C "$TPM_DIR" pull --ff-only || printf "WARNING: Cannot update TPM\n"
fi

# Back up existing .tmux.conf, unless it's already our symlink (i.e. re-run)
if [ -e "$HOME/.tmux.conf" ] && [ "$(readlink "$HOME/.tmux.conf")" != ".tmux/tmux.conf" ]; then
  backup="$HOME/.tmux.conf.bak"
  if [ -e "$backup" ]; then
    backup="$backup.$(date +%Y%m%d%H%M%S)"
  fi
  printf "Found existing .tmux.conf in your \$HOME directory. Will create a backup at $backup\n"
  cp -f "$HOME/.tmux.conf" "$backup"
fi

mkdir -p "$HOME"/.tmux
cp -a ./tmux/. "$HOME"/.tmux/
ln -sf .tmux/tmux.conf "$HOME"/.tmux.conf;

# Linux: link tmux wrapper as ~/.local/bin/tmux, it starts tmux without LD_LIBRARY_PATH,
# so a conda (or other) ncurses there can't crash tmux on copy, see tmux/tmux-wrapper.sh.
# An existing ~/.local/bin/tmux that isn't the wrapper (e.g. tmux built from source) is kept
if [ "$(uname -s)" = "Linux" ]; then
  wrapper="$HOME/.local/bin/tmux"
  wrapper_target="$HOME/.tmux/tmux-wrapper.sh"
  if { [ -e "$wrapper" ] || [ -L "$wrapper" ]; } && [ "$(readlink "$wrapper")" != "$wrapper_target" ]; then
    printf "WARNING: $wrapper exists and is not the tmux-config wrapper, leaving it alone. \
tmux started with LD_LIBRARY_PATH set (e.g. conda) can crash on copy, see tmux/tmux-wrapper.sh\n"
  else
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$wrapper_target" "$wrapper"
    if ! [ "$(type -P tmux)" -ef "$wrapper" ]; then
      printf "NOTE: Installed tmux wrapper at $wrapper, but \"tmux\" runs $(type -P tmux). \
Put ~/.local/bin before $(dirname "$(type -P tmux)") in PATH (a new login shell may already do it), \
or add to your shell rc: alias tmux=~/.local/bin/tmux\n"
    fi
  fi
fi

# Install new, update existing and remove unused TPM plugins.
# TPM requires running tmux server, as soon as `tmux start-server` does not work
# create dump __noop session in detached mode, and kill it when plugins are installed.
printf "Install and update TPM plugins\n"
tmux new -d -s __noop >/dev/null 2>&1 || true
tmux set-environment -g TMUX_PLUGIN_MANAGER_PATH "~/.tmux/plugins"
"$TPM_DIR"/bin/install_plugins || true
"$TPM_DIR"/bin/update_plugins all || true
"$TPM_DIR"/bin/clean_plugins || true
tmux kill-session -t __noop >/dev/null 2>&1 || true

# Refresh already running tmux sessions: reload config in every tmux server (any socket,
# e.g. `tmux -L work`) that runs this config, servers started with another one
# (`tmux -f other.conf`) are left alone. Then reattach their clients in place, as some
# settings only apply when a client attaches (e.g. extended keys for Shift+Enter).
# iTerm2 control mode (-CC) clients are not reattached, as they'd come back as plain tmux.
# Not refreshed: scrollback size of existing panes, key bindings removed from config
printf "Refresh running tmux sessions\n"
socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
for socket in "$socket_dir"/*; do
  [ -S "$socket" ] || continue
  # Skip stale sockets (server is gone) and servers not running this config
  [ "$(tmux -S "$socket" show -gqv @copy_use_osc52_fallback 2>/dev/null)" = "on" ] || continue

  if ! tmux -S "$socket" source-file "$HOME"/.tmux.conf; then
    printf "WARNING: Cannot reload ~/.tmux.conf in tmux server at $socket\n"
    continue
  fi
  printf "  reloaded tmux server at $socket\n"
  "$HOME"/.tmux/check_ncurses.sh -S "$socket" | sed 's/^/  /' || true

  tmux -S "$socket" list-clients -F '#{client_name} #{session_id} #{client_control_mode}' |
    while read -r client session control_mode; do
      [ "$control_mode" = "1" ] && continue
      tmux -S "$socket" detach-client -t "$client" -E "tmux -S '$socket' attach -t '$session'" || true
      printf "  reattached client $client\n"
    done
done

printf "OK: Completed\n"
