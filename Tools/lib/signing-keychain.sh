#!/bin/bash
MAESTRO_KC_SAVED=()
MAESTRO_KC_CHANGED=false
maestro_signing_keychain_restore() {
    if [ "$MAESTRO_KC_CHANGED" = true ]; then
        security list-keychains -d user -s "${MAESTRO_KC_SAVED[@]}"
        MAESTRO_KC_CHANGED=false
    fi
}
maestro_signing_keychain_guard() {
    [ -n "${MAESTRO_SIGNING_CONTEXT:-}" ] && return 0
    [ -n "${SIGNING_KEYCHAIN:-}" ] || return 0
    [ -f "$SIGNING_KEYCHAIN" ] || { echo "Signing keychain missing" >&2; exit 1; }
    while IFS= read -r path; do MAESTRO_KC_SAVED+=("$path"); done < <(
        security list-keychains -d user | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))'
    )
    trap maestro_signing_keychain_restore EXIT
    trap 'maestro_signing_keychain_restore; exit 130' INT
    trap 'maestro_signing_keychain_restore; exit 143' TERM
    MAESTRO_KC_CHANGED=true
    security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${MAESTRO_KC_SAVED[@]}"
    export MAESTRO_SIGNING_CONTEXT=1
}
