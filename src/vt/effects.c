#include "effects.h"

/* The table stays in C because msc imports the write callback's const uint8_t* as a one-element borrow, so
   that callback cannot be bound to its typedef in .ms: compiler card 2026-10-28-readonly-ptr-does-not-emit-const-in-c.
   NULL effects clears the callbacks. */
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
		{ GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, (const void*)haroVtSemanticPrompt },
	};
	int failed = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, effects) != GHOSTTY_SUCCESS;
	for (size_t i = 0; i < sizeof callbacks / sizeof callbacks[0]; i++) {
		const void* callback = effects ? callbacks[i].callback : NULL;
		failed |= ghostty_terminal_set(terminal, callbacks[i].option, callback) != GHOSTTY_SUCCESS;
	}
	return failed ? -1 : 0;
}
