#include <stdlib.h>
#include <string.h>

#include "effects.h"
#include "state.h"

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
	int bells;
	int titleChanged;
	int pwdChanged;
	GhosttyMouseEncoder mouse;
	GhosttyMouseEvent mouseEvent;
	int mouseSignature;
	int mouseSize[4];
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

static void onBell(GhosttyTerminal terminal, void* userdata) {
	(void)terminal;
	((Effects*)userdata)->bells++;
}

static void onTitleChanged(GhosttyTerminal terminal, void* userdata) {
	(void)terminal;
	((Effects*)userdata)->titleChanged = 1;
}

static void onPwdChanged(GhosttyTerminal terminal, void* userdata) {
	(void)terminal;
	((Effects*)userdata)->pwdChanged = 1;
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
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, (const void*)onBell)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)onTitleChanged)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)onPwdChanged)
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

/* out: bells since the last take, title changed, pwd changed. A take clears them. */
int vtEventsTake(int id, int32_t* out, int64_t cap) {
	Effects* e = slot(id);
	if (!e || cap < 3) return -1;
	out[0] = e->bells;
	out[1] = e->titleChanged;
	out[2] = e->pwdChanged;
	e->bells = 0;
	e->titleChanged = 0;
	e->pwdChanged = 0;
	return 0;
}

void vtEffectsClose(int id, GhosttyTerminal terminal) {
	Effects* e = slot(id);
	if (!e) return;
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
	if (e->mouse) ghostty_mouse_encoder_free(e->mouse);
	if (e->mouseEvent) ghostty_mouse_event_free(e->mouseEvent);
	free(e->data);
	memset(e, 0, sizeof *e);
}

static int mouseOpen(Effects* e) {
	if (e->mouse && e->mouseEvent) return 1;
	if (!e->mouse && ghostty_mouse_encoder_new(vtAllocator(), &e->mouse) != GHOSTTY_SUCCESS) return 0;
	if (!e->mouseEvent && ghostty_mouse_event_new(vtAllocator(), &e->mouseEvent) != GHOSTTY_SUCCESS) return 0;
	bool track = true;
	ghostty_mouse_encoder_setopt(e->mouse, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track);
	e->mouseSignature = -1;
	return 1;
}

/* The report for one pointer event under the modes the program set; 0 bytes when the mode reports
   nothing for it (a motion within the cell it last reported, for one). The encoder forgets the last
   cell on every setopt_from_terminal and size, so each is set only when its value changed. action is a
   GhosttyMouseAction, button a GhosttyMouseButton with 0 for none. x and y are surface pixels with
   the grid at the origin. -2: buf too small. */
int64_t vtMouseEncode(int id, GhosttyTerminal terminal, int action, int button, int mods,
	float x, float y, int cellWidth, int cellHeight, int width, int height, int anyPressed,
	uint8_t* buf, int64_t cap) {
	Effects* e = slot(id);
	if (!e || !mouseOpen(e)) return -1;
	int signature = vtMouseSignature(terminal);
	if (signature < 0) return -1;
	if (signature != e->mouseSignature) {
		ghostty_mouse_encoder_setopt_from_terminal(e->mouse, terminal);
		e->mouseSignature = signature;
	}
	int geometry[4] = { cellWidth, cellHeight, width, height };
	if (memcmp(geometry, e->mouseSize, sizeof geometry) != 0) {
		GhosttyMouseEncoderSize size;
		memset(&size, 0, sizeof size);
		size.size = sizeof size;
		size.screen_width = (uint32_t)width;
		size.screen_height = (uint32_t)height;
		size.cell_width = (uint32_t)cellWidth;
		size.cell_height = (uint32_t)cellHeight;
		ghostty_mouse_encoder_setopt(e->mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
		memcpy(e->mouseSize, geometry, sizeof geometry);
	}
	bool pressed = anyPressed != 0;
	GhosttyMousePosition at = { x, y };
	ghostty_mouse_encoder_setopt(e->mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
	ghostty_mouse_event_set_action(e->mouseEvent, (GhosttyMouseAction)action);
	if (button == 0) ghostty_mouse_event_clear_button(e->mouseEvent);
	else ghostty_mouse_event_set_button(e->mouseEvent, (GhosttyMouseButton)button);
	ghostty_mouse_event_set_mods(e->mouseEvent, (GhosttyMods)mods);
	ghostty_mouse_event_set_position(e->mouseEvent, at);
	size_t written = 0;
	GhosttyResult r = ghostty_mouse_encoder_encode(e->mouse, e->mouseEvent, (char*)buf, (size_t)cap, &written);
	if (r == GHOSTTY_SUCCESS) return (int64_t)written;
	return r == GHOSTTY_OUT_OF_SPACE ? -2 : -1;
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
