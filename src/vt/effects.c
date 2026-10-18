#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#endif

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
	GhosttyRenderState state;
	int held;
	int64_t heldAtMs;
	int64_t holdLimitMs;
	uint8_t* clip;
	int64_t clipLen;
	int clipPending;
	uint8_t* readReply;
	int64_t readReplyLen;
	int readPending;
	int readNew;
} Effects;

static Effects effects[EFFECTS_MAX];

static void append(Effects* e, const uint8_t* bytes, size_t n) {
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

static void writePty(GhosttyTerminal terminal, void* userdata, const uint8_t* bytes, size_t n) {
	(void)terminal;
	append(userdata, bytes, n);
}

static Effects* slot(int id) {
	if (id < 0 || id >= EFFECTS_MAX || !effects[id].used) return NULL;
	return &effects[id];
}

#ifdef _WIN32
static int64_t nowMs(void) {
	return (int64_t)GetTickCount64();
}
#else
static int64_t nowMs(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
#endif

static void onRenderHold(GhosttyTerminal terminal, void* userdata, bool held) {
	Effects* e = userdata;
	e->held = held;
	if (!held) return;
	ghostty_render_state_update(e->state, terminal);
	e->heldAtMs = nowMs();
}

static bool onDeviceAttributes(GhosttyTerminal terminal, void* userdata, GhosttyDeviceAttributes* out) {
	(void)terminal; (void)userdata;
	memset(out, 0, sizeof *out);
	out->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_LEVEL_2;
	out->primary.features[0] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
	out->primary.features[1] = GHOSTTY_DA_FEATURE_CLIPBOARD;
	out->primary.num_features = 2;
	out->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
	out->secondary.firmware_version = 10;
	return true;
}

static GhosttyString onXtversion(GhosttyTerminal terminal, void* userdata) {
	(void)terminal; (void)userdata;
	GhosttyString name = { (const uint8_t*)"haro", 4 };
	return name;
}

static void onClipboardWrite(GhosttyTerminal terminal, void* userdata, const GhosttyClipboardWrite* write) {
	(void)terminal;
	Effects* e = userdata;
	GhosttyClipboardWriteReply reply = { sizeof reply, GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED, false };
	if (write->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD) {
		for (size_t i = 0; i < write->contents_len; i++) {
			const GhosttyClipboardContent* c = &write->contents[i];
			if (c->mime.len != 10 || memcmp(c->mime.ptr, "text/plain", 10) != 0) continue;
			uint8_t* copy = malloc(c->data.len > 0 ? c->data.len : 1);
			if (!copy) {
				reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY;
				break;
			}
			memcpy(copy, c->data.ptr, c->data.len);
			free(e->clip);
			e->clip = copy;
			e->clipLen = (int64_t)c->data.len;
			e->clipPending = 1;
			reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
			break;
		}
	}
	write->reply(write, &reply);
}

/* An OSC 52 read cannot wait for the user inside vt_write: the reply must be given before the callback
   returns. So the callback answers "denied", which makes libghostty write an empty clipboard reply
   ("ESC ] 52 ; c ;" and the terminator the program used), takes those bytes back out of the reply
   queue and keeps them. vtClipboardAnswer later writes the same frame with the clipboard in it, or
   empty. A request while one is pending, for a clipboard Windows has no equivalent of, or in kitty's
   OSC 5522 protocol, whose answer is not this frame, keeps its refusal. */
#define OSC52_REPLY "\x1b]52;"

static void onClipboardRead(GhosttyTerminal terminal, void* userdata, const GhosttyClipboardRead* read) {
	(void)terminal;
	Effects* e = userdata;
	GhosttyClipboardReadReply reply = { sizeof reply, GHOSTTY_CLIPBOARD_READ_RESULT_DENIED, NULL, 0, NULL, 0, false };
	int64_t mark = e->len;
	read->reply(read, &reply);
	if (e->readPending || read->location != GHOSTTY_CLIPBOARD_LOCATION_STANDARD || e->outOfMemory) return;
	int64_t n = e->len - mark;
	if (n < 8 || memcmp(e->data + mark, OSC52_REPLY, sizeof OSC52_REPLY - 1) != 0) return;
	uint8_t* copy = malloc((size_t)n);
	if (!copy) return;
	memcpy(copy, e->data + mark, (size_t)n);
	e->len = mark;
	free(e->readReply);
	e->readReply = copy;
	e->readReplyLen = n;
	e->readPending = 1;
	e->readNew = 1;
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

#define HOLD_LIMIT_MS 1000

int vtEffectsOpen(GhosttyTerminal terminal, GhosttyRenderState state) {
	int id = -1;
	for (int i = 0; i < EFFECTS_MAX; i++) {
		if (!effects[i].used) { id = i; break; }
	}
	if (id < 0) return -1;
	Effects* e = &effects[id];
	memset(e, 0, sizeof *e);
	e->used = 1;
	e->state = state;
	e->holdLimitMs = HOLD_LIMIT_MS;
	if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, e) != GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)writePty)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, (const void*)onBell)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)onTitleChanged)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)onPwdChanged)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void*)onRenderHold)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
			(const void*)onDeviceAttributes) != GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, (const void*)onXtversion)
			!= GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
			(const void*)onClipboardWrite) != GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
			(const void*)onClipboardRead) != GHOSTTY_SUCCESS) {
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

/* The text of the last OSC 52 write to the standard clipboard that the host has not taken. -1: none
   pending. -2: buf is too small; the write stays pending and vtClipboardSize gives its length. */
int64_t vtClipboardTake(int id, uint8_t* buf, int64_t cap) {
	Effects* e = slot(id);
	if (!e || !e->clipPending) return -1;
	if (e->clipLen > cap) return -2;
	memcpy(buf, e->clip, (size_t)e->clipLen);
	e->clipPending = 0;
	return e->clipLen;
}

int64_t vtClipboardSize(int id) {
	Effects* e = slot(id);
	return e && e->clipPending ? e->clipLen : -1;
}

/* 1 once per OSC 52 read request that waits for an answer. */
int vtClipboardReadTake(int id) {
	Effects* e = slot(id);
	if (!e || !e->readNew) return 0;
	e->readNew = 0;
	return 1;
}

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void appendBase64(Effects* e, const uint8_t* in, int64_t n) {
	for (int64_t i = 0; i < n; i += 3) {
		uint32_t v = (uint32_t)in[i] << 16;
		if (i + 1 < n) v |= (uint32_t)in[i + 1] << 8;
		if (i + 2 < n) v |= in[i + 2];
		uint8_t out[4] = { (uint8_t)b64[(v >> 18) & 63], (uint8_t)b64[(v >> 12) & 63],
			i + 1 < n ? (uint8_t)b64[(v >> 6) & 63] : '=', i + 2 < n ? (uint8_t)b64[v & 63] : '=' };
		append(e, out, 4);
	}
}

/* Writes the reply the pending read waits for: the clipboard text when allow is set, else empty.
   -1: no read pending. */
int vtClipboardAnswer(int id, const uint8_t* text, int64_t len, int allow) {
	Effects* e = slot(id);
	if (!e || !e->readPending) return -1;
	int64_t head = 0;
	for (int semis = 0; head < e->readReplyLen && semis < 2;) {
		if (e->readReply[head++] == ';') semis++;
	}
	append(e, e->readReply, (size_t)head);
	if (allow) appendBase64(e, text, len);
	append(e, e->readReply + head, (size_t)(e->readReplyLen - head));
	free(e->readReply);
	e->readReply = NULL;
	e->readReplyLen = 0;
	e->readPending = 0;
	return 0;
}

void vtHoldLimit(int id, int64_t ms) {
	Effects* e = slot(id);
	if (e) e->holdLimitMs = ms;
}

/* Whether synchronized output holds the screen. A hold older than the limit ends here: the terminal
   has no clock and a program that never releases would freeze the screen (terminal.h, "Timeouts"). */
int vtHeld(int id, GhosttyTerminal terminal) {
	Effects* e = slot(id);
	if (!e || !e->held) return 0;
	if (nowMs() - e->heldAtMs < e->holdLimitMs) return 1;
	GhosttyTerminalModeConfig mode = { GHOSTTY_MODE_SYNC_OUTPUT, false };
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode);
	e->held = 0;
	return 0;
}

void vtEffectsClose(int id, GhosttyTerminal terminal) {
	Effects* e = slot(id);
	if (!e) return;
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, NULL);
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
	if (e->mouse) ghostty_mouse_encoder_free(e->mouse);
	if (e->mouseEvent) ghostty_mouse_event_free(e->mouseEvent);
	free(e->clip);
	free(e->readReply);
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
