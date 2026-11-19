#!/bin/sh
# Stand-in for LeverageRunner: writes its arguments and environment to
# state/runner/<pid>.json beside it, then runs until stopped (provider_tool.py).
exec python3 -I "$(dirname -- "$0")/provider_tool.py" runner "$@"
