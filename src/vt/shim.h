#ifndef HARO_VT_SHIM_H
#define HARO_VT_SHIM_H

#include <stdint.h>
#include <ghostty/vt.h>

GhosttyResult vtGridRef(GhosttyTerminal terminal, GhosttyPointTag tag, int x, int y, GhosttyGridRef* out);
void vtScroll(GhosttyTerminal terminal, GhosttyTerminalScrollViewportTag tag, int64_t amount);
int vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out);
int vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal);

#endif
