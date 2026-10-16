#ifndef HARO_VT_STATE_H
#define HARO_VT_STATE_H

#include <stdint.h>
#include <ghostty/vt.h>

int vtModes(GhosttyTerminal terminal, int32_t* out, int64_t cap);
int64_t vtFocusEncode(GhosttyTerminal terminal, int gained, uint8_t* buf, int64_t cap);
int vtMouseSignature(GhosttyTerminal terminal);
int vtCursorLook(GhosttyRenderState state, int32_t* out, int64_t cap);
int64_t vtString(GhosttyTerminal terminal, int which, uint8_t* buf, int64_t cap);

#endif
