/*
 * nspire-payload IMAGE: write to stdout the payload linuxloader2 put into a
 * new Linux image (rootimg "payload" setting). After the 16 byte tag of each
 * 4 KiB chunk: in chunk 0, "NSPLXPAY", the payload's length (le32) and a
 * zero le32; in chunks 1, 2..., the payload. Every chunk read must still
 * carry its tag ("NSPLXIMG" + le32 index + le32 0).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHUNK		4096
#define TAG_SIZE	16

static uint32_t le32(const unsigned char *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static int tag_ok(const unsigned char *c, uint32_t index)
{
	return !memcmp(c, "NSPLXIMG", 8) && le32(c + 8) == index && !le32(c + 12);
}

int main(int argc, char **argv)
{
	unsigned char c[CHUNK];
	uint32_t len, i;
	FILE *f;

	if (argc != 2) {
		fprintf(stderr, "usage: nspire-payload IMAGE\n");
		return 2;
	}
	f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 1;
	}
	if (fread(c, CHUNK, 1, f) != 1 || !tag_ok(c, 0) ||
	    memcmp(c + TAG_SIZE, "NSPLXPAY", 8)) {
		fprintf(stderr, "%s: no payload\n", argv[1]);
		return 1;
	}
	len = le32(c + TAG_SIZE + 8);
	for (i = 1; len; i++) {
		uint32_t n = len < CHUNK - TAG_SIZE ? len : CHUNK - TAG_SIZE;

		if (fread(c, CHUNK, 1, f) != 1 || !tag_ok(c, i)) {
			fprintf(stderr, "%s: chunk %u: bad tag\n", argv[1], (unsigned)i);
			return 1;
		}
		if (fwrite(c + TAG_SIZE, 1, n, stdout) != n) {
			perror("stdout");
			return 1;
		}
		len -= n;
	}
	return fflush(stdout) ? 1 : 0;
}
