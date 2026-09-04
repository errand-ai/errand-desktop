#!/usr/bin/env bash
#
# Builds the arm64 and x86_64 release slices with identical flags and merges them
# into a single universal Mach-O binary.
#
# Both slices must come from the same source tree and the same environment — only
# `--arch` varies — so that `lipo` cannot paper over a linker-flag mismatch.
#
# Usage: scripts/build-universal.sh [output-path]
#   output-path defaults to .build/universal/ErrandDesktop
set -euo pipefail

OUTPUT="${1:-.build/universal/ErrandDesktop}"
CONFIGURATION="release"

build_slice() {
  local arch="$1"
  echo "==> Building ${arch} slice"
  swift build -c "${CONFIGURATION}" --arch "${arch}"
}

build_slice arm64
build_slice x86_64

ARM64_BIN=".build/arm64-apple-macosx/${CONFIGURATION}/ErrandDesktop"
X86_64_BIN=".build/x86_64-apple-macosx/${CONFIGURATION}/ErrandDesktop"

for bin in "${ARM64_BIN}" "${X86_64_BIN}"; do
  if [[ ! -f "${bin}" ]]; then
    echo "error: expected slice not found at ${bin}" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${OUTPUT}")"
echo "==> Merging slices into ${OUTPUT}"
lipo -create -output "${OUTPUT}" "${ARM64_BIN}" "${X86_64_BIN}"

echo "==> lipo -info"
lipo -info "${OUTPUT}"

# Fail loudly if either slice is missing from the merged binary.
ARCHS="$(lipo -archs "${OUTPUT}")"
for expected in arm64 x86_64; do
  if [[ " ${ARCHS} " != *" ${expected} "* ]]; then
    echo "error: universal binary is missing the ${expected} slice (got: ${ARCHS})" >&2
    exit 1
  fi
done

echo "==> Universal binary ready: ${OUTPUT}"
