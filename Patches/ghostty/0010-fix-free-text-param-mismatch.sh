#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Backport ghostty #12020 onto tagged releases (present through v1.3.1).
#
# ghostty.h declares:
#     void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
# but v1.3.1's Zig impl exported only a single-param version:
#     export fn ghostty_surface_free_text(ptr: *Text) void
# The ABI mismatch means the caller's text pointer arrives in the ignored
# 2nd argument slot and the text allocation from ghostty_surface_read_text /
# ghostty_surface_read_selection is NEVER freed — a per-call heap leak on the
# monitoring snapshot path (upstream fix: ghostty commit 4803d58b).
#
# Idempotent: a no-op once the two-param signature is present (already
# patched here, or building from a ghostty ref >= the upstream fix).

EMBEDDED="${SOURCE_DIR}/src/apprt/embedded.zig"
if [ ! -f "$EMBEDDED" ]; then
    echo "[-] embedded.zig not found: $EMBEDDED"
    exit 1
fi

if grep -q 'export fn ghostty_surface_free_text(_: \*Surface, ptr: \*Text) void' "$EMBEDDED"; then
    echo "[+] free_text param mismatch already fixed"
    exit 0
fi

if ! grep -q 'export fn ghostty_surface_free_text(ptr: \*Text) void' "$EMBEDDED"; then
    echo "[-] free_text: neither the broken nor the fixed signature found — ghostty layout changed, refusing to patch blindly"
    exit 1
fi

sed -i '' \
    's/export fn ghostty_surface_free_text(ptr: \*Text) void/export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void/' \
    "$EMBEDDED"
echo "[+] patched ghostty_surface_free_text to the two-param (header-matching) signature"
