/*
 * nspire-nandstray: on the classic models, run the NAND controller's
 * operations the way the kernel driver does (page read, READ STATUS, lone
 * READ0 pointer, page program, block erase) with the DMA pointed into the
 * internal SRAM, and show for each how many bytes it wrote around its
 * buffer, and where: for DMA the driver does not expect. Programs and
 * erases only a unit of the "filesystem" partition the TI-Nspire OS does
 * not use (all its pages erased), and erases it again.
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
#define WIN		0x4000		/* watched */
#define T		0x1000		/* the DMA buffer, in the window */

#define REG(o)		(*(volatile uint32_t *)(regs + (o)))

static uint8_t *regs;
static volatile uint8_t *win;

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

static void run(uint32_t op)
{
	int n;

	REG(0x0c) = op;
	REG(0x08) = 1;
	for (n = 0; n < 100000 && (REG(0x08) & 1); n++)
		usleep(10);
}

static void fill(void)
{
	int i;

	for (i = 0; i < WIN; i++)
		win[i] = 0xa5;
}

/* What the last operation wrote in the window (expected: [T, T + len)) */
static void report(const char *name, unsigned len)
{
	int i, lo = -1, hi = -1, in = 0, out = 0;

	for (i = 0; i < WIN; i++) {
		if (win[i] == 0xa5)
			continue;
		if (lo < 0)
			lo = i;
		hi = i;
		if (i >= T && i < (int)(T + len))
			in++;
		else
			out++;
	}
	printf("%-9s in %4d out %4d", name, in, out);
	if (lo >= 0)
		printf(" [%+d..%+d]", lo - T, hi - T);
	printf(" dma=%08x size=%u st=%02x\n", REG(0x28), REG(0x24), REG(0x34) & 0xff);
}

static void addr(uint32_t a0, uint32_t a1, uint32_t a2)
{
	REG(0x10) = a0;
	REG(0x14) = a1;
	REG(0x18) = a2;
}

static void dma(unsigned size)
{
	REG(0x24) = size;
	REG(0x28) = SRAM + T;
}

static int erased(uint32_t page)
{
	int i;

	fill();
	addr(0, page & 0xff, page >> 8 & 0xff);
	dma(528);
	run(0x00 | 3 << 8 | 1 << 21 | 1 << 22);
	for (i = 0; i < 528; i++)
		if (win[T + i] != 0xff)
			return 0;
	return 1;
}

static void status(const char *name)
{
	fill();
	dma(1);
	run(0x70 | 1 << 22);
	report(name, 4);
}

int main(void)
{
	long offset = offset_of_filesystem();
	uint32_t part, unit, first = 0, page, p;
	int fd, i;

	if (offset < 0)
		offset = 0x200000;
	part = offset / 512;
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	regs = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, PHX);
	win = mmap(NULL, WIN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SRAM);
	if (regs == MAP_FAILED || win == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	/* The last unit (64 pages) of the 960 whose pages are all erased */
	for (unit = 960; unit-- > 900 && !first; ) {
		for (p = 0; p < 64 && erased(part + unit * 64 + p); p++)
			;
		if (p == 64)
			first = part + unit * 64;
	}
	if (!first) {
		printf("no unused unit\n");
		return 1;
	}
	page = first + 1;
	printf("unit %u, page %#x\n", (first - part) / 64, page);

	/* Page read: READ0, 3 address bytes, data (bytes) */
	fill();
	addr(0, page & 0xff, page >> 8 & 0xff);
	dma(528);
	run(0x00 | 3 << 8 | 1 << 21 | 1 << 22);
	report("read", 528);
	status("status");

	/* Lone READ0 (the pointer before a program), DMA left as a read's */
	fill();
	dma(528);
	run(0x00);
	report("pointer", 0);

	/* Program, from the SRAM: SEQIN, 3 address bytes, write, data, PAGEPROG */
	REG(0x04) = 1;
	fill();
	for (i = 0; i < 528; i++)
		win[T + i] = (uint8_t)(i * 7 + 3);
	addr(0, page & 0xff, page >> 8 & 0xff);
	dma(528);
	run(0x80 | 3 << 8 | 1 << 11 | 0x10 << 12 | 1 << 20 | 1 << 21 | 1 << 22);
	for (i = 0; i < 528; i++)	/* the source is not a stray write */
		win[T + i] = 0xa5;
	report("program", 0);
	{
		int n = 0, last = -1;

		for (i = 528; i < 528 + 4096 + 64; i++)
			if (win[T + i] != 0xa5) {
				n++;
				last = i;
			}
		printf("after the source: %d bytes written, the last at +%d:", n, last);
		for (i = 528; i < 528 + 16; i++)
			printf(" %02x", win[T + i]);
		printf(" ... at +4096:");
		for (i = 4096; i < 4096 + 16; i++)
			printf(" %02x", win[T + i]);
		putchar('\n');
	}
	status("status");
	for (i = 0; i < 8 && !(REG(0x34) & 0x40); i++)
		status("status");

	/* Read it back */
	fill();
	addr(0, page & 0xff, page >> 8 & 0xff);
	dma(528);
	run(0x00 | 3 << 8 | 1 << 21 | 1 << 22);
	for (i = 0; i < 528 && win[T + i] == (uint8_t)(i * 7 + 3); i++)
		;
	printf("read back: %s\n", i == 528 ? "OK" : "BAD");

	/* Erase: ERASE1, 2 address bytes, ERASE2; DMA left as a read's */
	fill();
	addr(first & 0xff, first >> 8 & 0xff, 0);
	dma(528);
	run(0x60 | 2 << 8 | 0xd0 << 12 | 1 << 20);
	report("erase", 0);
	status("status");
	for (i = 0; i < 8 && !(REG(0x34) & 0x40); i++)
		status("status");
	REG(0x04) = 0;
	printf("erased again: %s\n", erased(page) ? "OK" : "NO");
	return 0;
}
