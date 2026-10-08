/*
 * nspire-nandraw: read the classic models' NAND chip through the direct
 * access window at 0x08000000 (data; commands at +0x40000, addresses at
 * +0x80000, one byte at a time), not through the controller's DMA. Shows
 * the chip ID, then the first page of the first FlashFX units of the
 * "filesystem" partition: data[0..7] and spare[0..15].
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define WINDOW		0x08000000
#define DATA		0x00000
#define CMD		0x40000
#define ADDR		0x80000
#define PAGE		512
#define OOB		16

static volatile uint8_t *w;

static void cmd(uint8_t c) { w[CMD] = c; }
static void addr(uint8_t a) { w[ADDR] = a; }
static uint8_t data(void) { return w[DATA]; }

static long sysfs_long(const char *path)
{
	char buf[32];
	FILE *f = fopen(path, "r");
	long v = -1;

	if (f && fgets(buf, sizeof(buf), f))
		v = strtol(buf, NULL, 0);
	if (f)
		fclose(f);
	return v;
}

static int partition(void)
{
	char line[128];
	FILE *f = fopen("/proc/mtd", "r");
	int n = -1, m;

	while (f && fgets(line, sizeof(line), f))
		if (strstr(line, "\"filesystem\"") && sscanf(line, "mtd%d:", &m) == 1)
			n = m;
	if (f)
		fclose(f);
	return n;
}

static void read_page(unsigned page, uint8_t *buf)
{
	int i;

	cmd(0x00);			/* READ, first half */
	addr(0);
	addr(page);
	addr(page >> 8);
	usleep(200);			/* tR */
	for (i = 0; i < PAGE + OOB; i++)
		buf[i] = data();
}

int main(void)
{
	uint8_t buf[PAGE + OOB];
	char path[64];
	long offset;
	int fd, n, i, u;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	w = mmap(NULL, 0x100000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, WINDOW);
	if (w == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	cmd(0xff);			/* RESET */
	usleep(1000);
	cmd(0x90);			/* READ ID */
	addr(0);
	printf("ID:");
	for (i = 0; i < 4; i++)
		printf(" %02x", data());
	putchar('\n');

	n = partition();
	snprintf(path, sizeof(path), "/sys/class/mtd/mtd%d/offset", n);
	offset = n < 0 ? -1 : sysfs_long(path);
	if (offset < 0) {
		printf("no \"filesystem\" partition\n");
		return 1;
	}
	printf("mtd%d at %#lx; units 0-9, page 0:\n", n, offset);
	for (u = 0; u < 10; u++) {
		read_page(offset / PAGE + u * 64, buf);
		printf(" %u ", u);
		for (i = 0; i < 8; i++)
			printf("%02x", buf[i]);
		putchar(' ');
		for (i = 0; i < OOB; i++)
			printf("%02x", buf[PAGE + i]);
		putchar('\n');
	}
	return 0;
}
