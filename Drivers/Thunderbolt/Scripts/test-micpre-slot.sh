#!/bin/bash
# Host-side decision table for MicPre8 controls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'CPP'
#include <cstdio>
#include <cstdlib>
#include "SymphonyOptionBoard.h"

static void expect(const char *name, bool primaryValid, uint8_t primaryType,
                   bool secondaryValid, uint8_t secondaryType, bool converters,
                   unsigned expected)
{
    unsigned got = MicPreChannelsForSlots(primaryValid, primaryType,
                                           secondaryValid, secondaryType,
                                           converters);
    if (got != expected) {
        std::fprintf(stderr, "FAIL: %s: got %u, expected %u\n", name, got, expected);
        std::abort();
    }
    std::printf("PASS: %s -> %u\n", name, got);
}

int main()
{
    expect("slot 2 MicPre8", false, kSIOOptionBoard_None, true,
           kSIOOptionBoard_MicPre8, false, 8);
    // Slot 1 MicPre8 is an invalid hardware layout and must publish nothing.
    expect("slot 1 MicPre8 (invalid layout)", true, kSIOOptionBoard_MicPre8,
           true, kSIOOptionBoard_None, false, 0);
    expect("neither slot", true, kSIOOptionBoard_None, true,
           kSIOOptionBoard_None, false, 0);
    expect("slot 2 unread", false, kSIOOptionBoard_None, false,
           kSIOOptionBoard_MicPre8, false, 0);
    expect("slot 2 MicPre8 on converter port", false, kSIOOptionBoard_None,
           true, kSIOOptionBoard_MicPre8, true, 0);
}
CPP

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" \
    "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"
echo "MicPre slot decision: PASS"
