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


/* The colours a program's OSC 10/11 query is answered with while it has set none. */
int vtSetDefaultColors(GhosttyTerminal terminal, int fgR, int fgG, int fgB, int bgR, int bgG, int bgB) {
	GhosttyColorRgb fg = { (uint8_t)fgR, (uint8_t)fgG, (uint8_t)fgB };
	GhosttyColorRgb bg = { (uint8_t)bgR, (uint8_t)bgG, (uint8_t)bgB };
	if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg) != GHOSTTY_SUCCESS
		|| ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg) != GHOSTTY_SUCCESS) {
		return -1;
	}
	return 0;
}

/* The built-in palette with its first count/3 entries replaced by the rgb triples, as the colours a
   program's SGR 30-37, 90-97 and 38;5 indices name. */
int vtSetPalette(GhosttyTerminal terminal, const uint8_t* rgb, int64_t count) {
	if (count % 3 != 0 || count / 3 > 256) return -1;
	GhosttyColorRgb palette[256];
	if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, NULL) != GHOSTTY_SUCCESS
		|| ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, palette) != GHOSTTY_SUCCESS) {
		return -1;
	}
	for (int64_t i = 0; i < count / 3; i++) {
		palette[i].r = rgb[i * 3];
		palette[i].g = rgb[i * 3 + 1];
		palette[i].b = rgb[i * 3 + 2];
	}
	return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette) == GHOSTTY_SUCCESS ? 0 : -1;
}

int vtSetPullScrollback(GhosttyTerminal terminal, int pull) {
	bool on = pull != 0;
	return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK, &on) == GHOSTTY_SUCCESS ? 0 : -1;
}

/* The OSC 8 URI of the viewport cell at x, y: its length, 0 when the cell has none, -1 on error. A
   length above cap means nothing was copied. */
int64_t vtLinkAt(GhosttyTerminal terminal, int x, int y, uint8_t* buf, int64_t cap) {
	if (x < 0 || y < 0) return -1;
	GhosttyPoint at;
	memset(&at, 0, sizeof at);
	at.tag = GHOSTTY_POINT_TAG_VIEWPORT;
	at.value.coordinate.x = (uint16_t)x;
	at.value.coordinate.y = (uint32_t)y;
	GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
	if (ghostty_terminal_grid_ref(terminal, at, &ref) != GHOSTTY_SUCCESS) return -1;
	size_t len = 0;
	GhosttyResult r = ghostty_grid_ref_hyperlink_uri(&ref, buf, (size_t)cap, &len);
	if (r != GHOSTTY_SUCCESS && r != GHOSTTY_OUT_OF_SPACE) return -1;
	return (int64_t)len;
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

/* The cell's SGR 58 underline colour with a palette index resolved: 1 and rgb filled, or 0 when the
   cell has none (the text colour applies, generic.zig `underlineColor(...) orelse fg`). */
int vtUnderlineColor(GhosttyRenderState state, GhosttyRenderStateRowCells cells, uint8_t* rgb, int64_t cap) {
	if (cap < 3) return -1;
	GhosttyStyle style;
	ghostty_style_default(&style);
	style.size = sizeof style;
	if (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
		!= GHOSTTY_SUCCESS) {
		return -1;
	}
	if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) {
		rgb[0] = style.underline_color.value.rgb.r;
		rgb[1] = style.underline_color.value.rgb.g;
		rgb[2] = style.underline_color.value.rgb.b;
		return 1;
	}
	if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
		GhosttyColorRgb palette[256];
		if (ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, palette) != GHOSTTY_SUCCESS) {
			return -1;
		}
		GhosttyColorRgb c = palette[style.underline_color.value.palette];
		rgb[0] = c.r;
		rgb[1] = c.g;
		rgb[2] = c.b;
		return 1;
	}
	return 0;
}

/* Blinking is what a fresh terminal starts in and what DECSCUSR 0 returns to. The blink mode is not
   configurable as a reset default, so a full reset (RIS) goes back to a steady cursor. */
int vtSetBlinkDefault(GhosttyTerminal terminal, int on) {
	GhosttyTerminalModeConfig m;
	memset(&m, 0, sizeof m);
	m.mode = GHOSTTY_MODE_CURSOR_BLINKING;
	m.value = on != 0;
	bool blink = on != 0;
	if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &m) != GHOSTTY_SUCCESS) return -1;
	return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink) == GHOSTTY_SUCCESS ? 0 : -1;
}
