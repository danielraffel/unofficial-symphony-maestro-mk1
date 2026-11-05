#!/bin/bash
# Source only caller-selected local configuration; never discover another project's secrets.
if [ -n "${MAESTRO_ENV_FILE:-}" ]; then
    [ -f "$MAESTRO_ENV_FILE" ] || { echo "Missing MAESTRO_ENV_FILE" >&2; exit 1; }
    [ "$(stat -f '%Lp' "$MAESTRO_ENV_FILE")" = 600 ] || { echo "MAESTRO_ENV_FILE must be mode 600" >&2; exit 1; }
    set -a
    source "$MAESTRO_ENV_FILE"
    set +a
fi
export MAESTRO_BUILD_JOBS="${MAESTRO_BUILD_JOBS:-4}"
case "$MAESTRO_BUILD_JOBS" in ''|*[!0-9]*|0) echo "MAESTRO_BUILD_JOBS must be positive" >&2; exit 1;; esac
if [ -z "${TEAM_ID:-}" ]; then
    echo "TEAM_ID must be set in the private build environment" >&2
    exit 1
fi
export TEAM_ID
