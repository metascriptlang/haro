#include <ghostty/vt.h>
/* msc cannot import GhosttyPoint, a union with uint64_t _padding[2]:
   .inbox/compiler/2026-10-15-c-import-fixed-array-member-sizedarray.md */
static inline int sr_track(GhosttyTerminal t, int tag, unsigned x, unsigned y, GhosttyTrackedGridRef *out) {
	GhosttyPoint p;
	p.tag = (GhosttyPointTag)tag;
	p.value.coordinate.x = (uint16_t)x;
	p.value.coordinate.y = y;
	return (int)ghostty_terminal_grid_ref_track(t, p, out);
}
static inline int sr_set(GhosttyTrackedGridRef r, GhosttyTerminal t, int tag, unsigned x, unsigned y) {
	GhosttyPoint p;
	p.tag = (GhosttyPointTag)tag;
	p.value.coordinate.x = (uint16_t)x;
	p.value.coordinate.y = y;
	return (int)ghostty_tracked_grid_ref_set(r, t, p);
}
