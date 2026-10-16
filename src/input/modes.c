#include <stdbool.h>

#include "modes.h"

int inputMouseModes(GhosttyTerminal terminal) {
	int bits = 0;
	bool tracking = false;
	if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) != GHOSTTY_SUCCESS) return -1;
	if (tracking) bits |= INPUT_MOUSE_TRACKING;
	GhosttyTerminalModeConfig scroll;
	scroll.mode = GHOSTTY_MODE_ALT_SCROLL;
	scroll.value = false;
	if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &scroll) != GHOSTTY_SUCCESS) return -1;
	if (scroll.value) bits |= INPUT_ALT_SCROLL;
	return bits;
}
