import { Accessor } from "../../../../../../neon/src/core/signal";
import { ForList } from "../../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { View, ViewHandle } from "../../../../../../neon/src/components/primitives";
import { RowSlot } from "../../../frame";
import { CellText } from "../../ui/cellText";
import { CursorBoxes } from "../../content/cursor";
import { Preedit } from "../../content/preedit";
import { Shades } from "../../content/shades";
import { PaneModel, laidOut } from "./paneModel";
import {
	committed,
	dragged,
	focusChanged,
	keyed,
	pressed,
	released,
	wheeled,
} from "./paneEvents";

export function TerminalPane(props: { model: PaneModel }): NeonNode {
	const m = props.model;
	const metrics = m.metrics;
	const row = (item: Accessor<RowSlot>): NeonNode => <CellText
		metrics={metrics}
		spans={item().spans}
	/>;
	return <View
		style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
		focusable
		ref={(h: ViewHandle): void => {
			m.grid = h;
			h.focus();
		}}
		imeRect={{
			x: m.cursor.col() * metrics.cellWidth(),
			y: m.cursor.row() * metrics.rowHeight(),
			width: metrics.cellWidth(),
			height: metrics.rowHeight(),
		}}
		onLayout={(e: NeonEvent): void => { m.laidOut(e); }}
		onKeyDown={(e: NeonEvent): void => { m.keyed(e); }}
		onTextInput={(e: NeonEvent): void => { m.committed(e); }}
		onPreedit={(e: NeonEvent): void => { m.preedit.setText(e.text); }}
		onPointerDown={(e: NeonEvent): void => { m.pressed(e); }}
		onPointerMove={(e: NeonEvent): void => { m.dragged(e); }}
		onPointerUp={(e: NeonEvent): void => { m.released(e); }}
		onFocus={(e: NeonEvent): void => { m.focusChanged(true); }}
		onBlur={(e: NeonEvent): void => { m.focusChanged(false); }}
		onWheel={(e: NeonEvent): void => { m.wheeled(e); }}>
		<ForList each={m.term.grid}>{row}</ForList>
		<Shades model={m.shades} metrics={metrics} color={m.foreground()} />
		<CursorBoxes model={m.cursor} color={m.foreground()} />
		<Preedit
			model={m.preedit}
			metrics={metrics}
			col={m.cursor.col()}
			row={m.cursor.row()}
			background={m.background()}
			foreground={m.foreground()}
		/>
	</View>;
}
