#ifndef HARO_NATIVE_PTY_H
#define HARO_NATIVE_PTY_H

#include <stdint.h>

void ptySetWake(void (*wake)(void));
int ptyOpen(
	const char* commandLine, const char* cwd, const char* langEntry,
	int cols, int rows, int widthPx, int heightPx
);
int64_t ptyRead(int id, uint8_t* buf, int64_t cap);
int ptyWait(int id, int timeoutMs);
int64_t ptyWrite(int id, const uint8_t* data, int64_t len);
int ptyResize(int id, int cols, int rows, int widthPx, int heightPx);
int ptyExited(int id);
int ptyExitCode(int id);
void ptyClose(int id);

#endif
