#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
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

#include "byteQueue.h"
#include "nativePty.h"
#include "wakeHook.h"

#define PTY_MAX 16
#define CLOSE_GRACE_MS 1000
#define EXIT_QUIET_MS 50
#define EXIT_DRAIN_MS 1000
#define CHILD_FD_SCAN_MAX 65536

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
	ByteQueue in;
	ByteQueue out;
	int writeFailed;
	int stopping;
	int closed;
	int outOfMemory;
	int exited;
	int exitCode;
	int exitSignal;
} Pty;

static Pty ptys[PTY_MAX];
static pthread_mutex_t table = PTHREAD_MUTEX_INITIALIZER;

void ptySetWake(void (*wake)(void)) {
	wakeInstall(wake);
}

static void signalReady(Pty* p) {
	p->ready = 1;
	pthread_cond_broadcast(&p->changed);
}

static int append(Pty* p, const uint8_t* bytes, int64_t n) {
	pthread_mutex_lock(&p->lock);
	while (!p->stopping && p->in.len - p->in.head + n > READ_LIMIT) {
		pthread_cond_wait(&p->space, &p->lock);
	}
	if (p->stopping) {
		pthread_mutex_unlock(&p->lock);
		return 0;
	}
	if (!queuePush(&p->in, bytes, n, 65536)) {
		p->outOfMemory = 1;
		signalReady(p);
		pthread_mutex_unlock(&p->lock);
		wake();
		return 0;
	}
	signalReady(p);
	pthread_mutex_unlock(&p->lock);
	wake();
	return 1;
}

static int64_t nowMs(void) {
	struct timespec at;
	clock_gettime(CLOCK_MONOTONIC, &at);
	return (int64_t)at.tv_sec * 1000 + at.tv_nsec / 1000000;
}

static int stopping(Pty* p) {
	pthread_mutex_lock(&p->lock);
	int stop = p->stopping;
	pthread_mutex_unlock(&p->lock);
	return stop;
}

static void* readLoop(void* arg) {
	Pty* p = arg;
	uint8_t chunk[16384];
	int top = p->master > p->stop[0] ? p->master : p->stop[0];
	int64_t drainUntil = -1;
	for (;;) {
		fd_set fds;
		FD_ZERO(&fds);
		FD_SET(p->master, &fds);
		FD_SET(p->stop[0], &fds);
		struct timeval quiet = { 0, EXIT_QUIET_MS * 1000 };
		int ready = select(top + 1, &fds, NULL, NULL, drainUntil < 0 ? NULL : &quiet);
		if (ready < 0) {
			if (errno == EINTR) continue;
			break;
		}
		if (ready == 0 || (drainUntil >= 0 && nowMs() > drainUntil)) break;
		if (FD_ISSET(p->stop[0], &fds)) {
			if (drainUntil >= 0 || stopping(p)) break;
			char exited;
			ssize_t _read = read(p->stop[0], &exited, 1);
			(void)_read;
			drainUntil = nowMs() + EXIT_DRAIN_MS;
			continue;
		}
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
	ByteQueue batch = {0};
	pthread_mutex_lock(&p->lock);
	for (;;) {
		while (!p->stopping && p->out.len == 0) pthread_cond_wait(&p->pending, &p->lock);
		if (p->stopping) break;
		ByteQueue full = p->out;
		p->out = batch;
		p->out.len = 0;
		batch = full;
		pthread_mutex_unlock(&p->lock);
		int64_t n = batch.len;
		int ok = 1;
		for (int64_t done = 0; ok && done < n;) {
			ssize_t wrote = write(p->master, batch.data + done, (size_t)(n - done));
			if (wrote < 0 && errno == EINTR) continue;
			ok = wrote >= 0;
			if (ok) done += wrote;
		}
		if (batch.cap > BATCH_KEEP) {
			free(batch.data);
			batch = (ByteQueue){0};
		}
		pthread_mutex_lock(&p->lock);
		if (!ok) p->writeFailed = 1;
	}
	pthread_mutex_unlock(&p->lock);
	free(batch.data);
	return NULL;
}

static void* waitLoop(void* arg) {
	Pty* p = arg;
	siginfo_t info;
	memset(&info, 0, sizeof info);
	while (waitid(P_PID, (id_t)p->pid, &info, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
	pthread_mutex_lock(&p->lock);
	p->exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
	p->exitSignal = info.si_code == CLD_EXITED ? 0 : info.si_status;
	p->exited = 1;
	pthread_cond_broadcast(&p->changed);
	pthread_mutex_unlock(&p->lock);
	ssize_t _wrote = write(p->stop[1], "", 1);
	(void)_wrote;
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
	if (id < 0 || id >= PTY_MAX) return NULL;
	pthread_mutex_lock(&table);
	int used = ptys[id].used;
	pthread_mutex_unlock(&table);
	return used ? &ptys[id] : NULL;
}

static int claimSlot(void) {
	int id = -1;
	pthread_mutex_lock(&table);
	for (int i = 0; id < 0 && i < PTY_MAX; i++) {
		if (!ptys[i].used) {
			ptys[i].used = 1;
			id = i;
		}
	}
	pthread_mutex_unlock(&table);
	return id;
}

static void releaseSlot(int id) {
	pthread_mutex_lock(&table);
	memset(&ptys[id], 0, sizeof ptys[id]);
	pthread_mutex_unlock(&table);
}

static void closeOnExec(int fd) {
	fcntl(fd, F_SETFD, FD_CLOEXEC);
}

extern char** environ;

#define COUNT(a) (sizeof (a) / sizeof (a)[0])

static const char* const REPLACED[] = {
	"TERM=", "COLORTERM=", "TERM_PROGRAM=", "TERM_PROGRAM_VERSION=", "TERM_SESSION_ID=", "VTE_VERSION=",
};
static const char* const ADDED[] = { "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Haro" };

static int replaced(const char* entry, int newPwd, int newLang) {
	if (newPwd && strncmp(entry, "PWD=", 4) == 0) return 1;
	if (newLang && strncmp(entry, "LANG=", 5) == 0) return 1;
	for (size_t i = 0; i < COUNT(REPLACED); i++) {
		if (strncmp(entry, REPLACED[i], strlen(REPLACED[i])) == 0) return 1;
	}
	return 0;
}

static char** childEnv(const char* cwd, const char* langEntry, char** pwd) {
	int newPwd = cwd[0] != '\0';
	int newLang = langEntry[0] != '\0';
	size_t count = 0;
	while (environ[count] != NULL) count++;
	char** env = malloc((count + COUNT(ADDED) + 3) * sizeof *env);
	*pwd = newPwd ? malloc(strlen(cwd) + sizeof "PWD=") : NULL;
	if (env == NULL || (newPwd && *pwd == NULL)) {
		free(env);
		free(*pwd);
		return NULL;
	}
	size_t n = 0;
	for (size_t i = 0; i < count; i++) {
		if (!replaced(environ[i], newPwd, newLang)) env[n++] = environ[i];
	}
	for (size_t i = 0; i < COUNT(ADDED); i++) env[n++] = (char*)ADDED[i];
	if (newLang) env[n++] = (char*)langEntry;
	if (newPwd) {
		strcpy(*pwd, "PWD=");
		strcat(*pwd, cwd);
		env[n++] = *pwd;
	}
	env[n] = NULL;
	return env;
}

static void execChild(char** argv, char** env, const char* cwd, int failed, int fdLimit) {
	sigset_t none;
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	int inherited[] = { SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD };
	for (size_t i = 0; i < COUNT(inherited); i++) signal(inherited[i], SIG_DFL);
	for (int fd = STDERR_FILENO + 1; fd < fdLimit; fd++) {
		if (fd != failed) close(fd);
	}
	if (cwd[0] != '\0' && chdir(cwd) != 0) {
		size_t last = 0;
		while (env[last] != NULL) last++;
		env[last - 1] = NULL;
	}
	environ = env;
	execvp(argv[0], argv);
	int err = errno;
	ssize_t _wrote = write(failed, &err, sizeof err);
	(void)_wrote;
	_exit(127);
}

static struct winsize winsizeOf(int cols, int rows, int widthPx, int heightPx) {
	return (struct winsize){
		(unsigned short)rows, (unsigned short)cols, (unsigned short)widthPx, (unsigned short)heightPx,
	};
}

static int openIn(
	int id, const char* commandLine, const char* cwd, const char* langEntry,
	int cols, int rows, int widthPx, int heightPx
) {
	wordexp_t words;
	int parsed = wordexp(commandLine, &words, WRDE_NOCMD);
	if (parsed != 0) {
		if (parsed == WRDE_NOSPACE) wordfree(&words);
		return -1;
	}
	char* pwd = NULL;
	char** env = words.we_wordc == 0 ? NULL : childEnv(cwd, langEntry, &pwd);
	int failed[2];
	if (env == NULL || pipe(failed) != 0) {
		free(env);
		free(pwd);
		wordfree(&words);
		return -1;
	}
	closeOnExec(failed[0]);
	closeOnExec(failed[1]);

	struct winsize size = winsizeOf(cols, rows, widthPx, heightPx);
	int master = -1;
	struct rlimit files;
	int fdLimit = getrlimit(RLIMIT_NOFILE, &files) == 0 && files.rlim_cur < CHILD_FD_SCAN_MAX
		? (int)files.rlim_cur : CHILD_FD_SCAN_MAX;
	pid_t pid = forkpty(&master, NULL, NULL, &size);
	if (pid == 0) execChild(words.we_wordv, env, cwd, failed[1], fdLimit);
	if (pid > 0) closeOnExec(master);
	free(env);
	free(pwd);
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
	int stopped = got == 0 && master < FD_SETSIZE && pipe(stop) == 0;
	if (stopped && stop[0] >= FD_SETSIZE) {
		close(stop[0]);
		close(stop[1]);
		stopped = 0;
	}
	if (!stopped) {
		if (got == 0) kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		close(master);
		return -1;
	}
	closeOnExec(stop[0]);
	closeOnExec(stop[1]);

	Pty* p = &ptys[id];
	p->pid = pid;
	p->master = master;
	p->stop[0] = stop[0];
	p->stop[1] = stop[1];
	p->exitCode = -1;
	p->exitSignal = 0;
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

int ptyOpen(
	const char* commandLine, const char* cwd, const char* langEntry,
	int cols, int rows, int widthPx, int heightPx
) {
	int id = claimSlot();
	if (id < 0) return -1;
	int opened = openIn(id, commandLine, cwd, langEntry, cols, rows, widthPx, heightPx);
	if (opened < 0) releaseSlot(id);
	return opened;
}

int64_t ptyRead(int id, uint8_t* buf, int64_t cap) {
	Pty* p = slot(id);
	if (!p) return -1;
	pthread_mutex_lock(&p->lock);
	if (p->outOfMemory) {
		pthread_mutex_unlock(&p->lock);
		return -2;
	}
	int64_t n = queueTake(&p->in, buf, cap);
	if (n > 0) pthread_cond_signal(&p->space);
	int ended = p->closed && p->in.len == 0;
	if (p->in.len == 0 && !p->closed) p->ready = 0;
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
	if (!queuePush(&p->out, data, len, 4096)) {
		pthread_mutex_unlock(&p->lock);
		return -2;
	}
	pthread_cond_signal(&p->pending);
	pthread_mutex_unlock(&p->lock);
	return len;
}

int ptyResize(int id, int cols, int rows, int widthPx, int heightPx) {
	Pty* p = slot(id);
	if (!p) return -1;
	struct winsize size = winsizeOf(cols, rows, widthPx, heightPx);
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

int ptyMaster(int id) {
	Pty* p = slot(id);
	return p ? p->master : -1;
}

int ptyExitSignal(int id) {
	Pty* p = slot(id);
	if (!p) return 0;
	pthread_mutex_lock(&p->lock);
	int signal = p->exitSignal;
	pthread_mutex_unlock(&p->lock);
	return signal;
}

int ptyChildPid(int id) {
	Pty* p = slot(id);
	return p ? (int)p->pid : -1;
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
	kill(-p->pid, SIGHUP);
	if (p->threads > 0) {
		struct timespec deadline = deadlineAfter(CLOSE_GRACE_MS);
		pthread_mutex_lock(&p->lock);
		int r = 0;
		while (!p->exited && r == 0) r = pthread_cond_timedwait(&p->changed, &p->lock, &deadline);
		pthread_mutex_unlock(&p->lock);
	}
	if (!ptyExited(id)) kill(-p->pid, SIGKILL);
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
	free(p->in.data);
	free(p->out.data);
	releaseSlot(id);
}
