// Can a tracked grid ref on the previous top viewport row tell how many lines scrolled?
@passC("-I../vendor/ghostty/include");
@passC("-DGHOSTTY_STATIC");
@include("./scrollRefShim.h");
@link("../out/ghostty/ghostty-vt-static.lib");

import {
	ghostty_terminal_new,
	ghostty_terminal_free,
	ghostty_tracked_grid_ref_has_value,
	ghostty_tracked_grid_ref_point,
	ghostty_tracked_grid_ref_free,
	ghostty_render_state_new,
	ghostty_render_state_update,
	ghostty_render_state_clean,
	ghostty_render_state_free,
	ghostty_render_state_row_iterator_new,
	ghostty_render_state_row_iterator_free,
	ghostty_render_state_row_iterator_next_dirty,
	GhosttyTerminal,
	GhosttyRenderState,
	GhosttyRenderStateRowIterator,
	GhosttyRenderStateData,
	GhosttyTrackedGridRef,
	GhosttyPointCoordinate,
	GhosttyPointTag,
	GhosttyTerminalScrollbar,
} from "../vendor/ghostty/include/ghostty/vt.h";

// msc passes a string to ghostty_terminal_vt_write wrongly; asBytes is right.
extern function writeBytes(t: GhosttyTerminal, b: Readonly<Span<uint8>>): void from "ghostty_terminal_vt_write";
extern function stateRowIterator(
	s: GhosttyRenderState,
	key: GhosttyRenderStateData,
	out it: GhosttyRenderStateRowIterator,
): int32 from "ghostty_render_state_get";
extern function setUsize(t: GhosttyTerminal, opt: int32, out v: uint64): int32 from "ghostty_terminal_set";
extern function getScrollbar(t: GhosttyTerminal, key: int32, out v: GhosttyTerminalScrollbar): int32 from "ghostty_terminal_get";
extern function srTrack(t: GhosttyTerminal, tag: int32, x: uint32, y: uint32, out ref: GhosttyTrackedGridRef): int32 from "sr_track";
extern function srSet(ref: GhosttyTrackedGridRef, t: GhosttyTerminal, tag: int32, x: uint32, y: uint32): int32 from "sr_set";

const VIEWPORT = GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT;
const SCREEN = GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN;
const HISTORY = GhosttyPointTag.GHOSTTY_POINT_TAG_HISTORY;
const ACTIVE = GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE;
const OPT_SCROLLBACK_MAX_LINES = 28;
const DATA_SCROLLBAR = 9;
const VIEWPORT_TAG = 1;

function write(term: GhosttyTerminal, s: string): void {
	writeBytes(term, s.asBytes());
}

function lines(from: int32, count: int32): string {
	let s = "";
	for (let i = 0; i < count; i++) {
		s = s + `\r\nrow ${from + i}`;
	}
	return s;
}

function pointAt(ref: GhosttyTrackedGridRef, tag: GhosttyPointTag): string {
	let c: GhosttyPointCoordinate;
	const r = ghostty_tracked_grid_ref_point(ref, tag, c);
	if ((r as int32) != 0) { return `r=${r as int32}`; }
	return `${c.y}`;
}

struct Rig {
	term: GhosttyTerminal;
	state: GhosttyRenderState;
	it: GhosttyRenderStateRowIterator;
	ref: GhosttyTrackedGridRef;
}

function open(cap: int32): Rig {
	let term: GhosttyTerminal;
	ghostty_terminal_new(null, term, 80, 24);
	if (cap >= 0) {
		let v: uint64 = cap as uint64;
		const sr = setUsize(term, OPT_SCROLLBACK_MAX_LINES, v);
		console.log(`  set scrollback max lines ${cap}: r=${sr}`);
	}
	let state: GhosttyRenderState;
	ghostty_render_state_new(null, state);
	let it: GhosttyRenderStateRowIterator;
	ghostty_render_state_row_iterator_new(null, it);
	write(term, "row 0" + lines(1, 23));
	let ref: GhosttyTrackedGridRef;
	srTrack(term, VIEWPORT_TAG, 0, 0, ref);
	return { term: term, state: state, it: it, ref: ref };
}

function close(rig: Rig): void {
	ghostty_tracked_grid_ref_free(rig.ref);
	ghostty_render_state_row_iterator_free(rig.it);
	ghostty_render_state_free(rig.state);
	ghostty_terminal_free(rig.term);
}

function frame(name: string, rig: Rig, expected: string): void {
	ghostty_render_state_update(rig.state, rig.term);
	let it = rig.it;
	stateRowIterator(rig.state, GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, it);
	let y: uint16 = 0;
	let n = 0;
	let list = "";
	while (ghostty_render_state_row_iterator_next_dirty(it, y)) {
		n = n + 1;
		if (n <= 26) { list = list + `${y} `; }
	}
	let sb: GhosttyTerminalScrollbar;
	getScrollbar(rig.term, DATA_SCROLLBAR, sb);
	let c: GhosttyPointCoordinate;
	const has = ghostty_tracked_grid_ref_has_value(rig.ref);
	const rs = ghostty_tracked_grid_ref_point(rig.ref, SCREEN, c);
	let measured = "LOST";
	if ((rs as int32) == 0) { measured = `${(sb.offset as int64) - (c.y as int64)}`; }
	console.log(`${name}: expected N=${expected} measured N=${measured} | has_value=${has} refPoint viewport=${pointAt(rig.ref, VIEWPORT)} active=${pointAt(rig.ref, ACTIVE)} screen=${pointAt(rig.ref, SCREEN)} history=${pointAt(rig.ref, HISTORY)} | scrollbar total=${sb.total} offset=${sb.offset} len=${sb.len} | dirty=${n} {${list}}`);
	ghostty_render_state_clean(rig.state);
	srSet(rig.ref, rig.term, VIEWPORT_TAG, 0, 0);
}

function scroll(name: string, k: int32, cap: int32): void {
	const rig = open(cap);
	frame(`${name} baseline`, rig, "0");
	write(rig.term, lines(24, k));
	frame(`${name} K=${k}`, rig, `${k}`);
	close(rig);
}

function others(): void {
	const rig = open(-1);
	frame("baseline", rig, "0");
	write(rig.term, "\x1b[6;1Hoverwrite");
	frame("overwrite row 5 (no scroll)", rig, "0");
	write(rig.term, "\x1b[2J\x1b[H");
	frame("clear screen 2J H", rig, "0");
	write(rig.term, "x" + lines(1, 23));
	frame("refill 24 rows (no scroll)", rig, "0");
	write(rig.term, lines(24, 7));
	frame("then 7 lines (K=7)", rig, "7");
	write(rig.term, "\x1b[?1049h");
	frame("alt screen enter", rig, "0?");
	write(rig.term, "alt" + lines(1, 30));
	frame("alt screen: 30 lines", rig, "0?");
	write(rig.term, "\x1b[?1049l");
	frame("alt screen leave", rig, "0");
	write(rig.term, lines(100, 5));
	frame("after leave + 5 lines", rig, "5");
	close(rig);
}

function main(): int32 {
	scroll("default", 1, -1);
	scroll("default", 3, -1);
	scroll("default", 24, -1);
	scroll("default", 100, -1);
	scroll("default", 5000, -1);
	scroll("cap10", 100, 10);
	scroll("cap0", 100, 0);
	scroll("cap10", 5000, 10);
	others();
	return 0;
}

process.exit(main());
