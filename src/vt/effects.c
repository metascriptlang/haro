#include <stdlib.h>
#include <string.h>

#include "effects.h"

#ifdef __EMSCRIPTEN__
/* msc cannot build the vtable's function pointers:
   .inbox/compiler/2026-10-16-function-into-c-function-pointer-emits-msclosure.md */
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

/* The callbacks' state lives in vt.ms, which defines these. */
void haroVtWritePty(void* effects, uint8_t* bytes, int64_t n);
void haroVtBell(GhosttyTerminal terminal, void* effects);
void haroVtTitleChanged(GhosttyTerminal terminal, void* effects);
void haroVtPwdChanged(GhosttyTerminal terminal, void* effects);
void haroVtRenderHold(GhosttyTerminal terminal, void* effects, bool held);
bool haroVtDeviceAttributes(GhosttyTerminal terminal, void* effects, GhosttyDeviceAttributes* out);
bool haroVtSize(GhosttyTerminal terminal, void* effects, GhosttySizeReportSize* out);
void haroVtClipboardWritten(void* effects, uint8_t* text, int64_t n);
int64_t haroVtRepliesLength(void* effects);
void haroVtClipboardRead(void* effects, int64_t mark);
GhosttyString haroVtXtversion(GhosttyTerminal terminal, void* effects);
void haroVtDesktopNotification(GhosttyTerminal terminal, void* effects, const GhosttyTerminalDesktopNotification* notification);

/* msc has no integer as wide as size_t on every target (32 bits on wasm32) for a callback's
   parameter. */
static void writePty(GhosttyTerminal terminal, void* userdata, const uint8_t* bytes, size_t n) {
	(void)terminal;
	haroVtWritePty(userdata, (uint8_t*)bytes, (int64_t)n);
}

/* msc cannot call the reply function pointer:
   .inbox/compiler/2026-10-16-function-into-c-function-pointer-emits-msclosure.md */
static void onClipboardWrite(GhosttyTerminal terminal, void* userdata, const GhosttyClipboardWrite* write) {
	(void)terminal;
	GhosttyClipboardWriteReply reply = { sizeof reply, GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED, false };
	if (write->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD && write->contents_len == 0) {
		haroVtClipboardWritten(userdata, (uint8_t*)"", 0);
		reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
	} else if (write->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD) {
		for (size_t i = 0; i < write->contents_len; i++) {
			const GhosttyClipboardContent* c = &write->contents[i];
			if (c->mime.len != 10 || memcmp(c->mime.ptr, "text/plain", 10) != 0) continue;
			haroVtClipboardWritten(userdata, (uint8_t*)c->data.ptr, (int64_t)c->data.len);
			reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
			break;
		}
	}
	write->reply(write, &reply);
}

static void onClipboardRead(GhosttyTerminal terminal, void* userdata, const GhosttyClipboardRead* read) {
	(void)terminal;
	GhosttyClipboardReadReply reply = { sizeof reply, GHOSTTY_CLIPBOARD_READ_RESULT_DENIED, NULL, 0, NULL, 0, false };
	int64_t mark = haroVtRepliesLength(userdata);
	read->reply(read, &reply);
	if (read->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD) haroVtClipboardRead(userdata, mark);
}

/* The callbacks are registered here because their addresses are C symbols. NULL effects clears them. */
int vtEffectsWire(GhosttyTerminal terminal, void* effects) {
	const struct { GhosttyTerminalOption option; const void* callback; } callbacks[] = {
		{ GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)writePty },
		{ GHOSTTY_TERMINAL_OPT_BELL, (const void*)haroVtBell },
		{ GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)haroVtTitleChanged },
		{ GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)haroVtPwdChanged },
		{ GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void*)haroVtRenderHold },
		{ GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void*)haroVtDeviceAttributes },
		{ GHOSTTY_TERMINAL_OPT_SIZE, (const void*)haroVtSize },
		{ GHOSTTY_TERMINAL_OPT_XTVERSION, (const void*)haroVtXtversion },
		{ GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, (const void*)haroVtDesktopNotification },
		{ GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, (const void*)onClipboardWrite },
		{ GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, (const void*)onClipboardRead },
	};
	int failed = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, effects) != GHOSTTY_SUCCESS;
	for (size_t i = 0; i < sizeof callbacks / sizeof callbacks[0]; i++) {
		const void* callback = effects ? callbacks[i].callback : NULL;
		failed |= ghostty_terminal_set(terminal, callbacks[i].option, callback) != GHOSTTY_SUCCESS;
	}
	return failed ? -1 : 0;
}
