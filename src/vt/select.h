#ifndef HARO_VT_SELECT_H
#define HARO_VT_SELECT_H

#include <stdint.h>
#include <ghostty/vt.h>

/* Every point is a screen coordinate: y counts from the top of scrollback. */

void vtScroll(GhosttyTerminal terminal, int tag, int64_t amount);

int vtPromptJump(GhosttyTerminal terminal, int delta);

int vtSelSet(GhosttyTerminal terminal, int sx, int sy, int ex, int ey, int rectangle);
void vtSelClear(GhosttyTerminal terminal);
int vtSelGet(GhosttyTerminal terminal, int32_t* out, int64_t cap);
int vtSelWord(GhosttyTerminal terminal, int x, int y, int32_t* out, int64_t cap);
int vtSelLine(GhosttyTerminal terminal, int x, int y, int32_t* out, int64_t cap);
int64_t vtSelText(GhosttyTerminal terminal, uint8_t* buf, int64_t cap);

int64_t vtPasteEncode(GhosttyTerminal terminal, const uint8_t* data, int64_t len,
	int allowUnsafe, uint8_t* out, int64_t cap);

#endif
