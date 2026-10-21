#include <string.h>

#include "shim.h"

/* msc cannot import GhosttyPoint or the scroll viewport union, which hold a fixed array:
   .inbox/compiler/2026-10-15-c-import-fixed-array-member-sizedarray.md */

static GhosttyPoint pointAt(GhosttyPointTag tag, int x, int y) {
	GhosttyPoint p;
	memset(&p, 0, sizeof p);
	p.tag = tag;
	p.value.coordinate.x = (uint16_t)x;
	p.value.coordinate.y = (uint32_t)y;
	return p;
}

GhosttyResult vtGridRef(GhosttyTerminal terminal, GhosttyPointTag tag, int x, int y, GhosttyGridRef* out) {
	if (x < 0 || y < 0) return GHOSTTY_INVALID_VALUE;
	*out = GHOSTTY_INIT_SIZED(GhosttyGridRef);
	return ghostty_terminal_grid_ref(terminal, pointAt(tag, x, y), out);
}

void vtScroll(GhosttyTerminal terminal, GhosttyTerminalScrollViewportTag tag, int64_t amount) {
	GhosttyTerminalScrollViewport v;
	memset(&v, 0, sizeof v);
	v.tag = tag;
	if (tag == GHOSTTY_SCROLL_VIEWPORT_DELTA) v.value.delta = (intptr_t)amount;
	if (tag == GHOSTTY_SCROLL_VIEWPORT_ROW) v.value.row = (size_t)amount;
	ghostty_terminal_scroll_viewport(terminal, v);
}

GhosttyResult vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out) {
	return ghostty_terminal_grid_ref_track(terminal, pointAt(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0), out);
}

GhosttyResult vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal) {
	return ghostty_tracked_grid_ref_set(ref, terminal, pointAt(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0));
}
