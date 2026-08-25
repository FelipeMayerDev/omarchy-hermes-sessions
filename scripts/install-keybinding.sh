#!/bin/bash
# kelso.hermes-sessions: ensure the Super+Shift+H panel toggle binding exists.
# Runs at desktop start (post-boot hook) so a default keybinding ships with
# the plugin without touching the user's bindings.lua by hand.

LUA="$HOME/.config/hypr/bindings.lua"
MARKER="kelso.hermes-sessions toggle"

[[ -f "$LUA" ]] || exit 0
grep -qF "$MARKER" "$LUA" && exit 0

cat >> "$LUA" <<EOF

-- Hermes sessions panel (added automatically by kelso.hermes-sessions)
o.bind("SUPER + SHIFT + H", "Hermes sessions panel", "omarchy-shell kelso.hermes-sessions toggle")
EOF

hyprctl reload >/dev/null 2>&1 || true
