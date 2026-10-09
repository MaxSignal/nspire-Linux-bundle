/*
 * nspire-sleepd: ctrl+ON puts the calculator to sleep, as in the
 * TI-Nspire OS, and ON wakes it up. Watches the input devices with the ON
 * key (KEY_POWER) or a ctrl key, and on ON pressed while ctrl is held,
 * writes "mem" to /sys/power/state: processes and devices stop (the
 * screen too) until the ON key's interrupt wakes the system.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define MAX_DEVS	8
#define BIT_SET(a, b)	((a)[(b) / 8] >> ((b) % 8) & 1)

static int has_keys(int fd)
{
	unsigned char keys[KEY_MAX / 8 + 1] = { 0 };

	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0)
		return 0;
	return BIT_SET(keys, KEY_POWER) || BIT_SET(keys, KEY_LEFTCTRL) ||
	       BIT_SET(keys, KEY_RIGHTCTRL);
}

static void sleep_now(void)
{
	int fd = open("/sys/power/state", O_WRONLY);

	if (fd < 0)
		return;
	/* returns once the system is awake again */
	if (write(fd, "mem", 3) < 0)
		perror("nspire-sleepd: /sys/power/state");
	close(fd);
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
