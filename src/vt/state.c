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
