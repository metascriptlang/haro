#include "wake.h"

#include <stdatomic.h>

static atomic_int wakeFd = -1;

#ifdef _WIN32
int serverWakeOpen(void) { return -1; }
void serverWakeClose(void) {}
void serverWake(void) {}
#else
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef MSG_NOSIGNAL
#define WAKE_SEND_FLAGS (MSG_NOSIGNAL | MSG_DONTWAIT)
#else
#define WAKE_SEND_FLAGS MSG_DONTWAIT
#endif

int serverWakeOpen(void) {
	int fds[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
#ifdef SO_NOSIGPIPE
	int on = 1;
	setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
	fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
	int old = atomic_exchange(&wakeFd, fds[1]);
	if (old >= 0) close(old);
	return fds[0];
}

void serverWakeClose(void) {
	int fd = atomic_exchange(&wakeFd, -1);
	if (fd >= 0) close(fd);
}

void serverWake(void) {
	int fd = atomic_load(&wakeFd);
	if (fd < 0) return;
	char b = 1;
	(void)send(fd, &b, 1, WAKE_SEND_FLAGS);
}
#endif
