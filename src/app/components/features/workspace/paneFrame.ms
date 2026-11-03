import { Accessor, untrack } from "../../../../../../neon/src/core/signal";
import { For, Repeat, Show } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { View } from "../../../../../../neon/src/components/primitives";
import { Axis, PaneId, Placed } from "../../../../workspace/tree";
import { Direction } from "../../../../workspace/workspace";
import { CellMetrics, CellText } from "../../ui/cellText";
import {
	Box,
	DividerLine,
	DividerStyle,
	FrameLayout,
	Segment,
	TitleSpot,
	dragStep,
	lineBox,
	paneBox,
} from "./frameLayout";

export struct FrameLook {
	style: DividerStyle;
	gapPixels: float64;
	divider: string;
	focusedDivider: string;
}

export const DEFAULT_FRAME_LOOK: FrameLook = {
	style: DividerStyle.Cell,
	gapPixels: 0,
	divider: "#4e4e4e",
	focusedDivider: "#5fafd7",
};

const LINE_PIXELS: float64 = 1;
const LINE_GRAB_PIXELS: float64 = 7;

export interface PaneFrameProps {
	layout: Accessor<FrameLayout>;
	metrics: CellMetrics;
	inset: Accessor<number>;
	look: Accessor<FrameLook>;
	pane: (id: PaneId) => NeonNode;
	onFocusPane: (id: PaneId) => void;
	onResize: (direction: Direction, cells: int32) => void;
}

interface Drag {
	line: DividerLine | null;
	origin: float64;
}

function colourOf(look: FrameLook, focused: boolean): string {
	return focused ? look.focusedDivider : look.divider;
}

function cellBox(s: Segment, cellWidth: float64, rowHeight: float64): Box {
	const vertical = s.axis == Axis.SideBySide;
	return {
		left: s.x * cellWidth,
		top: s.y * rowHeight,
		width: vertical ? cellWidth : s.length * cellWidth,
		height: vertical ? s.length * rowHeight : rowHeight,
	};
}

function segmentBox(
	s: Segment,
	f: FrameLayout,
	look: FrameLook,
	m: CellMetrics,
): Box {
	if (look.style == DividerStyle.Cell) {
		return cellBox(s, m.cellWidth(), m.rowHeight());
	}
	return lineBox(s, f.divider, m.cellWidth(), m.rowHeight(), LINE_GRAB_PIXELS);
}

function grabbed(
	this d: Drag,
	props: PaneFrameProps,
	s: Segment,
	e: NeonEvent,
): void {
	const f = props.layout();
	const line = f.lines[s.line];
	const handle = line.handle;
	if (handle === null) { return; }
	const box = segmentBox(s, f, props.look(), props.metrics);
	const vertical = s.axis == Axis.SideBySide;
	d.origin = vertical
		? e.x - e.locationX - box.left
		: e.y - e.locationY - box.top;
	d.line = line;
	if (!(handle == f.focused)) { props.onFocusPane(handle); }
}

function dragged(this d: Drag, props: PaneFrameProps, e: NeonEvent): void {
	const line = d.line;
	if (line === null) { return; }
	if (!e.pressed) {
		d.line = null;
		return;
	}
	const vertical = line.split.axis == Axis.SideBySide;
	const cell = vertical
		? props.metrics.cellWidth()
		: props.metrics.rowHeight();
	if (cell <= 0) { return; }
	const at = vertical ? e.x : e.y;
	const step = line.dragStep((at - d.origin) / cell, props.layout().divider);
	if (step !== null) { props.onResize(step.direction, step.cells); }
}

function CellSegment(props: {
	segment: Accessor<Segment>;
	metrics: CellMetrics;
	colour: Accessor<string>;
}): NeonNode {
	const s = props.segment;
	return <Show
		when={s().axis == Axis.SideBySide}
		fallback={<CellText
			metrics={props.metrics}
			spans={[{ text: s().glyphs, style: { color: props.colour() } }]}
			widths={[]}
		/>}>
		<Repeat count={s().length}>
			{(i: number): NeonNode => <CellText
				metrics={props.metrics}
				spans={[{
					text: s().glyphs.charAt(i as int32),
					style: { color: props.colour() },
				}]}
				widths={[]}
			/>}
		</Repeat>
	</Show>;
}

function LineSegment(props: {
	segment: Accessor<Segment>;
	colour: Accessor<string>;
}): NeonNode {
	const vertical = (): boolean => props.segment().axis == Axis.SideBySide;
	const offset = (LINE_GRAB_PIXELS - LINE_PIXELS) / 2;
	return <View
		style={{
			position: "absolute",
			left: vertical() ? offset : 0,
			top: vertical() ? 0 : offset,
			width: vertical() ? LINE_PIXELS : "100%",
			height: vertical() ? "100%" : LINE_PIXELS,
			backgroundColor: props.colour(),
		}}
	/>;
}

function Title(props: {
	spot: Accessor<TitleSpot>;
	metrics: CellMetrics;
	look: Accessor<FrameLook>;
	onFocusPane: (id: PaneId) => void;
}): NeonNode {
	const t = props.spot;
	const m = props.metrics;
	return <View
		style={{
			position: "absolute",
			left: t().x * m.cellWidth(),
			top: t().y * m.rowHeight(),
			pointerEvents: "box-only",
		}}
		onPointerDown={(e: NeonEvent): void => { props.onFocusPane(t().pane); }}>
		<CellText
			metrics={m}
			spans={[{
				text: t().text,
				style: { color: colourOf(props.look(), t().focused) },
			}]}
			widths={[]}
		/>
	</View>;
}

export function PaneFrame(props: PaneFrameProps): NeonNode {
	const m = props.metrics;
	const drag: Drag = { line: null, origin: 0 };
	const paneView = (item: Accessor<Placed>): NeonNode => {
		const id = untrack((): PaneId => item().pane.id);
		const box = (): Box => {
			const f = props.layout();
			return paneBox(
				item().rect,
				f.cols,
				f.rows,
				m.cellWidth(),
				m.rowHeight(),
				props.look().gapPixels,
			);
		};
		return <View
			style={{
				position: "absolute",
				left: box().left,
				top: box().top,
				width: box().width,
				height: box().height,
				overflow: "hidden",
			}}
			onPointerDown={(e: NeonEvent): void => {
				if (!(id == props.layout().focused)) { props.onFocusPane(id); }
			}}>
			{props.pane(id)}
		</View>;
	};
	const segmentView = (item: Accessor<Segment>, index: number): NeonNode => {
		const box = (): Box =>
			segmentBox(item(), props.layout(), props.look(), m);
		const colour = (): string => colourOf(props.look(), item().focused);
		return <View
			style={{
				position: "absolute",
				left: box().left,
				top: box().top,
				width: box().width,
				height: box().height,
				pointerEvents: "box-only",
			}}
			onPointerDown={(e: NeonEvent): void => {
				drag.grabbed(props, item(), e);
			}}>
			<Show
				when={props.look().style == DividerStyle.Cell}
				fallback={<LineSegment segment={item()} colour={colour()} />}>
				<CellSegment segment={item()} metrics={m} colour={colour()} />
			</Show>
		</View>;
	};
	return <View
		style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0 }}
		onPointerMove={(e: NeonEvent): void => { drag.dragged(props, e); }}
		onPointerUp={(e: NeonEvent): void => { drag.line = null; }}>
		<View
			style={{
				position: "absolute",
				left: props.inset(),
				top: props.inset(),
				right: props.inset(),
				bottom: props.inset(),
			}}>
			<For
				each={props.layout().panes}
				keyed={(p: Placed): int32 => p.pane.id as int32}>
				{paneView}
			</For>
			<For each={props.layout().segments} keyed={false}>
				{segmentView}
			</For>
			<For each={props.layout().titles} keyed={false}>
				{(item: Accessor<TitleSpot>, index: number): NeonNode => <Title
					spot={item()}
					metrics={m}
					look={props.look()}
					onFocusPane={props.onFocusPane}
				/>}
			</For>
		</View>
	</View>;
}
