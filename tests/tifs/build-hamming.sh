#!/bin/sh
# Build libhamming.so, the kernel's software Hamming ECC for the test tools,
# from the kernel's drivers/mtd/nand/ecc-sw-hamming.c given as argument.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
sed -n '/^static const char invparity/,/^EXPORT_SYMBOL(ecc_sw_hamming_calculate)/p' \
	"$1" > "$HERE/hamming_body.c"
grep -q '^int ecc_sw_hamming_calculate' "$HERE/hamming_body.c"
cc -O2 -shared -fPIC -o "$HERE/libhamming.so" "$HERE/hamming.c"
