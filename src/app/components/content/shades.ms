import { Accessor } from "../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../neon/src/core/list";
import { ForList } from "../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../neon/src/render/node";
import { View } from "../../../../../neon/src/components/primitives";
import { Block } from "../../../select/select";
import { SHADE_OPACITY } from "../../theme";
import { CellMetrics } from "../ui/cellText";

const SHADE_SLOTS: int32 = 3;
const NO_SHADE: Block = { row: 0, col: 0, rows: 0, cols: 0 };

export interface ShadesModel {
	blocks: List<Block>;
	lit: Vec<Block>;
}

export function createShades(): ShadesModel {
	return {
		blocks: createList<Block>([NO_SHADE, NO_SHADE, NO_SHADE]),
		lit: [NO_SHADE, NO_SHADE, NO_SHADE],
	};
}

export function paintShades(this s: ShadesModel, drawn: Vec<Block>): void {
	for (let i = 0; i < SHADE_SLOTS; i++) {
		const next = i < drawn.length ? drawn[i] : NO_SHADE;
		if (next == s.lit[i]) { continue; }
		s.lit[i] = next;
		s.blocks.set(i, next);
	}
}

export function Shades(props: {
	model: ShadesModel;
	metrics: CellMetrics;
	color: Accessor<string>;
}): NeonNode {
	const m = props.metrics;
	const shade = (item: Accessor<Block>): NeonNode => <View
		style={{
			position: "absolute",
			left: item().col * m.cellWidth(),
			top: item().row * m.rowHeight(),
			width: item().cols * m.cellWidth(),
			height: item().rows * m.rowHeight(),
			backgroundColor: props.color(),
			opacity: item().rows > 0 ? SHADE_OPACITY : 0,
			pointerEvents: "none",
		}}
	/>;
	return <ForList each={props.model.blocks}>{shade}</ForList>;
}

test "a selection paints into its slots and clears the slots it no longer uses" {
	const s = createShades();
	const top: Block = { row: 0, col: 2, rows: 1, cols: 5 };
	const rest: Block = { row: 1, col: 0, rows: 2, cols: 80 };
	s.paintShades([top, rest]);
	assert s.blocks.at(0) == top;
	assert s.blocks.at(1) == rest;
	assert s.blocks.at(2) == NO_SHADE;
	s.paintShades([rest]);
	assert s.blocks.at(0) == rest;
	assert s.blocks.at(1) == NO_SHADE;
	assert s.lit.length == SHADE_SLOTS;
}
