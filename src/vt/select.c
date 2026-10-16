#include <stdlib.h>
#include <string.h>

#include "select.h"

/* msc cannot import GhosttyPoint or the scroll union: .inbox/compiler/2026-10-15-c-import-fixed-array-member-sizedarray.md */

static GhosttyPoint screenPoint(int x, int y) {
	GhosttyPoint p;
	memset(&p, 0, sizeof p);
	p.tag = GHOSTTY_POINT_TAG_SCREEN;
	p.value.coordinate.x = (uint16_t)x;
	p.value.coordinate.y = (uint32_t)y;
	return p;
}

static GhosttyResult refAt(GhosttyTerminal terminal, int x, int y, GhosttyGridRef* ref) {
	if (x < 0 || y < 0) return GHOSTTY_INVALID_VALUE;
	*ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
	return ghostty_terminal_grid_ref(terminal, screenPoint(x, y), ref);
}

static int coordOf(GhosttyTerminal terminal, const GhosttyGridRef* ref, int32_t* out) {
	GhosttyPointCoordinate c;
	GhosttyResult r = ghostty_terminal_point_from_grid_ref(terminal, ref, GHOSTTY_POINT_TAG_SCREEN, &c);
	if (r != GHOSTTY_SUCCESS) return -1;
	out[0] = (int32_t)c.x;
	out[1] = (int32_t)c.y;
	return 0;
}

static int rangeOut(GhosttyTerminal terminal, const GhosttySelection* sel, int32_t* out, int64_t cap) {
	GhosttySelection ordered = GHOSTTY_INIT_SIZED(GhosttySelection);
	if (cap < 5) return -2;
	if (ghostty_terminal_selection_ordered(terminal, sel, GHOSTTY_SELECTION_ORDER_FORWARD, &ordered)
		!= GHOSTTY_SUCCESS) return -1;
	if (coordOf(terminal, &ordered.start, out) != 0) return -1;
	if (coordOf(terminal, &ordered.end, out + 2) != 0) return -1;
	out[4] = sel->rectangle ? 1 : 0;
	return 0;
}

void vtScroll(GhosttyTerminal terminal, int tag, int64_t amount) {
	GhosttyTerminalScrollViewport v;
	memset(&v, 0, sizeof v);
	v.tag = (GhosttyTerminalScrollViewportTag)tag;
	if (tag == GHOSTTY_SCROLL_VIEWPORT_DELTA) v.value.delta = (intptr_t)amount;
	if (tag == GHOSTTY_SCROLL_VIEWPORT_ROW) v.value.row = (size_t)amount;
	ghostty_terminal_scroll_viewport(terminal, v);
}

/* Scroll the viewport so the nearest prompt (OSC 133 A) above (delta < 0) or below (delta > 0) its top
   row is the top row, as Surface.zig `jump_to_prompt` does. 1: scrolled, 0: no such prompt, -1: error. */
int vtPromptJump(GhosttyTerminal terminal, int delta) {
	GhosttyTerminalScrollbar bar;
	memset(&bar, 0, sizeof bar);
	if (delta == 0 || ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) != GHOSTTY_SUCCESS) return -1;
	int64_t step = delta < 0 ? -1 : 1;
	int64_t last = (int64_t)bar.total - 1;
	for (int64_t y = (int64_t)bar.offset + step; y >= 0 && y <= last; y += step) {
		GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
		if (ghostty_terminal_grid_ref(terminal, screenPoint(0, (int)y), &ref) != GHOSTTY_SUCCESS) return -1;
		GhosttyRow row = 0;
		GhosttyRowSemanticPrompt prompt = GHOSTTY_ROW_SEMANTIC_NONE;
		if (ghostty_grid_ref_row(&ref, &row) != GHOSTTY_SUCCESS
			|| ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt) != GHOSTTY_SUCCESS) {
			return -1;
		}
		if (prompt != GHOSTTY_ROW_SEMANTIC_PROMPT) continue;
		vtScroll(terminal, GHOSTTY_SCROLL_VIEWPORT_ROW, y);
		return 1;
	}
	return 0;
}

int vtSelSet(GhosttyTerminal terminal, int sx, int sy, int ex, int ey, int rectangle) {
	GhosttySelection sel = GHOSTTY_INIT_SIZED(GhosttySelection);
	if (refAt(terminal, sx, sy, &sel.start) != GHOSTTY_SUCCESS) return -1;
	if (refAt(terminal, ex, ey, &sel.end) != GHOSTTY_SUCCESS) return -1;
	sel.rectangle = rectangle != 0;
	return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS ? 0 : -1;
}

void vtSelClear(GhosttyTerminal terminal) {
	ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
}

/* 0 and out = x0, y0, x1, y1, rectangle; 1 when the terminal holds no selection. */
int vtSelGet(GhosttyTerminal terminal, int32_t* out, int64_t cap) {
	GhosttySelection sel = GHOSTTY_INIT_SIZED(GhosttySelection);
	GhosttyResult r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &sel);
	if (r == GHOSTTY_NO_VALUE) return 1;
	if (r != GHOSTTY_SUCCESS) return -1;
	return rangeOut(terminal, &sel, out, cap);
}

int vtSelWord(GhosttyTerminal terminal, int x, int y, int32_t* out, int64_t cap) {
	GhosttyTerminalSelectWordOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
	GhosttySelection sel = GHOSTTY_INIT_SIZED(GhosttySelection);
	if (refAt(terminal, x, y, &o.ref) != GHOSTTY_SUCCESS) return -1;
	GhosttyResult r = ghostty_terminal_select_word(terminal, &o, &sel);
	if (r == GHOSTTY_NO_VALUE) return 1;
	if (r != GHOSTTY_SUCCESS) return -1;
	return rangeOut(terminal, &sel, out, cap);
}

int vtSelLine(GhosttyTerminal terminal, int x, int y, int32_t* out, int64_t cap) {
	GhosttyTerminalSelectLineOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
	GhosttySelection sel = GHOSTTY_INIT_SIZED(GhosttySelection);
	if (refAt(terminal, x, y, &o.ref) != GHOSTTY_SUCCESS) return -1;
	o.semantic_prompt_boundary = true;
	GhosttyResult r = ghostty_terminal_select_line(terminal, &o, &sel);
	if (r == GHOSTTY_NO_VALUE) return 1;
	if (r != GHOSTTY_SUCCESS) return -1;
	return rangeOut(terminal, &sel, out, cap);
}

/* The active selection as plain text, the way Ghostty's Screen.selectionString copies it
   (unwrap and trim). Returns the byte length; above cap, nothing was written and the
   length is the capacity to retry with. -1 when there is no selection. */
int64_t vtSelText(GhosttyTerminal terminal, uint8_t* buf, int64_t cap) {
	GhosttyTerminalSelectionFormatOptions o = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
	o.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	o.unwrap = true;
	o.trim = true;
	o.selection = NULL;
	size_t written = 0;
	GhosttyResult r = ghostty_terminal_selection_format_buf(terminal, o, buf, (size_t)cap, &written);
	if (r == GHOSTTY_SUCCESS || r == GHOSTTY_OUT_OF_SPACE) return (int64_t)written;
	return -1;
}

static int bracketed(GhosttyTerminal terminal) {
	GhosttyTerminalModeConfig m;
	memset(&m, 0, sizeof m);
	m.mode = GHOSTTY_MODE_BRACKETED_PASTE;
	if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &m) != GHOSTTY_SUCCESS) return 0;
	return m.value ? 1 : 0;
}

/* Surface.zig completeClipboardPaste with its defaults: bracketed, the data is unsafe only when it
   holds the end marker; unbracketed, it is unsafe when it holds a newline. Returns the bytes written
   to out (len + 16 is always enough), -1 when the paste is unsafe and allowUnsafe is 0. */
int64_t vtPasteEncode(GhosttyTerminal terminal, const uint8_t* data, int64_t len,
	int allowUnsafe, uint8_t* out, int64_t cap) {
	static const char endMarker[] = "\x1b[201~";
	int br = bracketed(terminal);
	int unsafe;
	if (br) {
		unsafe = 0;
		for (int64_t i = 0; i + 6 <= len; i++) {
			if (memcmp(data + i, endMarker, 6) == 0) { unsafe = 1; break; }
		}
	} else {
		unsafe = !ghostty_paste_is_safe((const char*)data, (size_t)len);
	}
	if (unsafe && !allowUnsafe) return -1;
	char* copy = malloc(len > 0 ? (size_t)len : 1);
	if (!copy) return -3;
	if (len > 0) memcpy(copy, data, (size_t)len);
	size_t written = 0;
	GhosttyResult r = ghostty_paste_encode(copy, (size_t)len, br != 0, (char*)out, (size_t)cap, &written);
	free(copy);
	if (r == GHOSTTY_SUCCESS) return (int64_t)written;
	return r == GHOSTTY_OUT_OF_SPACE ? -2 : -3;
}
