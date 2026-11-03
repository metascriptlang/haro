import { Axis, PaneId, cellRect } from "../../../../workspace/tree";
import {
	CommandKind,
	Tab,
	Workspace,
	WorkspaceCommand,
	activeTab,
	apply,
	create,
} from "../../../../workspace/workspace";
import {
	DividerLine,
	FrameLayout,
	Segment,
	currentAt,
	dragStep,
	frameOf,
	lineBox,
	paneBox,
	titleText,
} from "./frameLayout";

const COLS: int32 = 81;
const ROWS: int32 = 25;

function pane(n: int32): PaneId {
	return n as PaneId;
}

function must(w: Workspace, c: WorkspaceCommand): void {
	const result = w.apply(c, COLS, ROWS);
	if (!result.ok) {
		throw new Error(`refused: ${result.error.toString()}`);
	}
}

function opened(divider: int32): Workspace {
	const created = Workspace.create(divider);
	if (!created.ok) { throw new Error("divider refused"); }
	const w = created.value;
	must(w, { kind: CommandKind.NewTab });
	return w;
}

function split(w: Workspace, n: int32, axis: Axis): void {
	must(w, { kind: CommandKind.Split, pane: pane(n), axis: axis });
}

function focus(w: Workspace, n: int32): void {
	must(w, { kind: CommandKind.FocusPane, pane: pane(n) });
}

function tabOf(w: Workspace): Tab {
	const tab = w.activeTab();
	if (tab === null) { throw new Error("no tab"); }
	return tab;
}

function untitled(id: PaneId): string {
	return "";
}

function named(id: PaneId): string {
	return `p${id as int32}`;
}

function frame(w: Workspace): FrameLayout {
	return frameOf(tabOf(w), COLS, ROWS, w.dividerCells, untitled);
}

function repeated(glyph: string, count: int32): string {
	let out = "";
	for (let i: int32 = 0; i < count; i++) { out += glyph; }
	return out;
}

function seg(s: Segment): string {
	const focused = s.focused ? "*" : "";
	return `${s.x},${s.y}+${s.length}${focused}`;
}

function segs(f: FrameLayout): string {
	return f.segments.map((s: Segment): string => seg(s)).join(" ");
}

function lineAt(f: FrameLayout, axis: Axis, at: int32): DividerLine {
	for (const l of f.lines) {
		if (l.split.axis == axis && l.at == at) { return l; }
	}
	throw new Error(`no line at ${at}`);
}

function splitOnce(divider: int32, axis: Axis): Workspace {
	const w = opened(divider);
	split(w, 1, axis);
	return w;
}

function rowGlyphs(f: FrameLayout): string {
	let row = "";
	for (const s of f.segments) {
		if (s.axis == Axis.Stacked) { row += s.glyphs; }
	}
	return row;
}

function columnGlyphs(f: FrameLayout): string {
	let column = "";
	for (const s of f.segments) {
		if (s.axis == Axis.SideBySide) { column += s.glyphs; }
	}
	return column;
}

function grid(w: Workspace): Workspace {
	split(w, 1, Axis.SideBySide);
	focus(w, 1);
	split(w, 1, Axis.Stacked);
	focus(w, 2);
	split(w, 2, Axis.Stacked);
	return w;
}

test "one pane fills the tab with no dividers and no title" {
	for (const divider of [0, 1]) {
		const f = frameOf(tabOf(opened(divider)), COLS, ROWS, divider, named);
		assert f.panes.length == 1;
		assert f.panes[0].rect == cellRect(0, 0, COLS, ROWS);
		assert f.lines.length == 0 && f.segments.length == 0;
		assert f.titles.length == 0;
	}
}

test "a side-by-side split draws one column of vertical bars beside the focused pane" {
	const f = frame(splitOnce(1, Axis.SideBySide));
	assert f.lines.length == 1 && f.lines[0].at == 40;
	assert segs(f) == "40,0+25*";
	assert f.segments[0].glyphs == repeated("│", ROWS);
	assert !f.segments[0].joinsBefore && !f.segments[0].joinsAfter;
}

test "a stacked split draws one row of horizontal bars" {
	const f = frame(splitOnce(1, Axis.Stacked));
	assert f.lines.length == 1 && f.lines[0].at == 12;
	assert segs(f) == "0,12+81*";
	assert f.segments[0].glyphs == repeated("─", COLS);
}

test "without divider cells a split is a boundary line with no glyphs" {
	const across = frame(splitOnce(0, Axis.SideBySide));
	assert across.lines[0].at == 41;
	assert across.panes[1].rect == cellRect(41, 0, 40, ROWS);
	assert segs(across) == "41,0+25*";
	assert across.segments[0].glyphs == "";
	const down = frame(splitOnce(0, Axis.Stacked));
	assert segs(down) == "0,13+81*";
}

test "an L of three panes joins the stem with a tee and colours only the focused pane's borders" {
	const w = opened(1);
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	const f = frame(w);
	assert segs(f) == "40,0+12 40,12+13* 41,12+40*";
	assert f.segments[1].glyphs == "├" + repeated("│", 12);
	assert f.segments[2].glyphs == repeated("─", 40);
	assert f.segments[2].joinsBefore && !f.segments[2].joinsAfter;
	focus(w, 1);
	assert segs(frame(w)) == "40,0+25* 41,12+40";
}

test "an L of three panes without divider cells splits the line where the focus ends" {
	const w = opened(0);
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	const f = frame(w);
	assert segs(f) == "41,0+13 41,13+12* 41,13+40*";
	assert !f.segments[2].joinsBefore;
}

test "four panes in a grid cross at the middle" {
	const f = frame(grid(opened(1)));
	assert f.panes.length == 4;
	assert segs(f) == "40,0+12 40,12+13* 41,12+40* 0,12+40";
	assert f.segments[1].glyphs.charAt(0) == "┼";
	assert f.segments[2].joinsBefore && !f.segments[2].joinsAfter;
	assert f.segments[3].joinsAfter && !f.segments[3].joinsBefore;
}

test "the junction characters follow the cells around them" {
	const up = opened(1);
	split(up, 1, Axis.Stacked);
	focus(up, 1);
	split(up, 1, Axis.SideBySide);
	assert rowGlyphs(frame(up)).charAt(40) == "┴";
	assert columnGlyphs(frame(up)) == repeated("│", 12);
	const down = opened(1);
	split(down, 1, Axis.Stacked);
	split(down, 2, Axis.SideBySide);
	assert rowGlyphs(frame(down)).charAt(40) == "┬";
	const left = opened(1);
	split(left, 1, Axis.SideBySide);
	focus(left, 1);
	split(left, 1, Axis.Stacked);
	assert columnGlyphs(frame(left)).charAt(12) == "┤";
	assert rowGlyphs(frame(left)) == repeated("─", 40);
}

test "every divider names the last pane before it, the middle one of four columns too" {
	const w = opened(1);
	split(w, 1, Axis.SideBySide);
	focus(w, 1);
	split(w, 1, Axis.SideBySide);
	focus(w, 2);
	split(w, 2, Axis.SideBySide);
	const f = frame(w);
	assert f.lines.length == 3;
	assert lineAt(f, Axis.SideBySide, 40).before == pane(3);
	assert lineAt(f, Axis.SideBySide, 20).before == pane(1);
	assert lineAt(f, Axis.SideBySide, 61).before == pane(2);
	const stacked = opened(1);
	split(stacked, 1, Axis.Stacked);
	focus(stacked, 1);
	split(stacked, 1, Axis.SideBySide);
	const below = frame(stacked);
	assert lineAt(below, Axis.Stacked, 12).before == pane(3);
}

test "dragging a divider moves it by whole cells, negative toward the start" {
	const w = opened(1);
	split(w, 1, Axis.SideBySide);
	const l = frame(w).lines[0];
	assert l.dragStep(40.9, 1) == 0;
	const right = l.dragStep(43.2, 1);
	assert right == 3;
	must(w, {
		kind: CommandKind.MoveDivider,
		pane: l.before,
		axis: Axis.SideBySide,
		by: right,
	});
	assert l.currentAt(1) == 43;
	assert frame(w).lines[0].at == 43;
	assert l.dragStep(41.0, 1) == -2;
	assert frame(splitOnce(1, Axis.Stacked)).lines[0].dragStep(14.0, 1) == 2;
	assert frame(splitOnce(1, Axis.Stacked)).lines[0].dragStep(3.5, 1) == -9;
}

test "without divider cells a drag snaps to the nearest cell boundary" {
	const l = frame(splitOnce(0, Axis.SideBySide)).lines[0];
	assert l.dragStep(41.4, 0) == 0;
	assert l.dragStep(41.6, 0) == 1;
}

test "a title sits on the border row above its pane, clipped to the pane's width" {
	const w = opened(1);
	split(w, 1, Axis.Stacked);
	const f = frameOf(tabOf(w), COLS, ROWS, 1, named);
	assert f.titles.length == 1;
	const t = f.titles[0];
	assert t.pane == pane(2) && t.x == 0 && t.y == 12;
	assert t.text == " p2 " && t.focused;
	assert segs(f) == "4,12+77*";
	assert titleText("abcdefgh", 6) == " abcd…";
	assert titleText("ab", 4) == " ab ";
	assert titleText("", 10) == "";
	assert titleText("ab", 0) == "";
}

test "a pane on the top edge or without divider cells gets no title" {
	const w = opened(1);
	split(w, 1, Axis.SideBySide);
	assert frameOf(tabOf(w), COLS, ROWS, 1, named).titles.length == 0;
	const flat = splitOnce(0, Axis.Stacked);
	assert frameOf(tabOf(flat), COLS, ROWS, 0, named).titles.length == 0;
}

test "a zoomed pane fills the tab alone with no dividers" {
	const w = grid(opened(1));
	must(w, { kind: CommandKind.ToggleZoom });
	const f = frameOf(tabOf(w), COLS, ROWS, 1, named);
	assert f.panes.length == 1;
	assert f.panes[0].pane.id == pane(4);
	assert f.panes[0].rect == cellRect(0, 0, COLS, ROWS);
	assert f.segments.length == 0 && f.titles.length == 0;
}

test "a pixel gap shrinks only the sides that face another pane" {
	const box = paneBox(cellRect(41, 0, 40, 25), COLS, ROWS, 10, 20, 6);
	assert box.left == 413 && box.top == 0;
	assert box.width == 397 && box.height == 500;
	const whole = paneBox(cellRect(0, 0, COLS, ROWS), COLS, ROWS, 10, 20, 6);
	assert whole.left == 0 && whole.width == 810;
}

test "a thin line runs through the middle of its cells and reaches the line it joins" {
	const f = frame(grid(opened(1)));
	const box = lineBox(f.segments[3], 1, 10, 20, 1);
	assert box.left == 0 && box.width == 405;
	assert box.top == 249.5 && box.height == 1;
	const vertical = lineBox(f.segments[0], 1, 10, 20, 1);
	assert vertical.left == 404.5 && vertical.top == 0 && vertical.height == 240;
}
