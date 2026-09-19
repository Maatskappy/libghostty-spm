#!/bin/bash
# Make compiler-rt runtime symbols in libghostty.a local, so the archive
# links next to other static libraries that also bundle a compiler runtime.
#
# Why: Zig 0.16's compiler_rt defines ___isPlatformVersionAtLeast (the
# os_version_check builtin behind @available / __builtin_available). Rust's
# std defines the same strong symbol, so an app that links libghostty.a and a
# Rust static library (Inby links loro's libloro_swift.a) fails with
# "duplicate symbol '___isPlatformVersionAtLeast'". Zig 0.15 builds did not
# define it, which is why this only appeared with 1.6.
#
# Making the symbol local keeps compiler_rt.o's own references bound to it,
# while any outside caller resolves to the host's copy. Clang always links
# libclang_rt, which provides one.
#
# Usage: Script/localize-runtime-symbols.sh <in.xcframework.zip> <out.xcframework.zip>

set -euo pipefail

SYMBOLS=(___isPlatformVersionAtLeast ___isOSVersionAtLeast)

in_zip="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out_zip="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s\n' "${SYMBOLS[@]}" > "$work/symbols.txt"
(cd "$work" && unzip -q "$in_zip")

find "$work/GhosttyKit.xcframework" -name libghostty.a | while read -r archive; do
    thins=()
    for arch in $(lipo -archs "$archive"); do
        slice="$work/slice"
        rm -rf "$slice" && mkdir -p "$slice"
        lipo -thin "$arch" "$archive" -output "$slice/lib.a" 2>/dev/null \
            || cp "$archive" "$slice/lib.a"
        # nmedit rejects a list naming a symbol the object lacks, so pass
        # only the ones this slice defines.
        nm -g "$slice/lib.a" 2>/dev/null | grep -Fwf "$work/symbols.txt" \
            | awk '$2 == "T" { print $3 }' | sort -u > "$slice/defined.txt" || true
        if [ -s "$slice/defined.txt" ]; then
            (cd "$slice" && ar -x lib.a compiler_rt.o \
                && nmedit -R defined.txt compiler_rt.o \
                && ar -r lib.a compiler_rt.o 2>/dev/null && ranlib lib.a 2>/dev/null)
            if nm -g "$slice/lib.a" 2>/dev/null | grep -Fwf "$work/symbols.txt" | grep -q ' T '; then
                echo "error: $archive ($arch) still exports a runtime symbol" >&2
                exit 1
            fi
            echo "localized: ${archive#"$work/"} ($arch)"
        fi
        mv "$slice/lib.a" "$work/$arch.a"
        thins+=("$work/$arch.a")
    done
    if [ "${#thins[@]}" -gt 1 ]; then
        lipo -create "${thins[@]}" -output "$archive"
    else
        mv "${thins[0]}" "$archive"
    fi
    rm -f "${thins[@]}"
done

rm -f "$out_zip"
(cd "$work" && zip -qry --symlinks "$out_zip" GhosttyKit.xcframework)
shasum -a 256 "$out_zip"
