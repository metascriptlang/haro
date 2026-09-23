#ifndef TERMINATOR_CONPTY_H
#define TERMINATOR_CONPTY_H

#include <stdint.h>

int ptyOpen(const char* commandLine, int cols, int rows);
int64_t ptyRead(int id, uint8_t* buf, int64_t cap);
int64_t ptyWrite(int id, const uint8_t* data, int64_t len);
int ptyResize(int id, int cols, int rows);
int ptyExited(int id);
int ptyExitCode(int id);
void ptyClose(int id);

#endif
