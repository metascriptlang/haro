#ifndef HARO_VT_STATE_H
#define HARO_VT_STATE_H

#include <stdint.h>
#include <ghostty/vt.h>

int64_t vtString(GhosttyTerminal terminal, int which, uint8_t* buf, int64_t cap);

#endif
