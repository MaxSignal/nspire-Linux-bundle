/*
 * nspire-nanddma: on the classic models, read the first page of the
 * "filesystem" partition with the NAND controller's DMA (0xB8000000) into
 * the internal SRAM, with variants of the operation, to find how it moves
 * one byte of the chip to one byte of memory. Prints the controller's
 * registers, the chip ID read with and without bit 21, then per variant:
 * how many bytes of the buffer were written, where CC DD (a FlashFX unit
 * header) first shows, data[0..7] and the bytes at 512..519.
 *
 * "nspire-nanddma write" also tests writing, in a unit of the filesystem
 * the TI-Nspire OS does not use (all its pages erased): a page programmed
 * with and without bit 21, read back, then the block erased again.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PHX		0xb8000000
#define SRAM		0xa4010000	/* free for Linux: TI's old framebuffer area */
#define BUF		0x2000

#define REG(o)		(*(volatile uint32_t *)(regs + (o)))

static uint8_t *regs;
static volatile uint8_t *buf;

static long offset_of_filesystem(void)
{
	char line[128], path[64];
	FILE *f = fopen("/proc/mtd", "r");
	long v = -1;
	int n = -1, m;

	while (f && fgets(line, sizeof(line), f))
		if (strstr(line, "\"filesystem\"") && sscanf(line, "mtd%d:", &m) == 1)
			n = m;
	if (f)
		fclose(f);
	snprintf(path, sizeof(path), "/sys/class/mtd/mtd%d/offset", n);
	f = fopen(path, "r");
	if (f && fgets(line, sizeof(line), f))
		v = strtol(line, NULL, 0);
	if (f)
		fclose(f);
	return v;
}

static int run(uint32_t op)
{
	int n;

	REG(0x0c) = op;
	REG(0x08) = 1;
	for (n = 0; n < 100000 && (REG(0x08) & 1); n++)
		usleep(10);
	return n < 100000 ? 0 : -1;
}

/* READY in the status the controller reads (READ STATUS) */
static int wait_ready(void)
{
	int n;

	for (n = 0; n < 100000 && !(REG(0x34) & 0x40); n++)
		usleep(10);
	return n < 100000 ? 0 : -1;
}

static void read_id(const char *name, uint32_t extra)
{
	int i;

	for (i = 0; i < 16; i++)
		buf[i] = 0xa5;
	REG(0x10) = 0;
	REG(0x24) = 4;
	REG(0x28) = SRAM;
	run(0x90 | 1 << 8 | 1 << 22 | extra);
	printf("ID %-4s", name);
	for (i = 0; i < 8; i++)
		printf(" %02x", buf[i]);
	putchar('\n');
}

static void read_page(uint32_t page, uint32_t extra)
{
	REG(0x10) = 0;
	REG(0x14) = page & 0xff;
	REG(0x18) = page >> 8 & 0xff;
	REG(0x24) = 528;
	REG(0x28) = SRAM;
	run(0x00 | 3 << 8 | 1 << 22 | extra);
}

static int all_ff(void)
{
	int i;

	for (i = 0; i < 528; i++)
		if (buf[i] != 0xff)
			return 0;
	return 1;
}

static int erase_block(uint32_t page)
{
	REG(0x10) = page & 0xff;
	REG(0x14) = page >> 8 & 0xff;
	/* ERASE1, 2 address bytes, ERASE2 */
	if (run(0x60 | 2 << 8 | 0xd0 << 12 | 1 << 20))
		return -1;
	return wait_ready();
}

static int program(uint32_t page, uint32_t extra)
{
	int i;

	for (i = 0; i < 528; i++)
		buf[i] = i * 7 + 3;
	run(0x00);					/* pointer: first half */
	REG(0x10) = 0;
	REG(0x14) = page & 0xff;
	REG(0x18) = page >> 8 & 0xff;
	REG(0x24) = 528;
	REG(0x28) = SRAM;
	/* SEQIN, 3 address bytes, write, PAGEPROG */
	if (run(0x80 | 3 << 8 | 1 << 11 | 0x10 << 12 | 1 << 20 | 1 << 22 | extra))
		return -1;
	return wait_ready();
}

static void write_test(uint32_t part_page, uint32_t part_pages)
{
	uint32_t unit, p, first = 0;
	int i, bad;

	/* The last unit (64 pages) whose pages are all erased */
	for (unit = part_pages / 64; unit-- > 0 && !first; ) {
		for (p = 0; p < 64; p++) {
			read_page(part_page + unit * 64 + p, 1 << 21);
			if (!all_ff())
				break;
		}
		if (p == 64)
			first = part_page + unit * 64;
	}
	if (!first) {
		printf("write: no unused unit\n");
		return;
	}
	printf("write test in unit %u (page %#x)\n", (first - part_page) / 64, first);
	REG(0x04) = 1;					/* writable */
	for (i = 0; i < 2; i++) {
		uint32_t extra = i ? 0 : 1 << 21, page = first + 1 + i;
		int j;

		program(page, extra);
		read_page(page, 1 << 21);
		for (bad = -1, j = 0; j < 528; j++)
			if (buf[j] != (uint8_t)(j * 7 + 3)) {
				bad = j;
				break;
			}
		printf("write %-4s %s", i ? "none" : "b21", bad < 0 ? "OK" : "BAD at");
		if (bad >= 0)
			printf(" %d: %02x%02x%02x%02x", bad, buf[bad], buf[bad + 1], buf[bad + 2],
			       buf[bad + 3]);
		putchar('\n');
	}
	erase_block(first);
	for (bad = 0, p = 0; p < 32; p++) {
		read_page(first + p, 1 << 21);
		if (!all_ff())
			bad++;
	}
	REG(0x04) = 0;
	printf("erased again: %s\n", bad ? "NO, pages left" : "OK");
}

static void try(const char *name, uint32_t page, uint32_t extra, uint32_t size)
{
	int i, written = 0, cc = -1, n;

	for (i = 0; i < BUF; i++)
		buf[i] = 0xa5;
	REG(0x10) = 0;
	REG(0x14) = page & 0xff;
	REG(0x18) = page >> 8 & 0xff;
	REG(0x24) = size;
	REG(0x28) = SRAM;
	REG(0x0c) = 0x00 | 3 << 8 | 1 << 22 | extra;	/* READ0, 3 address bytes, data */
	REG(0x08) = 1;
	for (n = 0; n < 100000 && (REG(0x08) & 1); n++)
		usleep(10);
	for (i = 0; i < BUF; i++) {
		if (buf[i] != 0xa5)
			written = i + 1;
		if (cc < 0 && i + 1 < BUF && buf[i] == 0xcc && buf[i + 1] == 0xdd)
			cc = i;
	}
	printf("%-6s w%-4d cc%-4d ", name, written, cc);
	for (i = 0; i < 8; i++)
		printf("%02x", buf[i]);
	putchar(' ');
	for (i = 512; i < 520; i++)
		printf("%02x", buf[i]);
	putchar('\n');
}

int main(int argc, char **argv)
{
	static const int show[] = { 0x00, 0x04, 0x0c, 0x2c, 0x30, 0x40, 0x48, 0x4c, 0x50, 0x54 };
	long offset = offset_of_filesystem();
	uint32_t page;
	unsigned i;
	int fd;

	/* Without the NAND driver: where the device tree puts it */
	if (offset < 0)
		offset = 0x200000;
	page = offset / 512;
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	regs = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, PHX);
	buf = mmap(NULL, BUF, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SRAM);
	if (regs == MAP_FAILED || buf == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	printf("regs:");
	for (i = 0; i < sizeof(show) / sizeof(show[0]); i++)
		printf("%s%02x=%x", i == 5 ? "\n " : " ", show[i], REG(show[i]));
	putchar('\n');
	read_id("none", 0);
	read_id("b21", 1 << 21);
	printf("page %#x: written, CC DD at, data[0..7] [512..519]\n", page);

	try("528", page, 0, 528);
	try("b21", page, 1 << 21, 528);
	try("b23", page, 1 << 23, 528);
	try("b24", page, 1 << 24, 528);
	try("x4", page, 0, 528 * 4);
	try("132", page, 0, 132);
	if (argc > 1 && !strcmp(argv[1], "write")) {
		long size = -1;
		char line[64];
		FILE *f;
		int n = -1, m;

		f = fopen("/proc/mtd", "r");
		while (f && fgets(line, sizeof(line), f))
			if (strstr(line, "\"filesystem\"") && sscanf(line, "mtd%d: %lx", &m, &size) == 2)
				n = m;
		if (f)
			fclose(f);
		if (n < 0 || size <= 0)
			size = 0x1e00000;
		write_test(page, size / 512);
	}
	return 0;
}
