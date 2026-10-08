#!/bin/sh
# Fill in release/notes.md for the ZIPs in $OUT.
# Output: $OUT/release-notes.md
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

REL=$(cat "$OUT/kernel.release")
LINUX_ZIP=nspire-linux-$REL.zip
OPENWRT_ZIP=nspire-openwrt-$(cat "$OUT/openwrt.version")-$REL.zip
LINUX_ZIP_NOFF=${LINUX_ZIP%.zip}-no-fastfetch.zip
OPENWRT_ZIP_NOFF=${OPENWRT_ZIP%.zip}-no-fastfetch.zip
for z in "$LINUX_ZIP" "$LINUX_ZIP_NOFF" "$OPENWRT_ZIP" "$OPENWRT_ZIP_NOFF"; do
	[ -f "$OUT/$z" ] || { echo "missing $OUT/$z" >&2; exit 1; }
done

info=$(mktemp) sums=$(mktemp)
trap 'rm -f "$info" "$sums"' EXIT
{
	echo "- Kernel: $REL ([MaxSignal/linux]($(echo "$KERNEL_REPO" | sed 's/\.git$//')) \`$KERNEL_REF\`${KERNEL_COMMIT:+ @ \`$KERNEL_COMMIT\`})"
	echo "- Loader: linuxloader2 ([MaxSignal/nspire-linux-loader2]($(echo "$LOADER_REPO" | sed 's/\.git$//')) \`$LOADER_REF\`${LOADER_COMMIT:+ @ \`$LOADER_COMMIT\`})"
	echo "- BusyBox $BUSYBOX_VERSION, OpenWrt $(cat "$OUT/openwrt.version") (at91/sam9x), fastfetch $FASTFETCH_VERSION"
	echo "- Bundle: \`$(git -C "$TOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)\`"
} > "$info"
(cd "$OUT" && sha256sum "$LINUX_ZIP" "$LINUX_ZIP_NOFF" "$OPENWRT_ZIP" "$OPENWRT_ZIP_NOFF") > "$sums"

awk -v info="$info" -v sums="$sums" \
    -v kernel="$REL" -v openwrt="$(cat "$OUT/openwrt.version")" \
    -v linux_zip="$LINUX_ZIP" -v openwrt_zip="$OPENWRT_ZIP" \
    -v linux_zip_noff="$LINUX_ZIP_NOFF" -v openwrt_zip_noff="$OPENWRT_ZIP_NOFF" '
	/^@BUILD_INFO@$/ { while ((getline l < info) > 0) print l; next }
	/^@SHA256@$/ { while ((getline l < sums) > 0) print l; next }
	{
		gsub(/@KERNEL@/, kernel); gsub(/@OPENWRT@/, openwrt)
		gsub(/@LINUX_ZIP_NOFF@/, linux_zip_noff); gsub(/@OPENWRT_ZIP_NOFF@/, openwrt_zip_noff)
		gsub(/@LINUX_ZIP@/, linux_zip); gsub(/@OPENWRT_ZIP@/, openwrt_zip)
		print
	}' "$TOP/release/notes.md" > "$OUT/release-notes.md"
if grep -n '@[A-Z_0-9]*@' "$OUT/release-notes.md"; then
	echo "unreplaced placeholder in the release notes" >&2; exit 1
fi
echo "release notes: $OUT/release-notes.md"
