#include <stdlib.h>
#include <string.h>

#include "effects.h"

#ifdef __EMSCRIPTEN__
static const uint8_t maxLog2Align = 4;

static void* heapAlloc(void* ctx, size_t len, uint8_t log2Align, uintptr_t ra) {
	(void)ctx; (void)ra;
	if (log2Align > maxLog2Align) return NULL;
	size_t align = (size_t)1 << log2Align;
	if (align < sizeof(void*)) align = sizeof(void*);
	void* p = NULL;
	return posix_memalign(&p, align, len) == 0 ? p : NULL;
}

static bool heapResize(void* ctx, void* mem, size_t len, uint8_t log2Align, size_t newLen, uintptr_t ra) {
	(void)ctx; (void)mem; (void)len; (void)log2Align; (void)newLen; (void)ra;
	return false;
}

static void* heapRemap(void* ctx, void* mem, size_t len, uint8_t log2Align, size_t newLen, uintptr_t ra) {
	(void)ctx; (void)mem; (void)len; (void)log2Align; (void)newLen; (void)ra;
	return NULL;
}

static void heapFree(void* ctx, void* mem, size_t len, uint8_t log2Align, uintptr_t ra) {
	(void)ctx; (void)len; (void)log2Align; (void)ra;
	free(mem);
}

static char heapCtx;
static const GhosttyAllocatorVtable heapVtable = { heapAlloc, heapResize, heapRemap, heapFree };
static const GhosttyAllocator heapAllocator = { &heapCtx, &heapVtable };

const GhosttyAllocator* vtAllocator(void) {
	return &heapAllocator;
}
#else
const GhosttyAllocator* vtAllocator(void) {
	return NULL;
}
#endif

#define EFFECTS_MAX 16

typedef struct {
	int used;
	uint8_t* data;
	int64_t len;
	int64_t cap;
	int outOfMemory;
} Effects;

static Effects effects[EFFECTS_MAX];

static void writePty(GhosttyTerminal terminal, void* userdata, const uint8_t* bytes, size_t n) {
	(void)terminal;
	Effects* e = userdata;
	if (e->outOfMemory) return;
	if (e->len + (int64_t)n > e->cap) {
		int64_t cap = e->cap ? e->cap : 256;
		while (cap < e->len + (int64_t)n) cap *= 2;
		uint8_t* grown = realloc(e->data, (size_t)cap);
		if (!grown) {
			e->outOfMemory = 1;
			return;
		}
		e->data = grown;
		e->cap = cap;
	}
	memcpy(e->data + e->len, bytes, n);
	e->len += (int64_t)n;
}

static Effects* slot(int id) {
	if (id < 0 || id >= EFFECTS_MAX || !effects[id].used) return NULL;
	return &effects[id];
}

int vtEffectsOpen(GhosttyTerminal terminal) {
	int id = -1;
	for (int i = 0; i < EFFECTS_MAX; i++) {
		if (!effects[i].used) { id = i; break; }
	}
	if (id < 0) return -1;
	Effects* e = &effects[id];
	memset(e, 0, sizeof *e);
	e->used = 1;
	if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, e) != GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)writePty)
			!= GHOSTTY_SUCCESS) {
		e->used = 0;
		return -1;
	}
	return id;
}

int64_t vtRepliesTake(int id, uint8_t* buf, int64_t cap) {
	Effects* e = slot(id);
	if (!e) return -1;
	if (e->outOfMemory) return -2;
	int64_t n = e->len < cap ? e->len : cap;
	if (n > 0) {
		memcpy(buf, e->data, (size_t)n);
		memmove(e->data, e->data + n, (size_t)(e->len - n));
		e->len -= n;
	}
	return n;
}

void vtEffectsClose(int id, GhosttyTerminal terminal) {
	Effects* e = slot(id);
	if (!e) return;
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
	free(e->data);
	memset(e, 0, sizeof *e);
}

/* msc cannot import GhosttyPoint: .inbox/compiler/2026-10-15-c-import-fixed-array-member-sizedarray.md */
static GhosttyPoint viewportTop(void) {
	GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_VIEWPORT };
	return p;
}

int vtTopTrack(GhosttyTerminal terminal, GhosttyTrackedGridRef* out) {
	return (int)ghostty_terminal_grid_ref_track(terminal, viewportTop(), out);
}

int vtTopAnchor(GhosttyTrackedGridRef ref, GhosttyTerminal terminal) {
	return (int)ghostty_tracked_grid_ref_set(ref, terminal, viewportTop());
}
