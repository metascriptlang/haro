#ifndef HARO_NATIVE_PTY_H
#define HARO_NATIVE_PTY_H

#include <stdint.h>

#define PTY_OPEN_TABLE_FULL (-1)
#define PTY_OPEN_BLANK_COMMAND (-2)
#define PTY_OPEN_BAD_ENV (-3)
#define PTY_OPEN_RESOURCES (-4)
#define PTY_OPEN_FORK_FAILED (-5)
#define PTY_OPEN_EXEC_FAILED (-6)
#define PTY_OPEN_THREAD_FAILED (-7)

void ptySetWake(void (*wake)(void));
int ptyOpen(
	const char* commandLine, const char* cwd, const uint8_t* envBlock, int64_t envLen,
	int cols, int rows, int widthPx, int heightPx
);
int64_t ptyRead(int id, uint8_t* buf, int64_t cap);
int ptyWait(int id, int timeoutMs);
int64_t ptyWrite(int id, const uint8_t* data, int64_t len);
int ptyResize(int id, int cols, int rows, int widthPx, int heightPx);
int ptyExited(int id);
int ptyExitCode(int id);
void ptyClose(int id);
#ifdef _WIN32
#define PTY_TREE_FAILED (-1)
#define PTY_TREE_TRUNCATED (-2)
int64_t ptyTreeNames(int id, uint8_t* buf, int64_t cap);
#else
int ptyMaster(int id);
int ptyChildPid(int id);
int ptyExitSignal(int id);
#endif
uint8_t** ptyEnviron(void);

#endif
