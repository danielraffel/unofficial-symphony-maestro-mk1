#!/bin/bash
# OpticalFormat (0x34) trace test for every option-board combination.
#
# Compiles SymphonyOptionBoard.h on the host and prints, for each pair of slot
# types (plus a failed board-type read), the 0x34 writes the link-configuration
# step sends and the slots that get an optical-format control. The output must
# match golden/optical-format-trace.txt. The test also replays the rules from
# before this change (blind 0x34 to both slots, AES counted as optical) and
# fails if any combination without an AES board traces differently, so only the
# AES rows can change.
#
# Regenerate the golden file (review the diff before committing):
#   UPDATE_GOLDEN=1 Drivers/Thunderbolt/Scripts/test-optical-format.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
GOLDEN="$SCRIPT_DIR/golden/optical-format-trace.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'CPP'
#include <cstdio>
#include <cstdlib>
#include <string>
#include "SymphonyOptionBoard.h"

static const char* Name(int t) {
    static const char* names[] = { "None", "MicPre8", "AnalogAES", "Optical",
                                   "AD16", "DA16", "ADDA16", "2x6" };
    return t < 0 ? "read-failed" : names[t];
}

// The rules as they were before: 0x34 to both slots whatever they hold, and an
// optical control for AES, Optical, AD16, DA16 and 2x6.
static bool OldHasOpticalFormat(uint8_t t) {
    return t == 2 || t == 3 || t == 4 || t == 5 || t == 7;
}

// t < 0 means the 0xA1 board-type read failed for that slot.
static std::string Trace(int t0, int t1, bool old) {
    std::string out;
    const int types[2] = { t0, t1 };
    for (int b = 0; b < 2; b++) {
        bool ok = types[b] >= 0;
        uint8_t bt = ok ? (uint8_t)types[b] : 0;
        bool send = old ? true : BootSendsOpticalFormat(ok, bt);
        if (send) out += " TX 0x34 nValue=" + std::to_string(b) + " data=00;";
    }
    for (int b = 0; b < 2; b++) {
        bool ok = types[b] >= 0;
        uint8_t bt = ok ? (uint8_t)types[b] : 0;
        bool control = ok && (old ? OldHasOpticalFormat(bt) : BoardHasOpticalFormat(bt));
        if (control) out += " control board" + std::to_string(b) + ";";
    }
    return out.empty() ? " (nothing)" : out;
}

int main() {
    static_assert(!BoardHasOpticalFormat(kSIOOptionBoard_AnalogAES), "AES has no optical format");
    static_assert(BoardHasOpticalFormat(kSIOOptionBoard_Optical), "Optical keeps its format");
    static_assert(!BootSendsOpticalFormat(true, kSIOOptionBoard_AnalogAES), "no boot 0x34 to AES");
    static_assert(BootSendsOpticalFormat(false, kSIOOptionBoard_AnalogAES), "failed read sends as before");

    int unchanged = 0, changed = 0;
    for (int t0 = -1; t0 <= 7; t0++) {
        for (int t1 = -1; t1 <= 7; t1++) {
            std::string now = Trace(t0, t1, false);
            std::string before = Trace(t0, t1, true);
            bool hasAES = t0 == 2 || t1 == 2;
            if (!hasAES && now != before) {
                std::fprintf(stderr, "FAIL: %s + %s changed without an AES board\n  before:%s\n  now:   %s\n",
                             Name(t0), Name(t1), before.c_str(), now.c_str());
                return 1;
            }
            if (hasAES && now == before) {
                std::fprintf(stderr, "FAIL: %s + %s still traces as before\n", Name(t0), Name(t1));
                return 1;
            }
            (now == before ? unchanged : changed)++;
            std::printf("slot1=%s slot2=%s:%s\n", Name(t0), Name(t1), now.c_str());
        }
    }
    std::fprintf(stderr, "[optical] %d combinations unchanged, %d with an AES board changed\n",
                 unchanged, changed);
    return 0;
}
CPP

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test" > "$TMP_DIR/trace.txt"

if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
    cp "$TMP_DIR/trace.txt" "$GOLDEN"
    echo "[optical] golden trace written: $GOLDEN"
fi
diff -u "$GOLDEN" "$TMP_DIR/trace.txt"

# The driver must use these helpers, not a private copy of the rules.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
assert '#include "SymphonyOptionBoard.h"' in src
assert 'static constexpr bool BoardHasOpticalFormat' not in src
boot = src[src.index("19b-0c. Set optical format"):src.index("19b-1. Playback routing")]
assert "BootSendsOpticalFormat(typeOK, bt)" in boot
assert "kSIOCmd_OptionBoardType" in boot
assert boot.index("kSIOCmd_OptionBoardType") < boot.index("kSIOCmd_OpticalFormat")
assert "!BoardHasOpticalFormat(bt)" in src
PY
echo "OpticalFormat trace: PASS"
