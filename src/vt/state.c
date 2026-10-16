#include <string.h>

#include "state.h"

/* The bytes of the title (which 0) or the pwd (which 1) the terminal holds. A length above cap means
   nothing was copied. */
int64_t vtString(GhosttyTerminal terminal, int which, uint8_t* buf, int64_t cap) {
	GhosttyTerminalData key = which == 0 ? GHOSTTY_TERMINAL_DATA_TITLE : GHOSTTY_TERMINAL_DATA_PWD;
	GhosttyString s;
	memset(&s, 0, sizeof s);
	if (ghostty_terminal_get(terminal, key, &s) != GHOSTTY_SUCCESS) return -1;
	if ((int64_t)s.len <= cap) memcpy(buf, s.ptr, s.len);
	return (int64_t)s.len;
}

