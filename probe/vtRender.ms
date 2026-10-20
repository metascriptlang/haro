@passC("-I../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@link("../out/ghostty/ghostty-vt-static.lib");

import {
	ghostty_terminal_new,
	ghostty_terminal_vt_write,
	ghostty_terminal_free,
	ghostty_render_state_new,
	ghostty_render_state_update,
	ghostty_render_state_get,
	ghostty_render_state_free,
	ghostty_render_state_row_iterator_new,
	ghostty_render_state_row_iterator_next_dirty,
	GhosttyTerminal,
	GhosttyRenderState,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateData,
} from "../vendor/ghostty/include/ghostty/vt.h";

extern function stateRowIterator(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out it: GhosttyRenderStateRowIterator,
): int32 from "ghostty_render_state_get";

function main(): int32 {
	let term: GhosttyTerminal;
	ghostty_terminal_new(null, term, 80, 24);
	const text = "hello\r\n";
	ghostty_terminal_vt_write(term, text, text.length);
	let state: GhosttyRenderState;
	ghostty_render_state_new(null, state);
	ghostty_render_state_update(state, term);
	let cols: uint16 = 0;
	const colsKey = GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLS;
	const r = ghostty_render_state_get(state, colsKey, cols);
	console.log(`get cols: ${r as int32} ${cols}`);
	let rows: GhosttyRenderStateRowIterator;
	ghostty_render_state_row_iterator_new(null, rows);
	stateRowIterator(state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, rows);
	let y: uint16 = 0;
	const dirty = ghostty_render_state_row_iterator_next_dirty(rows, y);
	console.log(`dirty ${dirty} y=${y}`);
	ghostty_render_state_free(state);
	ghostty_terminal_free(term);
	return 0;
}

process.exit(main());
