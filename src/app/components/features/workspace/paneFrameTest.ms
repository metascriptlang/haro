import { Setter, accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { flush } from "../../../../../../neon/src/core/runtime";
import { element } from "../../../../../../neon/src/macros/ui/element";
import { render } from "../../../../../../neon/src/render/host";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { View } from "../../../../../../neon/src/components/primitives";
import { VoidHost, createVoidHostWith } from "../../../../../../neon/src/platform/void/host";
import { Scene2D } from "../../../../../../void/src/void2d/node";
import { create } from "../../../../../../void/src/void2d/scene";
import { rgba } from "../../../../../../void/src/void2d/types";
import { DEFAULT_FONT, FontStyle, registerFace } from "../../../../../../void/src/void2d/font";
import { Axis, PaneId } from "../../../../workspace/tree";
import {
	CommandKind,
	Workspace,
	WorkspaceCommand,
	activeTab,
	apply,
	create,
} from "../../../../workspace/workspace";
import { CellMetrics } from "../../ui/cellText";
import { DividerStyle, FrameLayout, frameOf } from "./frameLayout";
import { DEFAULT_FRAME_LOOK, FrameLook, PaneFrame } from "./paneFrame";

const COLS: int32 = 81;
const ROWS: int32 = 25;
const CELL: float64 = 10;
const ROW: float64 = 20;
const FAMILY = "Frame Test Mono";

interface Rig {
	vh: VoidHost;
	w: Workspace;
	setLayout: Setter<FrameLayout>;
	log: string[];
}

function must(w: Workspace, c: WorkspaceCommand): void {
	const result = w.apply(c, COLS, ROWS);
	if (!result.ok) { throw new Error(`refused: ${result.error.toString()}`); }
}

function laidOut(w: Workspace): FrameLayout {
	const tab = w.activeTab();
	if (tab === null) { throw new Error("no tab"); }
	return frameOf(tab, COLS, ROWS, w.dividerCells, (id: PaneId): string => "");
}

function run(r: Rig, c: WorkspaceCommand): void {
	must(r.w, c);
	r.setLayout(laidOut(r.w));
}

function settle(r: Rig, c: WorkspaceCommand): void {
	run(r, c);
	flush();
	laidOutView(r.vh);
}

function laidOutView(vh: VoidHost): void {
	vh.layout((COLS as float64) * CELL as float32, (ROWS as float64) * ROW as float32);
}

function rigWith(divider: int32, look: FrameLook): Rig {
	const created = Workspace.create(divider);
	if (!created.ok) { throw new Error("divider refused"); }
	const w = created.value;
	must(w, { kind: CommandKind.NewTab });
	must(w, { kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide });
	const [layout, setLayout] = createSignal<FrameLayout>(laidOut(w));
	registerFace("assets/JetBrainsMonoNL-Regular.ttf", FAMILY, 400, FontStyle.Normal);
	const metrics: CellMetrics = {
		fontSize: accessor((): number => 14),
		fontFamily: accessor((): string => FAMILY),
		cellWidth: accessor((): number => CELL),
		rowHeight: accessor((): number => ROW),
	};
	const vh = createVoidHostWith(
		Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)),
		DEFAULT_FONT,
	);
	const r: Rig = { vh: vh, w: w, setLayout: setLayout, log: [] };
	render(element(<PaneFrame
		layout={layout()}
		metrics={metrics}
		inset={0}
		look={look}
		pane={(id: PaneId): NeonNode => <View style={{ flexGrow: 1 }} />}
		onFocusPane={(id: PaneId): void => {
			r.log.push(`focus ${id as int32}`);
			run(r, { kind: CommandKind.FocusPane, pane: id });
		}}
		onMoveDivider={(before: PaneId, axis: Axis, by: int32): void => {
			r.log.push(`move ${before as int32} ${by}`);
			run(r, { kind: CommandKind.MoveDivider, pane: before, axis: axis, by: by });
		}}
	/>), vh.host, vh.root);
	laidOutView(vh);
	return r;
}

function rig(): Rig {
	return rigWith(1, DEFAULT_FRAME_LOOK);
}

test "a press inside an unfocused pane focuses it" {
	const r = rig();
	r.vh.pointerDown(100.0, 100.0, 1);
	flush();
	r.vh.pointerUp(100.0, 100.0, 1);
	flush();
	assert r.log.join("|") == "focus 1", r.log.join("|");
	r.vh.pointerDown(100.0, 100.0, 1);
	flush();
	r.vh.pointerUp(100.0, 100.0, 1);
	flush();
	assert r.log.join("|") == "focus 1", r.log.join("|");
}

test "dragging the divider resizes cell by cell from where the model left it" {
	const r = rig();
	r.vh.pointerDown(405.0, 100.0, 1);
	flush();
	r.vh.pointerMove(408.0, 100.0, 1, true);
	flush();
	assert r.log.length == 0;
	r.vh.pointerMove(431.0, 100.0, 1, true);
	flush();
	assert r.log.join("|") == "move 1 3", r.log.join("|");
	assert laidOut(r.w).lines[0].at == 43;
	r.vh.pointerMove(395.0, 100.0, 1, true);
	flush();
	assert r.log.join("|") == "move 1 3|move 1 -4", r.log.join("|");
	r.vh.pointerMove(5.0, 100.0, 1, true);
	flush();
	assert r.log[2] == "move 1 -39";
	assert laidOut(r.w).lines[0].at == 1;
	r.vh.pointerMove(15.0, 100.0, 1, true);
	flush();
	assert r.log.length == 3;
	r.vh.pointerMove(395.0, 100.0, 1, true);
	flush();
	assert r.log[3] == "move 1 38";
	r.vh.pointerUp(395.0, 100.0, 1);
	flush();
	r.vh.pointerMove(500.0, 100.0, 0, false);
	flush();
	assert r.log.length == 4;
	assert laidOut(r.w).lines[0].at == 39;
}

test "dragging a divider away from the focused pane moves it and keeps the focus" {
	const r = rig();
	settle(r, { kind: CommandKind.FocusPane, pane: 1 as PaneId });
	settle(r, { kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.Stacked });
	settle(r, { kind: CommandKind.FocusPane, pane: 2 as PaneId });
	r.vh.pointerDown(100.0, 250.0, 1);
	flush();
	r.vh.pointerMove(100.0, 290.0, 1, true);
	flush();
	r.vh.pointerUp(100.0, 290.0, 1);
	flush();
	assert r.log.join("|") == "move 1 2", r.log.join("|");
	assert laidOut(r.w).focused == (2 as PaneId);
}

test "the middle divider of four columns can be dragged" {
	const r = rig();
	settle(r, { kind: CommandKind.FocusPane, pane: 1 as PaneId });
	settle(r, { kind: CommandKind.Split, pane: 1 as PaneId, axis: Axis.SideBySide });
	settle(r, { kind: CommandKind.FocusPane, pane: 2 as PaneId });
	settle(r, { kind: CommandKind.Split, pane: 2 as PaneId, axis: Axis.SideBySide });
	r.vh.pointerDown(405.0, 100.0, 1);
	flush();
	r.vh.pointerMove(431.0, 100.0, 1, true);
	flush();
	r.vh.pointerUp(431.0, 100.0, 1);
	flush();
	assert r.log.join("|") == "move 3 3", r.log.join("|");
	assert laidOut(r.w).focused == (4 as PaneId);
}

test "a thin line without divider cells is grabbed around it and snaps to cell boundaries" {
	const r = rigWith(0, { ...DEFAULT_FRAME_LOOK, style: DividerStyle.Line });
	assert laidOut(r.w).lines[0].at == 41;
	r.vh.pointerDown(412.0, 100.0, 1);
	flush();
	r.vh.pointerMove(436.0, 100.0, 1, true);
	flush();
	r.vh.pointerUp(436.0, 100.0, 1);
	flush();
	assert r.log.join("|") == "move 1 3", r.log.join("|");
	assert laidOut(r.w).lines[0].at == 44;
}
