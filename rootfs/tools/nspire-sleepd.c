/*
 * nspire-sleepd: ctrl+ON puts the calculator to sleep, as in the
 * TI-Nspire OS, and ON wakes it up. Watches the input devices with the ON
 * key (KEY_POWER) or a ctrl key, and when ON, pressed while ctrl was held,
 * is let go, turns the screen off and writes "mem" to /sys/power/state:
 * processes and devices stop until the ON key's interrupt wakes the system
 * up, and the screen comes back on.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/vt.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <unistd.h>

#define MAX_DEVS	8
#define SUSPEND_VT	MAX_NR_CONSOLES	/* the kernel's suspend console */
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
 * The kernel's messages would turn the screen on again: keep them off the
 * console while asleep
 */
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

static void put(const char *path, const char *value)
{
	int fd = open(path, O_WRONLY);

	if (fd < 0)
		return;
	if (write(fd, value, strlen(value)) < 0)
		perror(path);
	close(fd);
}

/* Show a console, the one shown before */
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
	int level = console_level(1), vt;

	/*
	 * The kernel shows its suspend console while suspending, and the
	 * screen comes on again with it: be there already
	 */
	vt = switch_vt(SUSPEND_VT);
	/* the screen off: the panel powered down (4), and the backlight */
	put("/sys/class/graphics/fb0/blank", "4");
	/* returns once the system is awake again */
	put("/sys/power/state", "mem");
	put("/sys/class/graphics/fb0/blank", "0");
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
	int n = 0, i, ctrl = 0, armed = 0;
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
				else if (ev.code == KEY_POWER && ev.value == 1)
					armed = ctrl;
				else if (ev.code == KEY_POWER && ev.value == 0 && armed) {
					/* once ON is let go: held, it wakes the system up */
					sleep_now();
					/* ctrl was let go while asleep */
					ctrl = armed = 0;
				}
			}
		}
	}
	return 1;
}
