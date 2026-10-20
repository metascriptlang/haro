import { Accessor } from "../../../../../neon/src/core/signal";
import { NeonNode } from "../../../../../neon/src/render/node";
import { TextSpan } from "../../../../../neon/src/render/hostTypes";
import { Text } from "../../../../../neon/src/components/primitives";

export interface CellMetrics {
	fontSize: number;
	cellWidth: Accessor<number>;
	rowHeight: Accessor<number>;
}

export function CellText(props: { metrics: CellMetrics; spans: Accessor<TextSpan[]> }): NeonNode {
	return <Text
		style={{ fontSize: props.metrics.fontSize, height: props.metrics.rowHeight() }}
		cellWidth={props.metrics.cellWidth()}
		spans={props.spans()}
	/>;
}
