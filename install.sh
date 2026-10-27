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

  tmux -S "$socket" list-clients -F '#{client_name} #{session_id} #{client_control_mode}' |
    while read -r client session control_mode; do
      [ "$control_mode" = "1" ] && continue
      tmux -S "$socket" detach-client -t "$client" -E "tmux -S '$socket' attach -t '$session'" || true
      printf "  reattached client $client\n"
    done
done

printf "OK: Completed\n"
