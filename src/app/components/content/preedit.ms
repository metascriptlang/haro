import { Accessor, Setter, createSignal } from "../../../../../neon/src/core/signal";
import { Show } from "../../../../../neon/src/macros/ui/flow";
import { NeonNode } from "../../../../../neon/src/render/node";
import { Text, View } from "../../../../../neon/src/components/primitives";
import { CellMetrics } from "../ui/cellText";

export interface PreeditModel {
	text: Accessor<string>;
	setText: Setter<string>;
}

export function open(this typeof PreeditModel): PreeditModel {
	const [text, setText] = createSignal<string>("");
	return { text: text, setText: setText };
}

export function Preedit(props: {
	model: PreeditModel;
	metrics: CellMetrics;
	col: Accessor<number>;
	row: Accessor<number>;
	background: Accessor<string>;
	foreground: Accessor<string>;
}): NeonNode {
	const p = props.model;
	const m = props.metrics;
	return <Show when={p.text() != ""}>
		<View
			style={{
				position: "absolute",
				left: props.col() * m.cellWidth(),
				top: props.row() * m.rowHeight(),
				backgroundColor: props.background(),
				pointerEvents: "none",
			}}>
			<Text
				style={{
					fontSize: m.fontSize(),
					fontFamily: m.fontFamily(),
					color: props.foreground(),
					height: m.rowHeight(),
					textDecorationLine: "underline",
				}}
				cellWidth={m.cellWidth()}>
				{p.text()}
			</Text>
		</View>
	</Show>;
}
