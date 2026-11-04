#define _GNU_SOURCE
#include <fcntl.h>
#include <spawn.h>
#include <sys/types.h>
#include "spawn.h"

extern char **environ;

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int closeOnExec(int fd) {
	int flags = fcntl(fd, F_GETFD);
	return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

int haroSpawnSocket(const char *joined, const char *errPath, int *fd) {
	char *line = strdup(joined);
	if (line == NULL) return -ENOMEM;
	int count = 1;
	for (char *c = line; *c; c++) if (*c == '\n') count++;
	char **argv = calloc((size_t)count + 1, sizeof(char *));
	if (argv == NULL) {
		free(line);
		return -ENOMEM;
	}
	int n = 0;
	argv[n++] = line;
	for (char *c = line; *c; c++) {
		if (*c == '\n') {
			*c = '\0';
			argv[n++] = c + 1;
		}
	}
	int pair[2] = { -1, -1 };
	int rc = socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0 ? 0 : errno;
	if (rc == 0 && (closeOnExec(pair[0]) != 0 || closeOnExec(pair[1]) != 0)) rc = errno;
	posix_spawn_file_actions_t files;
	int filesMade = 0;
	if (rc == 0) {
		rc = posix_spawn_file_actions_init(&files);
		filesMade = rc == 0;
	}
	if (rc == 0) rc = posix_spawn_file_actions_adddup2(&files, pair[1], 0);
	if (rc == 0) rc = posix_spawn_file_actions_adddup2(&files, pair[1], 1);
	if (rc == 0) {
		rc = posix_spawn_file_actions_addopen(&files, 2, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	}
	posix_spawnattr_t attr;
	int attrMade = 0;
	if (rc == 0) {
		rc = posix_spawnattr_init(&attr);
		attrMade = rc == 0;
	}
#ifdef __APPLE__
	if (rc == 0) rc = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
#endif
	pid_t pid = 0;
	if (rc == 0) rc = posix_spawnp(&pid, argv[0], &files, &attr, argv, environ);
	if (attrMade) posix_spawnattr_destroy(&attr);
	if (filesMade) posix_spawn_file_actions_destroy(&files);
	free(argv);
	free(line);
	if (rc != 0) {
		if (pair[0] >= 0) close(pair[0]);
		if (pair[1] >= 0) close(pair[1]);
		return -rc;
	}
	close(pair[1]);
	*fd = pair[0];
	return (int)pid;
}

int haroReap(int pid, int *code) {
	int status = 0;
	pid_t got = waitpid((pid_t)pid, &status, WNOHANG);
	if (got == 0) return 0;
	if (got < 0) return -1;
	if (WIFEXITED(status)) *code = WEXITSTATUS(status);
	else if (WIFSIGNALED(status)) *code = 128 + WTERMSIG(status);
	else *code = -1;
	return 1;
}

int haroShutdownWrite(int fd) {
	return shutdown(fd, SHUT_WR);
}
