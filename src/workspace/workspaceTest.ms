import {
	Axis,
	CellRect,
	MIN_PANE_CELLS,
	PaneId,
	TabId,
	cellRect,
} from "./tree";
import {
	CommandKind,
	DEFAULT_DIVIDER_CELLS,
	Direction,
	EventKind,
	Tab,
	Workspace,
	WorkspaceCommand,
	WorkspaceError,
	WorkspaceEvent,
	apply,
	create,
	focusedPane,
	layout,
	tabWith,
} from "./workspace";

// msc card 2026-11-04-literal-into-nullable-variant-field-dies-at-clang:
// a string literal in a command's title field fails in the C compiler.
const LOGS: string | null = "logs";

const COLS: int32 = 81;
const ROWS: int32 = 25;

function pane(n: int32): PaneId {
	return n as PaneId;
}

function tab(n: int32): TabId {
	return n as TabId;
}

function must(w: Workspace, c: WorkspaceCommand): WorkspaceEvent[] {
	const result = w.apply(c, COLS, ROWS);
	if (!result.ok) {
		throw new Error(`refused: ${result.error.toString()}`);
	}
	return result.value;
}

function refusal(w: Workspace, c: WorkspaceCommand): WorkspaceError | null {
	const result = w.apply(c, COLS, ROWS);
	return result.ok ? null : result.error;
}

function opened(): Workspace {
	const created = Workspace.create(DEFAULT_DIVIDER_CELLS);
	if (!created.ok) { throw new Error("divider refused"); }
	const w = created.value;
	must(w, { kind: CommandKind.NewTab });
	return w;
}

function split(w: Workspace, n: int32, axis: Axis): WorkspaceEvent[] {
	return must(w, { kind: CommandKind.Split, pane: pane(n), axis: axis });
}

function close(w: Workspace, n: int32): WorkspaceEvent[] {
	return must(w, { kind: CommandKind.ClosePane, pane: pane(n) });
}

function focus(w: Workspace, n: int32): void {
	must(w, { kind: CommandKind.FocusPane, pane: pane(n) });
}

function toward(w: Workspace, d: Direction): WorkspaceEvent[] {
	return must(w, { kind: CommandKind.FocusDirection, direction: d });
}

function resize(w: Workspace, d: Direction, cells: int32): WorkspaceEvent[] {
	return must(w, { kind: CommandKind.Resize, direction: d, cells: cells });
}

function focused(w: Workspace): int32 {
	const id = w.focusedPane();
	return id === null ? -1 : id as int32;
}

function rectOf(w: Workspace, n: int32): CellRect {
	const active = w.active;
	if (active === null) { return cellRect(-1, -1, -1, -1); }
	const t = w.tabWith(active);
	if (t === null) { return cellRect(-1, -1, -1, -1); }
	for (const p of t.layout(COLS, ROWS, w.dividerCells)) {
		if (p.pane.id == pane(n)) { return p.rect; }
	}
	return cellRect(-1, -1, -1, -1);
}

function kinds(events: WorkspaceEvent[]): string {
	return events.map((e: WorkspaceEvent): string => e.kind.toString()).join(",");
}

function tabOrder(w: Workspace): string {
	return w.tabs.map((t: Tab): string => String(t.id as int32)).join(",");
}

test "a new tab opens one pane over the whole tab and focuses it" {
	const w = Workspace.create(1);
	assert w.ok;
	if (w.ok) {
		const events = must(w.value, { kind: CommandKind.NewTab });
		assert kinds(events) == "TabsChanged,PaneOpened,FocusChanged";
		const e = events[1];
		if (e.kind == EventKind.PaneOpened) {
			assert e.pane == pane(1) && e.tab == tab(1);
			assert e.origin === null;
			assert e.rect == cellRect(0, 0, COLS, ROWS);
		}
	}
}

test "a side-by-side split halves the pane, opens the new one on the right and focuses it" {
	const w = opened();
	const events = split(w, 1, Axis.SideBySide);
	assert kinds(events) == "PaneOpened,PaneResized,FocusChanged";
	const e = events[0];
	if (e.kind == EventKind.PaneOpened) {
		assert e.pane == pane(2);
		assert e.origin !== null && e.origin == pane(1);
		assert e.rect == cellRect(41, 0, 40, ROWS);
	}
	const r = events[1];
	if (r.kind == EventKind.PaneResized) {
		assert r.pane == pane(1) && r.rect == cellRect(0, 0, 40, ROWS);
	}
	assert focused(w) == 2;
}

test "a stacked split opens the new pane below" {
	const w = opened();
	split(w, 1, Axis.Stacked);
	assert rectOf(w, 1) == cellRect(0, 0, COLS, 12);
	assert rectOf(w, 2) == cellRect(0, 13, COLS, 12);
	assert focused(w) == 2;
}

test "closing a pane two levels down gives its place to its sibling" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	split(w, 3, Axis.SideBySide);
	const bottomRight = rectOf(w, 3);
	const events = close(w, 4);
	assert kinds(events) == "PaneClosed,PaneResized,FocusChanged";
	assert rectOf(w, 3) == cellRect(41, 13, 40, 12);
	assert bottomRight.cols == 20;
	assert focused(w) == 3;
}

test "closing the focused pane focuses the pane it was split from" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	focus(w, 1);
	focus(w, 3);
	close(w, 3);
	assert focused(w) == 2;
}

test "closing a focused pane whose source is gone focuses the nearest pane" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	split(w, 3, Axis.SideBySide);
	close(w, 3);
	assert focused(w) == 4;
	assert rectOf(w, 4) == cellRect(41, 13, 40, 12);
	close(w, 4);
	assert focused(w) == 2;
}

test "closing a pane that is not focused keeps the focus" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	const events = close(w, 1);
	assert kinds(events) == "PaneClosed,PaneResized";
	assert focused(w) == 2;
}

test "closing the last pane closes its tab and the last tab empties the workspace" {
	const w = opened();
	must(w, { kind: CommandKind.NewTab });
	const first = close(w, 2);
	assert kinds(first) == "PaneClosed,TabsChanged,FocusChanged";
	assert w.tabs.length == 1;
	const last = close(w, 1);
	assert kinds(last) == "PaneClosed,TabsChanged,WorkspaceEmpty";
	const e = last[1];
	if (e.kind == EventKind.TabsChanged) {
		assert e.tabs.length == 0 && e.active === null;
	}
	assert w.focusedPane() === null;
}

test "focus by direction in an L-shaped layout picks the touching pane, ties by recency" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	focus(w, 2);
	toward(w, Direction.Left);
	assert focused(w) == 1;
	toward(w, Direction.Right);
	assert focused(w) == 2;
	toward(w, Direction.Down);
	assert focused(w) == 3;
	toward(w, Direction.Left);
	assert focused(w) == 1;
	toward(w, Direction.Right);
	assert focused(w) == 3;
	assert toward(w, Direction.Right).length == 0;
	focus(w, 1);
	assert toward(w, Direction.Up).length == 0;
}

test "focus by direction prefers the pane overlapping most along the other axis" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.Stacked);
	resize(w, Direction.Down, 6);
	focus(w, 3);
	focus(w, 1);
	toward(w, Direction.Right);
	assert focused(w) == 2;
}

test "previous and next pane follow tree order and wrap" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 1, Axis.Stacked);
	assert focused(w) == 3;
	must(w, { kind: CommandKind.CyclePane, by: 1 });
	assert focused(w) == 2;
	must(w, { kind: CommandKind.CyclePane, by: 1 });
	assert focused(w) == 1;
	must(w, { kind: CommandKind.CyclePane, by: -1 });
	assert focused(w) == 2;
}

test "a resize moves the nearest divider on its axis by whole cells and clamps at the minimum" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	const events = resize(w, Direction.Right, 5);
	assert kinds(events) == "PaneResized,PaneResized";
	assert rectOf(w, 1).cols == 45 && rectOf(w, 2).cols == 35;
	resize(w, Direction.Left, 1000);
	assert rectOf(w, 1).cols == MIN_PANE_CELLS;
	assert rectOf(w, 2).cols == COLS - 1 - MIN_PANE_CELLS;
	resize(w, Direction.Right, 1000);
	assert rectOf(w, 2).cols == MIN_PANE_CELLS;
	assert resize(w, Direction.Right, 1).length == 0;
	assert resize(w, Direction.Up, 3).length == 0;
}

test "a resize keeps every pane of a nested subtree at its minimum" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.SideBySide);
	focus(w, 1);
	resize(w, Direction.Right, 1000);
	assert rectOf(w, 2).cols == MIN_PANE_CELLS;
	assert rectOf(w, 3).cols == MIN_PANE_CELLS;
	assert rectOf(w, 1).cols == COLS - 2 - 2 * MIN_PANE_CELLS;
}

test "a resize moves the divider nearest to the focused pane" {
	const w = opened();
	split(w, 1, Axis.Stacked);
	split(w, 2, Axis.Stacked);
	resize(w, Direction.Up, 2);
	assert rectOf(w, 1).rows == 12;
	assert rectOf(w, 2).rows == 4;
	assert rectOf(w, 3).rows == 7;
}

function divider(n: int32, axis: Axis, by: int32): WorkspaceCommand {
	return { kind: CommandKind.MoveDivider, pane: pane(n), axis: axis, by: by };
}

function moved(w: Workspace, n: int32, axis: Axis, by: int32): WorkspaceEvent[] {
	return must(w, divider(n, axis, by));
}

test "moving a divider names it by the pane before it, so a middle divider is reachable" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	focus(w, 1);
	split(w, 1, Axis.SideBySide);
	focus(w, 2);
	split(w, 2, Axis.SideBySide);
	focus(w, 1);
	assert rectOf(w, 3).x + rectOf(w, 3).cols == 40;
	const events = moved(w, 3, Axis.SideBySide, 4);
	assert kinds(events) == "PaneResized,PaneResized,PaneResized,PaneResized";
	assert rectOf(w, 3).x + rectOf(w, 3).cols == 44;
	assert rectOf(w, 2).x == 45;
	assert focused(w) == 1;
	moved(w, 1, Axis.SideBySide, -3);
	assert rectOf(w, 1).cols == 19;
	assert rectOf(w, 3).x + rectOf(w, 3).cols == 44;
	moved(w, 3, Axis.SideBySide, -1000);
	assert rectOf(w, 1).cols == MIN_PANE_CELLS;
	assert rectOf(w, 3).cols == MIN_PANE_CELLS;
	assert focused(w) == 1;
}

test "moving a divider leaves zoom and refuses a pane with no divider after it" {
	const w = opened();
	split(w, 1, Axis.Stacked);
	must(w, { kind: CommandKind.ToggleZoom });
	const events = moved(w, 1, Axis.Stacked, 2);
	assert kinds(events) == "PaneResized,PaneResized,ZoomChanged";
	assert rectOf(w, 1).rows == 14;
	assert refusal(w, divider(2, Axis.Stacked, 1)) == WorkspaceError.NoDivider;
	assert refusal(w, divider(1, Axis.SideBySide, 1)) == WorkspaceError.NoDivider;
	assert refusal(w, divider(1, Axis.Stacked, 0)) ==
		WorkspaceError.CellsOutOfRange;
	assert refusal(w, divider(9, Axis.Stacked, 1)) == WorkspaceError.UnknownPane;
	assert rectOf(w, 1).rows == 14;
}

test "zoom fills the tab with the focused pane until toggled off" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	const on = must(w, { kind: CommandKind.ToggleZoom });
	assert kinds(on) == "PaneResized,ZoomChanged";
	assert rectOf(w, 2) == cellRect(0, 0, COLS, ROWS);
	assert rectOf(w, 1).cols == 40;
	const off = must(w, { kind: CommandKind.ToggleZoom });
	assert kinds(off) == "PaneResized,ZoomChanged";
	assert rectOf(w, 2) == cellRect(41, 0, 40, ROWS);
}

test "a split or a focus move by direction leaves zoom" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	must(w, { kind: CommandKind.ToggleZoom });
	const moved = toward(w, Direction.Left);
	assert kinds(moved) == "PaneResized,ZoomChanged,FocusChanged";
	assert focused(w) == 1;
	must(w, { kind: CommandKind.ToggleZoom });
	const events = split(w, 1, Axis.Stacked);
	assert kinds(events) == "PaneOpened,PaneResized,ZoomChanged,FocusChanged";
	const z = events[2];
	if (z.kind == EventKind.ZoomChanged) { assert z.pane === null; }
}

test "zoom on a lone pane changes nothing" {
	const w = opened();
	assert must(w, { kind: CommandKind.ToggleZoom }).length == 0;
}

test "a window resize lays every pane out again and sums exactly at odd sizes" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	split(w, 2, Axis.SideBySide);
	split(w, 3, Axis.Stacked);
	const sized = w.apply({ kind: CommandKind.Fit }, 77, 23);
	assert sized.ok;
	if (sized.ok) { assert sized.value.length == 4; }
	const active = w.active;
	if (active !== null) {
		const t = w.tabWith(active);
		if (t !== null) {
			const placed = t.layout(77, 23, w.dividerCells);
			assert placed[0].rect.cols + 1 + placed[1].rect.cols + 1 +
				placed[2].rect.cols == 77;
			assert placed[2].rect.rows + 1 + placed[3].rect.rows == 23;
			assert placed[2].rect.cols == placed[3].rect.cols;
		}
	}
	const again = w.apply({ kind: CommandKind.Fit }, 77, 23);
	if (again.ok) { assert again.value.length == 0; }
}

test "a new tab goes last and takes focus; goto, cycle and move wrap" {
	const w = opened();
	must(w, { kind: CommandKind.NewTab });
	must(w, { kind: CommandKind.NewTab });
	assert tabOrder(w) == "1,2,3";
	assert focused(w) == 3;
	must(w, { kind: CommandKind.GotoTab, index: 0 });
	assert focused(w) == 1;
	must(w, { kind: CommandKind.CycleTab, by: -1 });
	assert focused(w) == 3;
	must(w, { kind: CommandKind.CycleTab, by: 1 });
	assert focused(w) == 1;
	must(w, { kind: CommandKind.MoveTab, by: 1 });
	assert tabOrder(w) == "2,1,3";
	must(w, { kind: CommandKind.MoveTab, by: -2 });
	assert tabOrder(w) == "2,3,1";
	must(w, { kind: CommandKind.MoveTab, by: 1 });
	assert tabOrder(w) == "1,2,3";
}

test "closing the active tab activates the tab that takes its place" {
	const w = opened();
	must(w, { kind: CommandKind.NewTab });
	must(w, { kind: CommandKind.NewTab });
	must(w, { kind: CommandKind.GotoTab, index: 1 });
	const events = must(w, { kind: CommandKind.CloseTab, tab: tab(2) });
	assert kinds(events) == "PaneClosed,TabsChanged,FocusChanged";
	assert focused(w) == 3;
	must(w, { kind: CommandKind.CloseTab, tab: tab(3) });
	assert focused(w) == 1;
}

test "a rename sets the title and null clears it" {
	const w = opened();
	const named = must(w, {
		kind: CommandKind.RenameTab,
		tab: tab(1),
		title: LOGS,
	});
	assert kinds(named) == "TabsChanged";
	const e = named[0];
	if (e.kind == EventKind.TabsChanged) { assert e.tabs[0].title == "logs"; }
	must(w, { kind: CommandKind.RenameTab, tab: tab(1), title: null });
	assert w.tabs[0].title === null;
}

test "unknown ids, missing tabs and impossible sizes are refused and change nothing" {
	const w = opened();
	split(w, 1, Axis.SideBySide);
	const bad = pane(99);
	const splitBad: WorkspaceCommand = {
		kind: CommandKind.Split,
		pane: bad,
		axis: Axis.Stacked,
	};
	assert refusal(w, splitBad) == WorkspaceError.UnknownPane;
	assert refusal(w, { kind: CommandKind.ClosePane, pane: bad }) ==
		WorkspaceError.UnknownPane;
	assert refusal(w, { kind: CommandKind.FocusPane, pane: bad }) ==
		WorkspaceError.UnknownPane;
	assert refusal(w, { kind: CommandKind.CloseTab, tab: tab(9) }) ==
		WorkspaceError.UnknownTab;
	const renameBad: WorkspaceCommand = {
		kind: CommandKind.RenameTab,
		tab: tab(9),
		title: LOGS,
	};
	assert refusal(w, renameBad) == WorkspaceError.UnknownTab;
	assert refusal(w, { kind: CommandKind.GotoTab, index: 1 }) ==
		WorkspaceError.NoTabAtIndex;
	const still: WorkspaceCommand = {
		kind: CommandKind.Resize,
		direction: Direction.Left,
		cells: 0,
	};
	assert refusal(w, still) == WorkspaceError.CellsOutOfRange;
	const tiny = w.apply({ kind: CommandKind.Fit }, 0, ROWS);
	assert !tiny.ok && tiny.error == WorkspaceError.SizeOutOfRange;
	assert must(w, { kind: CommandKind.Fit }).length == 0;
	assert focused(w) == 2;
	assert !Workspace.create(-1).ok;
}

test "a pane too narrow to halve refuses the split" {
	const w = opened();
	const halve: WorkspaceCommand = {
		kind: CommandKind.Split,
		pane: pane(1),
		axis: Axis.SideBySide,
	};
	const narrow = w.apply(halve, 2, ROWS);
	assert !narrow.ok && narrow.error == WorkspaceError.NoRoomToSplit;
	const room = w.apply(halve, 3, ROWS);
	assert room.ok;
}

test "commands that need a focused pane are refused on an empty workspace" {
	const created = Workspace.create(0);
	assert created.ok;
	if (created.ok) {
		const w = created.value;
		assert refusal(w, { kind: CommandKind.ToggleZoom }) ==
			WorkspaceError.EmptyWorkspace;
		const up: WorkspaceCommand = {
			kind: CommandKind.FocusDirection,
			direction: Direction.Up,
		};
		assert refusal(w, up) == WorkspaceError.EmptyWorkspace;
	}
}
