#!/bin/sh
# Build linuxloader2.tns with the prebuilt Ndless SDK.
# Output: $OUT/linuxloader2.tns
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.sh

if [ -z "${NDLESS_SDK:-}" ]; then
	NDLESS_SDK=$WORK/ndless-sdk
	if [ ! -x "$NDLESS_SDK/bin/nspire-gcc" ]; then
		mkdir -p "$WORK"
		curl -fsSL "$NDLESS_SDK_URL" | tar -xz -C "$WORK"
	fi
fi
export PATH="$NDLESS_SDK/bin:$NDLESS_SDK/toolchain/install/bin:$PATH"

SRC=${LOADER_SRC:-$WORK/nspire-linux-loader2}
if [ -z "${LOADER_SRC:-}" ]; then
	rm -rf "$SRC"
	git clone --branch "$LOADER_REF" "$LOADER_REPO" "$SRC"
fi
make -C "$SRC" clean >/dev/null
make -C "$SRC"
cp "$SRC/linuxloader2.tns" "$OUT/"
echo "loader built from $(git -C "$SRC" rev-parse --short HEAD)"
