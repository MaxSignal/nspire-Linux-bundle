/*
 * nspire-sleepd: ctrl+ON puts the calculator to sleep, as in the
 * TI-Nspire OS, and ON wakes it up. Watches the input devices with the ON
 * key (KEY_POWER) or a ctrl key, and on ON pressed while ctrl is held,
 * blanks the screen and writes "mem" to /sys/power/state: processes and
 * devices stop until the ON key's interrupt wakes the system up, and the
 * screen shows what it showed again.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/vt.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <unistd.h>

#define MAX_DEVS	8
#define BLANK_VT	"12"	/* a console nobody uses */
#define BLANK		"\033[?25l\033[0m\033[2J"
#define BIT_SET(a, b)	((a)[(b) / 8] >> ((b) % 8) & 1)

static int has_keys(int fd)
{
	unsigned char keys[KEY_MAX / 8 + 1] = { 0 };

	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0)
		return 0;
	return BIT_SET(keys, KEY_POWER) || BIT_SET(keys, KEY_LEFTCTRL) ||
	       BIT_SET(keys, KEY_RIGHTCTRL);
}

/*
 * The screen: the classic models' LCD can neither be turned off (their
 * "backlight" is the contrast) nor stopped and started again without
 * shifting the picture, and shows nothing where its pixels have the
 * console's background, which nspire-console makes white. So the screen
 * goes to an empty console with the same colours, filled up to its edges,
 * without the kernel's messages, while asleep.
 */
static void fill_screen(void)
{
	static unsigned char buf[4096];
	int fd = open("/dev/fb0", O_RDWR), i;

	if (fd < 0)
		return;
	/* the background, as the console drew it in the top left corner */
	if (read(fd, buf, 4) == 4) {
		for (i = 4; i < (int)sizeof(buf); i++)
			buf[i] = buf[i % 4];
		lseek(fd, 0, SEEK_SET);
		while (write(fd, buf, sizeof(buf)) > 0)
			;
	}
	close(fd);
}
static int console_level(int level)
{
	FILE *f = fopen("/proc/sys/kernel/printk", "r");
	int old = 7;

	if (f) {
		if (fscanf(f, "%d", &old) != 1)
			old = 7;
		fclose(f);
	}
	klogctl(8, NULL, level);	/* SYSLOG_ACTION_CONSOLE_LEVEL */
	return old;
}

static int switch_vt(int vt)
{
	struct vt_stat st = { 0 };
	int fd = open("/dev/tty0", O_RDWR);

	if (fd < 0)
		return 0;
	ioctl(fd, VT_GETSTATE, &st);
	if (ioctl(fd, VT_ACTIVATE, vt) == 0)
		ioctl(fd, VT_WAITACTIVE, vt);
	close(fd);
	return st.v_active;
}

static void sleep_now(void)
{
	int fd, level, vt;

	/* an empty console, with the console's colours, cursor hidden */
	if (system("/usr/sbin/nspire-console /dev/tty" BLANK_VT) < 0)
		perror("nspire-sleepd: nspire-console");
	fd = open("/dev/tty" BLANK_VT, O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		if (write(fd, BLANK, sizeof(BLANK) - 1) < 0)
			perror("nspire-sleepd: tty" BLANK_VT);
		close(fd);
	}
	level = console_level(1);
	vt = switch_vt(atoi(BLANK_VT));
	fill_screen();

	/* returns once the system is awake again */
	fd = open("/sys/power/state", O_WRONLY);
	if (fd >= 0) {
		if (write(fd, "mem", 3) < 0)
			perror("nspire-sleepd: /sys/power/state");
		close(fd);
	}

	if (vt > 0)
		switch_vt(vt);
	console_level(level);
}

int main(void)
{
	struct pollfd pfd[MAX_DEVS];
	struct input_event ev;
	struct dirent *de;
	char path[16 + sizeof(de->d_name)];
	int n = 0, i, ctrl = 0;
	DIR *dir = opendir("/dev/input");

	while (dir && (de = readdir(dir)) && n < MAX_DEVS) {
		if (strncmp(de->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		pfd[n].fd = open(path, O_RDONLY | O_NONBLOCK);
		if (pfd[n].fd < 0)
			continue;
		if (!has_keys(pfd[n].fd)) {
			close(pfd[n].fd);
			continue;
		}
		pfd[n++].events = POLLIN;
	}
	if (dir)
		closedir(dir);
	if (!n)
		return 1;

	while (poll(pfd, n, -1) > 0) {
		for (i = 0; i < n; i++) {
			if (!(pfd[i].revents & POLLIN))
				continue;
			while (read(pfd[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				if (ev.type != EV_KEY)
					continue;
				if (ev.code == KEY_LEFTCTRL || ev.code == KEY_RIGHTCTRL)
					ctrl = ev.value != 0;
				else if (ev.code == KEY_POWER && ev.value == 1 && ctrl) {
					sleep_now();
					/* ctrl was let go while asleep */
					ctrl = 0;
				}
			}
		}
	}
	return 1;
}
