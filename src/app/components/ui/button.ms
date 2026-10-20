import { Accessor, createSignal } from "../../../../../neon/src/core/signal";
import { NeonNode } from "../../../../../neon/src/render/node";
import { Pressable, Text } from "../../../../../neon/src/components/primitives";
import { ButtonLook } from "../../theme";
import { CellMetrics } from "./cellText";

export function Button(props: {
	look: ButtonLook;
	label: Accessor<string>;
	metrics: CellMetrics;
	onPress: () => void;
}): NeonNode {
	const [held, setHeld] = createSignal<boolean>(false);
	const m = props.metrics;
	return <Pressable
		style={{
			backgroundColor: held() ? props.look.heldBackground : props.look.background,
			paddingLeft: 16,
			paddingRight: 16,
			paddingTop: 6,
			paddingBottom: 6,
			borderRadius: 4,
		}}
		onPressIn={(): void => { setHeld(true); }}
		onPressOut={(): void => { setHeld(false); }}
		onPress={(): void => { props.onPress(); }}>
		<Text
			style={{
				fontSize: m.fontSize,
				height: m.rowHeight(),
				width: props.label().length * m.cellWidth(),
			}}
			cellWidth={m.cellWidth()}
			spans={[{ text: props.label(), style: props.look.text }]}
		/>
	</Pressable>;
}
