/*
 * nspire-nandinfo [MTD]: what the TI-Nspire OS filesystem partition looks
 * like, on one screen (53 columns): where the FlashFX unit headers are
 * (page data starting with CC DD "DL_FS"), the spare area of their first
 * pages, and the first page of the first erase blocks. MTD defaults to the
 * "filesystem" partition.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <mtd/mtd-user.h>

static int find_partition(char *dev, size_t len)
{
	char line[128];
	FILE *f = fopen("/proc/mtd", "r");
	int n, found = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (strstr(line, "\"filesystem\"") && sscanf(line, "mtd%d:", &n) == 1) {
			snprintf(dev, len, "/dev/mtd%d", n);
			found = 1;
		}
	fclose(f);
	return found ? 0 : -1;
}

static int read_page(int fd, const struct mtd_info_user *mi, unsigned page,
		     unsigned char *data, unsigned char *oob)
{
	struct mtd_oob_buf ob = {
		.start = (unsigned long long)page * mi->writesize,
		.length = mi->oobsize,
		.ptr = oob,
	};

	if (pread(fd, data, mi->writesize, (off_t)page * mi->writesize) != (ssize_t)mi->writesize)
		memset(data, 0xee, mi->writesize);	/* unreadable: show it */
	return ioctl(fd, MEMREADOOB, &ob);
}

static void hex(const unsigned char *p, int n)
{
	while (n--)
		printf("%02x", *p++);
}

int main(int argc, char **argv)
{
	struct mtd_info_user mi;
	unsigned char *data, oob[256];
	char dev[32];
	unsigned blocks, ppb, b, headers = 0, first = ~0u, period = 0, last = ~0u;
	unsigned le = 0, be = 0;
	int fd, i;

	if (argc > 1)
		snprintf(dev, sizeof(dev), "%s", argv[1]);
	else if (find_partition(dev, sizeof(dev))) {
		fprintf(stderr, "no \"filesystem\" partition in /proc/mtd\n");
		return 1;
	}
	fd = open(dev, O_RDONLY);
	if (fd < 0 || ioctl(fd, MEMGETINFO, &mi)) {
		perror(dev);
		return 1;
	}
	/* Raw: the pages carry TI's ECC, not the one Linux would check */
	if (ioctl(fd, MTDFILEMODE, MTD_FILE_MODE_RAW))
		perror("raw mode");
	data = malloc(mi.writesize);
	blocks = mi.size / mi.erasesize;
	ppb = mi.erasesize / mi.writesize;
	printf("%s: %u blocks of %u pages of %u+%u\n", dev, blocks, ppb, mi.writesize,
	       mi.oobsize);

	for (b = 0; b < blocks; b++) {
		if (read_page(fd, &mi, b * ppb, data, oob))
			continue;
		if (data[0] != 0xcc || data[1] != 0xdd || memcmp(data + 2, "DL_FS", 5))
			continue;
		headers++;
		if (first == ~0u)
			first = b;
		else if (!period)
			period = b - last;
		last = b;
		if (oob[0] == 0xe2 && oob[1] == 0x48)
			le++;
		if (oob[0] == 0x48 && oob[1] == 0xe2)
			be++;
	}
	printf("DL_FS headers: %u blocks, first %d, every %u\n", headers,
	       first == ~0u ? -1 : (int)first, period);
	printf("spare[0..1] of them: e2 48 x%u, 48 e2 x%u\n", le, be);

	if (first != ~0u) {
		printf("block %u, pages 0-5: data[0..3] spare[0..15]\n", first);
		for (i = 0; i < 6; i++) {
			read_page(fd, &mi, first * ppb + i, data, oob);
			printf(" p%d ", i);
			hex(data, 4);
			putchar(' ');
			hex(oob, mi.oobsize < 16 ? mi.oobsize : 16);
			putchar('\n');
		}
		read_page(fd, &mi, first * ppb, data, oob);
		printf("header 10-3b:\n ");
		hex(data + 0x10, 22);
		printf("\n ");
		hex(data + 0x26, 22);
		putchar('\n');
	}

	printf("blocks 0-11, page 0: data[0..3] spare[0..15]\n");
	for (b = 0; b < 12 && b < blocks; b++) {
		read_page(fd, &mi, b * ppb, data, oob);
		printf(" %02u ", b);
		hex(data, 4);
		putchar(' ');
		hex(oob, mi.oobsize < 16 ? mi.oobsize : 16);
		putchar('\n');
	}
	return 0;
}
