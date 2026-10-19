#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <wordexp.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#include "nativePty.h"

#define PTY_MAX 16
#define READ_LIMIT (4 << 20)
#define BATCH_KEEP (4 << 20)
#define CLOSE_GRACE_MS 1000

typedef struct {
	int used;
	pid_t pid;
	int master;
	int stop[2];
	pthread_t reader;
	pthread_t waiter;
	pthread_t writer;
	int threads;
	pthread_mutex_t lock;
	pthread_cond_t changed;
	pthread_cond_t space;
	pthread_cond_t pending;
	int ready;
	uint8_t* data;
	int64_t head;
	int64_t len;
	int64_t cap;
	uint8_t* out;
	int64_t outLen;
	int64_t outCap;
	int writeFailed;
	int stopping;
	int closed;
	int outOfMemory;
	int exited;
	int exitCode;
} Pty;

static Pty ptys[PTY_MAX];
static void (*wakeApp)(void);

void ptySetWake(void (*wake)(void)) {
	wakeApp = wake;
}

static void wake(void) {
	if (wakeApp) wakeApp();
}

static void signalReady(Pty* p) {
	p->ready = 1;
	pthread_cond_broadcast(&p->changed);
}

static int append(Pty* p, const uint8_t* bytes, int64_t n) {
	pthread_mutex_lock(&p->lock);
	while (!p->stopping && p->len - p->head + n > READ_LIMIT) pthread_cond_wait(&p->space, &p->lock);
	if (p->stopping) {
		pthread_mutex_unlock(&p->lock);
		return 0;
	}
	if (p->head > 0 && p->len + n > p->cap) {
		memmove(p->data, p->data + p->head, (size_t)(p->len - p->head));
		p->len -= p->head;
		p->head = 0;
	}
	if (p->len + n > p->cap) {
		int64_t cap = p->cap ? p->cap : 65536;
		while (cap < p->len + n) cap *= 2;
		uint8_t* grown = realloc(p->data, (size_t)cap);
		if (!grown) {
			p->outOfMemory = 1;
			signalReady(p);
			pthread_mutex_unlock(&p->lock);
			wake();
			return 0;
		}
		p->data = grown;
		p->cap = cap;
	}
	memcpy(p->data + p->len, bytes, (size_t)n);
	p->len += n;
	signalReady(p);
	pthread_mutex_unlock(&p->lock);
	wake();
	return 1;
}

static void* readLoop(void* arg) {
	Pty* p = arg;
	uint8_t chunk[16384];
	int top = p->master > p->stop[0] ? p->master : p->stop[0];
	for (;;) {
		fd_set fds;
		FD_ZERO(&fds);
		FD_SET(p->master, &fds);
		FD_SET(p->stop[0], &fds);
		if (select(top + 1, &fds, NULL, NULL, NULL) < 0) {
			if (errno == EINTR) continue;
			break;
		}
		if (FD_ISSET(p->stop[0], &fds)) break;
		ssize_t got = read(p->master, chunk, sizeof chunk);
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0 || !append(p, chunk, got)) break;
	}
	pthread_mutex_lock(&p->lock);
	while (!p->exited) pthread_cond_wait(&p->changed, &p->lock);
	p->closed = 1;
	signalReady(p);
	pthread_mutex_unlock(&p->lock);
	wake();
	return NULL;
}

static void* writeLoop(void* arg) {
	Pty* p = arg;
	uint8_t* batch = NULL;
	int64_t batchCap = 0;
	pthread_mutex_lock(&p->lock);
	for (;;) {
		while (!p->stopping && p->outLen == 0) pthread_cond_wait(&p->pending, &p->lock);
		if (p->stopping) break;
		uint8_t* full = p->out;
		int64_t fullCap = p->outCap;
		int64_t n = p->outLen;
		p->out = batch;
		p->outCap = batchCap;
		p->outLen = 0;
		batch = full;
		batchCap = fullCap;
		pthread_mutex_unlock(&p->lock);
		int ok = 1;
		for (int64_t done = 0; ok && done < n;) {
			ssize_t wrote = write(p->master, batch + done, (size_t)(n - done));
			if (wrote < 0 && errno == EINTR) continue;
			ok = wrote >= 0;
			if (ok) done += wrote;
		}
		if (batchCap > BATCH_KEEP) {
			free(batch);
			batch = NULL;
			batchCap = 0;
		}
		pthread_mutex_lock(&p->lock);
		if (!ok) p->writeFailed = 1;
	}
	pthread_mutex_unlock(&p->lock);
	free(batch);
	return NULL;
}

static void* waitLoop(void* arg) {
	Pty* p = arg;
	siginfo_t info;
	memset(&info, 0, sizeof info);
	while (waitid(P_PID, (id_t)p->pid, &info, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
	pthread_mutex_lock(&p->lock);
	p->exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
	p->exited = 1;
	pthread_cond_broadcast(&p->changed);
	pthread_mutex_unlock(&p->lock);
	return NULL;
}

static struct timespec deadlineAfter(int ms) {
	struct timespec at;
	clock_gettime(CLOCK_REALTIME, &at);
	int64_t ns = at.tv_nsec + (int64_t)(ms % 1000) * 1000000;
	at.tv_sec += ms / 1000 + ns / 1000000000;
	at.tv_nsec = ns % 1000000000;
	return at;
}

static Pty* slot(int id) {
	if (id < 0 || id >= PTY_MAX || !ptys[id].used) return NULL;
	return &ptys[id];
}

static void closeOnExec(int fd) {
	fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static void execChild(char** argv, const char* cwd, int failed) {
	sigset_t none;
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	int inherited[] = { SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD };
	for (size_t i = 0; i < sizeof inherited / sizeof inherited[0]; i++) signal(inherited[i], SIG_DFL);
	setenv("TERM", "xterm-256color", 1);
	setenv("COLORTERM", "truecolor", 1);
	if (cwd[0] != '\0' && chdir(cwd) == 0) setenv("PWD", cwd, 1);
	execvp(argv[0], argv);
	int err = errno;
	ssize_t _wrote = write(failed, &err, sizeof err);
	(void)_wrote;
	_exit(127);
}

int ptyOpen(const char* commandLine, const char* cwd, int cols, int rows) {
	int id = -1;
	for (int i = 0; i < PTY_MAX; i++) {
		if (!ptys[i].used) { id = i; break; }
	}
	if (id < 0) return -1;

	wordexp_t words;
	int parsed = wordexp(commandLine, &words, WRDE_NOCMD);
	if (parsed != 0) {
		if (parsed == WRDE_NOSPACE) wordfree(&words);
		return -1;
	}
	int failed[2];
	if (words.we_wordc == 0 || pipe(failed) != 0) {
		wordfree(&words);
		return -1;
	}
	closeOnExec(failed[0]);
	closeOnExec(failed[1]);

	struct winsize size = { (unsigned short)rows, (unsigned short)cols, 0, 0 };
	int master = -1;
	pid_t pid = forkpty(&master, NULL, NULL, &size);
	if (pid == 0) execChild(words.we_wordv, cwd, failed[1]);
	wordfree(&words);
	close(failed[1]);
	if (pid < 0) {
		close(failed[0]);
		return -1;
	}

	int err = 0;
	ssize_t got;
	while ((got = read(failed[0], &err, sizeof err)) < 0 && errno == EINTR) {}
	close(failed[0]);
	int stop[2] = { -1, -1 };
	if (got != 0 || master >= FD_SETSIZE || pipe(stop) != 0) {
		if (got == 0) kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		close(master);
		return -1;
	}
	closeOnExec(master);
	closeOnExec(stop[0]);
	closeOnExec(stop[1]);

	Pty* p = &ptys[id];
	memset(p, 0, sizeof *p);
	p->used = 1;
	p->pid = pid;
	p->master = master;
	p->stop[0] = stop[0];
	p->stop[1] = stop[1];
	p->exitCode = -1;
	pthread_mutex_init(&p->lock, NULL);
	pthread_cond_init(&p->changed, NULL);
	pthread_cond_init(&p->space, NULL);
	pthread_cond_init(&p->pending, NULL);
	void* (*loops[])(void*) = { waitLoop, readLoop, writeLoop };
	while (p->threads < 3) {
		pthread_t* thread = p->threads == 0 ? &p->waiter : p->threads == 1 ? &p->reader : &p->writer;
		if (pthread_create(thread, NULL, loops[p->threads], p) != 0) {
			ptyClose(id);
			return -1;
		}
		p->threads++;
	}
	return id;
}

int64_t ptyRead(int id, uint8_t* buf, int64_t cap) {
	Pty* p = slot(id);
	if (!p) return -1;
	pthread_mutex_lock(&p->lock);
	if (p->outOfMemory) {
		pthread_mutex_unlock(&p->lock);
		return -2;
	}
	int64_t held = p->len - p->head;
	int64_t n = held < cap ? held : cap;
	if (n > 0) {
		memcpy(buf, p->data + p->head, (size_t)n);
		p->head += n;
		if (p->head == p->len) p->head = p->len = 0;
		pthread_cond_signal(&p->space);
	}
	int ended = p->closed && p->len == 0;
	if (p->len == 0 && !p->closed) p->ready = 0;
	pthread_mutex_unlock(&p->lock);
	if (n == 0 && ended) return -1;
	return n;
}

int ptyWait(int id, int timeoutMs) {
	Pty* p = slot(id);
	if (!p) return -1;
	struct timespec deadline = deadlineAfter(timeoutMs);
	pthread_mutex_lock(&p->lock);
	int r = 0;
	while (!p->ready && r == 0) r = pthread_cond_timedwait(&p->changed, &p->lock, &deadline);
	int ready = p->ready;
	pthread_mutex_unlock(&p->lock);
	if (ready) return 1;
	return r == ETIMEDOUT ? 0 : -2;
}

int64_t ptyWrite(int id, const uint8_t* data, int64_t len) {
	Pty* p = slot(id);
	if (!p) return -1;
	pthread_mutex_lock(&p->lock);
	if (p->writeFailed) {
		pthread_mutex_unlock(&p->lock);
		return -1;
	}
	if (p->outLen + len > p->outCap) {
		int64_t cap = p->outCap ? p->outCap : 4096;
		while (cap < p->outLen + len) cap *= 2;
		uint8_t* grown = realloc(p->out, (size_t)cap);
		if (!grown) {
			pthread_mutex_unlock(&p->lock);
			return -2;
		}
		p->out = grown;
		p->outCap = cap;
	}
	memcpy(p->out + p->outLen, data, (size_t)len);
	p->outLen += len;
	pthread_cond_signal(&p->pending);
	pthread_mutex_unlock(&p->lock);
	return len;
}

int ptyResize(int id, int cols, int rows) {
	Pty* p = slot(id);
	if (!p) return -1;
	struct winsize size = { (unsigned short)rows, (unsigned short)cols, 0, 0 };
	return ioctl(p->master, TIOCSWINSZ, &size) == 0 ? 0 : -1;
}

int ptyExited(int id) {
	Pty* p = slot(id);
	if (!p) return 0;
	pthread_mutex_lock(&p->lock);
	int exited = p->exited;
	pthread_mutex_unlock(&p->lock);
	return exited;
}

int ptyExitCode(int id) {
	Pty* p = slot(id);
	if (!p) return -1;
	pthread_mutex_lock(&p->lock);
	int code = p->exitCode;
	pthread_mutex_unlock(&p->lock);
	return code;
}

void ptyClose(int id) {
	Pty* p = slot(id);
	if (!p) return;
	pthread_mutex_lock(&p->lock);
	p->stopping = 1;
	pthread_cond_broadcast(&p->space);
	pthread_cond_broadcast(&p->pending);
	pthread_mutex_unlock(&p->lock);
	kill(p->pid, SIGHUP);
	if (p->threads > 0) {
		struct timespec deadline = deadlineAfter(CLOSE_GRACE_MS);
		pthread_mutex_lock(&p->lock);
		int r = 0;
		while (!p->exited && r == 0) r = pthread_cond_timedwait(&p->changed, &p->lock, &deadline);
		pthread_mutex_unlock(&p->lock);
	}
	if (!ptyExited(id)) kill(p->pid, SIGKILL);
	if (p->threads > 0) pthread_join(p->waiter, NULL);
	waitpid(p->pid, NULL, 0);
	if (p->threads > 2) pthread_join(p->writer, NULL);
	ssize_t _wrote = write(p->stop[1], "", 1);
	(void)_wrote;
	if (p->threads > 1) pthread_join(p->reader, NULL);
	close(p->master);
	close(p->stop[0]);
	close(p->stop[1]);
	pthread_cond_destroy(&p->pending);
	pthread_cond_destroy(&p->space);
	pthread_cond_destroy(&p->changed);
	pthread_mutex_destroy(&p->lock);
	free(p->data);
	free(p->out);
	memset(p, 0, sizeof *p);
}
