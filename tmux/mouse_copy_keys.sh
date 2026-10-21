#!/usr/bin/env bash

# Bind typing keys in "copy-mode" key table, used for mouse copy mode (see tmux.conf):
# key leaves copy mode (back to the bottom) and is sent to the shell, like typing
# in a scrolled back terminal does.
# Printable chars are sent by hex code, so no quoting is needed for ; # " ' etc.
# (they can't be bound by hex code though: "0x78" is a different key than "x")

set -eu

args=()

# '\;' separates commands inside the binding, plain ';' separates bind commands
bind_key() {
  local key="$1"; shift
  args+=(bind -T copy-mode "$key" send-keys -X cancel '\;' send-keys "$@" \;)
}

for code in $(seq 33 126); do
  hex=$(printf '%x' "$code")
  key=$(printf "\\x$hex")
  if [ "$key" = ";" ]; then
    key='\;'
  fi
  bind_key "$key" -H "$hex"
done

for key in Space Enter BSpace Tab BTab Up Down Left Right Home End DC IC; do
  bind_key "$key" "$key"
done

for c in {a..z}; do
  bind_key "C-$c" "C-$c"
done

for key in {a..z} {A..Z} {0..9} . _ - BSpace Left Right; do
  bind_key "M-$key" "M-$key"
done

tmux "${args[@]}"
