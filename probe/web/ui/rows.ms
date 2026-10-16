// The content both W2 entries mount: four coloured grid rows as <Text cellWidth spans>.
import { element } from "../../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../../neon/src/render/host";
import { Accessor } from "../../../../neon/src/core/signal";
import { Text } from "../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../neon/src/render/hostTypes";

export const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";
export const BACKGROUND = "#0c0c0c";
export const FOREGROUND = "#cccccc";
export const PADDING: number = 6;
const FONT_SIZE: number = 14;

export interface GridRow {
	spans: TextSpan[];
}

function span(text: string, color: string): TextSpan {
	return { text: text, style: { color: color } };
}

export function rows(): GridRow[] {
	return [
		{ spans: [span("red ", "#ff0000"), span("green ", "#00ff00"), span("blue", "#0000ff")] },
		{ spans: [
			{ text: " inverse ", style: { color: "#000000", backgroundColor: "#ffff00" } },
			span(" plain", FOREGROUND),
		] },
		{ spans: [
			{ text: "underlined", style: { color: "#88ccff", textDecorationLine: "underline" } },
			{ text: " struck", style: { color: "#ff8888", textDecorationLine: "line-through" } },
		] },
		{ spans: [span("Haro on the web: JetBrains Mono NL on a Neon cell grid", FOREGROUND)] },
	];
}

export function lineRow(item: Accessor<GridRow>): NeonNode {
	return element(
		<Text
			style={{ fontSize: FONT_SIZE, color: FOREGROUND, height: 18 }}
			cellWidth={8.4}
			spans={item().spans}
		/>
	);
}
