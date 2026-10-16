#ifndef HARO_VT_EFFECTS_H
#define HARO_VT_EFFECTS_H

#include <stdint.h>
#include <ghostty/vt.h>

const GhosttyAllocator* vtAllocator(void);

int vtEffectsOpen(GhosttyTerminal terminal, GhosttyRenderState state);
void vtHoldLimit(int id, int64_t ms);
int vtHeld(int id, GhosttyTerminal terminal);
int64_t vtRepliesTake(int id, uint8_t* buf, int64_t cap);
int64_t vtMouseEncode(int id, GhosttyTerminal terminal, int action, int button, int mods,
	float x, float y, int cellWidth, int cellHeight, int width, int height, int anyPressed,
	uint8_t* buf, int64_t cap);
int vtEventsTake(int id, int32_t* out, int64_t cap);
void vtEffectsClose(int id, GhosttyTerminal terminal);

int vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out);
int vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal);

#endif
