#include <string.h>

#include "shim.h"

/* msc cannot import GhosttyPoint or the scroll viewport union, which hold a fixed array:
   .inbox/compiler/2026-10-15-cimport-fixed-array-field-emits-unresolved-sizedarray.md */

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

int vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out) {
	return (int)ghostty_terminal_grid_ref_track(terminal, pointAt(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0), out);
}

int vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal) {
	return (int)ghostty_tracked_grid_ref_set(ref, terminal, pointAt(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0));
}

/* msc cannot copy out of GhosttyString.ptr yet:
   .inbox/compiler/2026-10-19-element-of-an-imported-const-pointer-field-into-an-array-slot-dies-in-codegen.md */
int64_t vtString(GhosttyTerminal terminal, GhosttyTerminalData key, uint8_t* buf, int64_t cap) {
	GhosttyString s;
	memset(&s, 0, sizeof s);
	if (ghostty_terminal_get(terminal, key, &s) != GHOSTTY_SUCCESS) return -1;
	if ((int64_t)s.len <= cap) memcpy(buf, s.ptr, s.len);
	return (int64_t)s.len;
}
