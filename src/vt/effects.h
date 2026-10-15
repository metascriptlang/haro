#ifndef TERMINATOR_VT_EFFECTS_H
#define TERMINATOR_VT_EFFECTS_H

#include <stdint.h>
#include <ghostty/vt.h>

int vtEffectsOpen(GhosttyTerminal terminal);
int64_t vtRepliesTake(int id, uint8_t* buf, int64_t cap);
void vtEffectsClose(int id, GhosttyTerminal terminal);

int vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out);
int vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal);

#endif
