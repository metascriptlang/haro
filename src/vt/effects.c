#include <stdlib.h>

#include "effects.h"

#ifdef __EMSCRIPTEN__
/* msc types a returned C pointer in a function-pointer field as non-null, so alloc cannot return NULL
   from .ms: compiler card 2026-10-28-a-header-function-pointer-field-returning-a-pointer-cannot-return-null */
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
#endif

/* The table stays in C because a .ms function reaches ghostty_terminal_set's const void* only through an
   unchecked cast, while here each callback is checked against its prototype in effects.h. NULL effects
   clears the callbacks. */
int vtEffectsWire(GhosttyTerminal terminal, void* effects) {
	const struct { GhosttyTerminalOption option; const void* callback; } callbacks[] = {
		{ GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)haroVtWritePty },
		{ GHOSTTY_TERMINAL_OPT_BELL, (const void*)haroVtBell },
		{ GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, (const void*)haroVtTitleChanged },
		{ GHOSTTY_TERMINAL_OPT_PWD_CHANGED, (const void*)haroVtPwdChanged },
		{ GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void*)haroVtRenderHold },
		{ GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void*)haroVtDeviceAttributes },
		{ GHOSTTY_TERMINAL_OPT_SIZE, (const void*)haroVtSize },
		{ GHOSTTY_TERMINAL_OPT_XTVERSION, (const void*)haroVtXtversion },
		{ GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, (const void*)haroVtDesktopNotification },
		{ GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, (const void*)haroVtClipboardWrite },
		{ GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, (const void*)haroVtClipboardRead },
	};
	int failed = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, effects) != GHOSTTY_SUCCESS;
	for (size_t i = 0; i < sizeof callbacks / sizeof callbacks[0]; i++) {
		const void* callback = effects ? callbacks[i].callback : NULL;
		failed |= ghostty_terminal_set(terminal, callbacks[i].option, callback) != GHOSTTY_SUCCESS;
	}
	return failed ? -1 : 0;
}
