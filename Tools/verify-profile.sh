#!/bin/bash
# verify-profile.sh — Validate a provisioning profile before it gets embedded.
#
#   verify-profile.sh <profile.provisionprofile> <expected-app-id> <developerid|development>
#
# Exists because a Development profile named "*_Production" was embedded into
# production dext builds for a month. It notarized fine — notarytool checks the
# signed entitlements, not the embedded profile — then failed at dext load time
# on any machine outside the profile's ProvisionedDevices list.
#
# A Developer ID profile has ProvisionsAllDevices=true, no ProvisionedDevices,
# no get-task-allow, and embeds the Developer ID Application certificate.
# A Development profile has the inverse. Nothing in the filename tells you which.
set -euo pipefail

PROFILE="${1:?usage: verify-profile.sh <profile> <app-id> <developerid|development>}"
EXPECT_APPID="${2:?missing expected app id}"
EXPECT_TYPE="${3:?missing type: developerid|development}"

fail() { echo "[profile] FAIL: $*" >&2; exit 1; }
ok()   { echo "[profile] ok: $*"; }

[ -f "$PROFILE" ] || fail "no such profile: $PROFILE"

PLIST=$(security cms -D -i "$PROFILE" 2>/dev/null) || fail "cannot decode CMS: $PROFILE"
get() { printf '%s' "$PLIST" | plutil -extract "$1" raw - 2>/dev/null; }
has() { printf '%s' "$PLIST" | plutil -extract "$1" raw - >/dev/null 2>&1; }

NAME=$(get Name || echo "?")
echo "[profile] $(basename "$PROFILE")  (\"$NAME\")"

# ── Expiry ───────────────────────────────────────────────────────────────────
EXP=$(get ExpirationDate) || fail "no ExpirationDate"
EXP_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" +%s 2>/dev/null) || fail "unparseable ExpirationDate: $EXP"
NOW_EPOCH=$(date +%s)
if [ "$EXP_EPOCH" -le "$NOW_EPOCH" ]; then
    fail "EXPIRED on $EXP — regenerate in the Apple Developer portal"
fi
DAYS=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
ok "expires $EXP (${DAYS}d)"
[ "$DAYS" -lt 30 ] && echo "[profile] WARNING: expires in ${DAYS} days"

# ── App ID ───────────────────────────────────────────────────────────────────
APPID=$(printf '%s' "$PLIST" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null \
     || printf '%s' "$PLIST" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw - 2>/dev/null) \
     || fail "no application-identifier in entitlements"
case "$APPID" in
    *".$EXPECT_APPID") ok "app id $APPID" ;;
    *) fail "app id mismatch: profile has '$APPID', expected suffix '.$EXPECT_APPID'" ;;
esac

# ── Embedded signing certificate ─────────────────────────────────────────────
CERT_SUBJ=$(printf '%s' "$PLIST" | plutil -extract DeveloperCertificates.0 raw - 2>/dev/null \
    | base64 -d 2>/dev/null | openssl x509 -inform DER -noout -subject 2>/dev/null) \
    || fail "no embedded DeveloperCertificates"

# ── Type-specific rules ──────────────────────────────────────────────────────
PROVISIONS_ALL=$(get ProvisionsAllDevices || echo "false")
GET_TASK_ALLOW=$(printf '%s' "$PLIST" | plutil -extract Entitlements.get-task-allow raw - 2>/dev/null || echo "false")

case "$EXPECT_TYPE" in
  developerid)
    [ "$PROVISIONS_ALL" = "true" ] \
        || fail "not a Developer ID profile (ProvisionsAllDevices != true). This is a Development profile — in the portal choose Distribution > Developer ID, not macOS App Development."
    has ProvisionedDevices \
        && fail "Developer ID profile must not carry a ProvisionedDevices list"
    [ "$GET_TASK_ALLOW" = "true" ] \
        && fail "get-task-allow is set — debug-only; notarization and SIP-enabled dext load will reject this"
    case "$CERT_SUBJ" in
        *"Developer ID Application"*) ok "signed by Developer ID Application cert" ;;
        *) fail "embedded cert is not Developer ID Application: $CERT_SUBJ" ;;
    esac
    ok "type: Developer ID (installs on any Mac)"
    ;;
  development)
    case "$CERT_SUBJ" in
        *"Apple Development"*) ok "signed by Apple Development cert" ;;
        *) fail "embedded cert is not Apple Development: $CERT_SUBJ" ;;
    esac
    THIS_MAC=$(ioreg -d2 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')
    if printf '%s' "$PLIST" | plutil -extract ProvisionedDevices json -o - - 2>/dev/null | grep -q "$THIS_MAC"; then
        ok "this Mac ($THIS_MAC) is provisioned"
    else
        fail "this Mac ($THIS_MAC) is NOT in ProvisionedDevices — add it in the portal and regenerate"
    fi
    ok "type: Development (this Mac only)"
    ;;
  *) fail "unknown expected type: $EXPECT_TYPE (want developerid|development)" ;;
esac

# ── The signing identity must actually be in the keychain ────────────────────
CERT_SHA=$(printf '%s' "$PLIST" | plutil -extract DeveloperCertificates.0 raw - 2>/dev/null \
    | base64 -d | openssl x509 -inform DER -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/.*=//; s/://g')
if security find-identity -v 2>/dev/null | grep -qi "$CERT_SHA"; then
    ok "matching private key present in keychain"
else
    fail "the certificate this profile is bound to has no private key in this keychain — the profile was generated against a certificate from a different Mac. Regenerate against your current Developer ID Application cert."
fi

echo "[profile] PASS"
