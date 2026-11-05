#include "pump.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef MSG_NOSIGNAL
#define PUMP_FLAGS MSG_NOSIGNAL
#else
#define PUMP_FLAGS 0
#endif

typedef struct {
	int from;
	int to;
} Pump;

static Pump pumps[4];
static int pumpCount = 0;

static void *pumpLoop(void *arg) {
	Pump *p = (Pump *)arg;
	char buf[65536];
	for (;;) {
		ssize_t got = read(p->from, buf, sizeof(buf));
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0) break;
		char *at = buf;
		while (got > 0) {
			ssize_t put = send(p->to, at, (size_t)got, PUMP_FLAGS);
			if (put < 0 && errno == EINTR) continue;
			if (put < 0) goto done;
			at += put;
			got -= put;
		}
	}
done:
	shutdown(p->to, SHUT_WR);
	close(p->to);
	return NULL;
}

int haroPumpToSocket(int from) {
	if (pumpCount >= (int)(sizeof(pumps) / sizeof(pumps[0]))) return -1;
	int fds[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
#ifdef SO_NOSIGPIPE
	int on = 1;
	setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
	Pump *p = &pumps[pumpCount++];
	p->from = from;
	p->to = fds[1];
	pthread_t thread;
	if (pthread_create(&thread, NULL, pumpLoop, p) != 0) {
		close(fds[0]);
		close(fds[1]);
		pumpCount--;
		return -1;
	}
	pthread_detach(thread);
	return fds[0];
}
