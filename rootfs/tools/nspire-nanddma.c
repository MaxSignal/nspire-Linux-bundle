/*
 * nspire-nanddma: on the classic models, read the first page of the
 * "filesystem" partition with the NAND controller's DMA (0xB8000000) into
 * the internal SRAM, with variants of the operation, to find how it moves
 * one byte of the chip to one byte of memory. Prints the controller's
 * registers, then per variant: how many bytes of the buffer were written,
 * where CC DD (a FlashFX unit header) first shows, data[0..7] and the
 * bytes at 512..519.
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

int main(void)
{
	static const int show[] = { 0x00, 0x04, 0x0c, 0x2c, 0x30, 0x40, 0x48, 0x4c, 0x50, 0x54 };
	long offset = offset_of_filesystem();
	uint32_t page;
	unsigned i;
	int fd;

	if (offset < 0) {
		printf("no \"filesystem\" partition\n");
		return 1;
	}
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
	printf("\npage %#x: written, CC DD at, data[0..7] [512..519]\n", page);

	try("528", page, 0, 528);
	try("b21", page, 1 << 21, 528);
	try("b23", page, 1 << 23, 528);
	try("b24", page, 1 << 24, 528);
	try("x4", page, 0, 528 * 4);
	try("132", page, 0, 132);
	return 0;
}
