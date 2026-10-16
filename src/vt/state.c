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


/* out: visible (DECTCEM), shape (GhosttyRenderStateCursorVisualStyle), blinking. Reads the render
   state, so it describes the frame the last update captured. */
int vtCursorLook(GhosttyRenderState state, int32_t* out, int64_t cap) {
	if (cap < 3) return -1;
	bool visible = false;
	bool blinking = false;
	GhosttyRenderStateCursorVisualStyle style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
	if (ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible) != GHOSTTY_SUCCESS
		|| ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style) != GHOSTTY_SUCCESS
		|| ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking) != GHOSTTY_SUCCESS) {
		return -1;
	}
	out[0] = visible ? 1 : 0;
	out[1] = (int32_t)style;
	out[2] = blinking ? 1 : 0;
	return 0;
}

static int modeOn(GhosttyTerminal terminal, GhosttyMode mode) {
	GhosttyTerminalModeConfig m;
	memset(&m, 0, sizeof m);
	m.mode = mode;
	if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &m) != GHOSTTY_SUCCESS) return -1;
	return m.value ? 1 : 0;
}

/* out: focus events (1004), bracketed paste (2004), alternate scroll (1007), application cursor
   keys (DECCKM), any mouse tracking mode. */
int vtModes(GhosttyTerminal terminal, int32_t* out, int64_t cap) {
	if (cap < 5) return -1;
	bool tracking = false;
	if ((out[0] = modeOn(terminal, GHOSTTY_MODE_FOCUS_EVENT)) < 0
		|| (out[1] = modeOn(terminal, GHOSTTY_MODE_BRACKETED_PASTE)) < 0
		|| (out[2] = modeOn(terminal, GHOSTTY_MODE_ALT_SCROLL)) < 0
		|| (out[3] = modeOn(terminal, GHOSTTY_MODE_DECCKM)) < 0
		|| ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) != GHOSTTY_SUCCESS) {
		return -1;
	}
	out[4] = tracking ? 1 : 0;
	return 0;
}

/* Which mouse modes are on, as bits: changes exactly when the encoder's options would. */
int vtMouseSignature(GhosttyTerminal terminal) {
	static const uint16_t numbers[] = { 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016 };
	int sig = 0;
	for (int i = 0; i < 8; i++) {
		int on = modeOn(terminal, ghostty_mode_new(numbers[i], false));
		if (on < 0) return -1;
		sig |= on << i;
	}
	bool tracking = false;
	if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) != GHOSTTY_SUCCESS) return -1;
	return sig | ((tracking ? 1 : 0) << 8);
}

/* The report for a focus change: 0 bytes when the program has not asked for focus events. */
int64_t vtFocusEncode(GhosttyTerminal terminal, int gained, uint8_t* buf, int64_t cap) {
	int on = modeOn(terminal, GHOSTTY_MODE_FOCUS_EVENT);
	if (on < 0) return -1;
	if (!on) return 0;
	size_t written = 0;
	GhosttyResult r = ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
		(char*)buf, (size_t)cap, &written);
	return r == GHOSTTY_SUCCESS ? (int64_t)written : -2;
}

/* All codepoints of the cell's grapheme, base first, as many as the cell holds: buf must hold the
   count GRAPHEMES_LEN reports. Returns the count, or -1. */
int64_t vtGraphemes(GhosttyRenderStateRowCells cells, uint32_t* buf, int64_t cap) {
	uint32_t count = 0;
	if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &count)
		!= GHOSTTY_SUCCESS || (int64_t)count > cap) {
		return -1;
	}
	if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf)
		!= GHOSTTY_SUCCESS) {
		return -1;
	}
	return (int64_t)count;
}
