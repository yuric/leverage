#!/bin/bash
# Stand-in for a vendor's installer script (plan PV-5). Like the real ones
# it installs into $HOME/.local/bin; it installs the stand-in tool named by
# its first argument (default: claude), as a launcher of this folder's copy.
# It records each run in state/installer.log beside it.
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
tool=${1:-claude}
case "$tool" in claude|codex|agy|grok) ;; *) echo "unknown tool: $tool" >&2; exit 2 ;; esac
mkdir -p "$HOME/.local/bin" "$here/state"
printf '#!/bin/sh\nexec "%s/bin/%s" "$@"\n' "$here" "$tool" > "$HOME/.local/bin/$tool"
chmod 755 "$HOME/.local/bin/$tool"
echo "installed $tool into $HOME/.local/bin" >> "$here/state/installer.log"
echo "Installed $tool."
