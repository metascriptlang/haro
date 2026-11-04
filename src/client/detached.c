#define _GNU_SOURCE
#include <fcntl.h>
#include <spawn.h>
#include <sys/types.h>
#include "detached.h"

extern char **environ;

int haroStartDetached(const char *path, const char *flag) {
	posix_spawnattr_t attr;
	posix_spawn_file_actions_t files;
	if (posix_spawnattr_init(&attr) != 0) return -1;
	if (posix_spawn_file_actions_init(&files) != 0) {
		posix_spawnattr_destroy(&attr);
		return -1;
	}
	short flags = POSIX_SPAWN_SETSID;
#ifdef __APPLE__
	flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
	int rc = posix_spawnattr_setflags(&attr, flags);
	if (rc == 0) rc = posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0);
	if (rc == 0) rc = posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0);
	if (rc == 0) rc = posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0);
	pid_t pid = 0;
	char *argv[] = { (char *)path, (char *)flag, NULL };
	if (rc == 0) rc = posix_spawn(&pid, path, &files, &attr, argv, environ);
	posix_spawn_file_actions_destroy(&files);
	posix_spawnattr_destroy(&attr);
	return rc == 0 ? (int)pid : -rc;
}
