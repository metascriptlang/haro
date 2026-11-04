#include "wake.h"

#include <stdatomic.h>
#include <stdint.h>

#ifdef _WIN32
#include <winsock2.h>
#define WAKE_SEND(fd, b) send((SOCKET)(intptr_t)(fd), (b), 1, 0)
#else
#include <sys/socket.h>
#ifdef MSG_NOSIGNAL
#define WAKE_SEND(fd, b) send((fd), (b), 1, MSG_NOSIGNAL | MSG_DONTWAIT)
#else
#define WAKE_SEND(fd, b) send((fd), (b), 1, MSG_DONTWAIT)
#endif
#endif

static atomic_int wakeFd = -1;

void serverWakeTo(int fd) {
#ifdef SO_NOSIGPIPE
	if (fd >= 0) {
		int on = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
	}
#endif
	atomic_store(&wakeFd, fd);
}

void serverWake(void) {
	int fd = atomic_load(&wakeFd);
	if (fd < 0) return;
	char b = 1;
	(void)WAKE_SEND(fd, &b);
}
