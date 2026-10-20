import { element } from "../../../neon/src/macros/ui/element";
import { render } from "../../../neon/src/render/host";
import { Text } from "../../../neon/src/components/primitives";
import { createSignal } from "../../../neon/src/core/signal";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { createVoidHostWith, VoidNode } from "../../../neon/src/platform/void/host";
import { Scene2D } from "../../../void/src/void2d/node";
import { create } from "../../../void/src/void2d/scene";
import { rgba } from "../../../void/src/void2d/types";
import { addFont, registerFace, FontStyle } from "../../../void/src/void2d/font";
import { labelTexts } from "../../../void/src/void2d/labelText";

test "spans update" {
	const PATH = "assets/JetBrainsMonoNL-Regular.ttf";
	const font = addFont(PATH);
	if (!font.ok) { throw new Error("font"); }
	registerFace("assets/JetBrainsMonoNL-Bold.ttf", PATH, 700, FontStyle.Normal);
	const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), font.value, PATH);

	const plain: Style = {
		color: "#ffffff",
		textDecorationLine: "none",
		textDecorationStyle: "solid",
		fontWeight: "normal",
		fontStyle: "normal",
	};
	const bold: Style = { ...plain, fontWeight: "bold" };
	const curly: Style = { ...plain, textDecorationLine: "underline", textDecorationStyle: "wavy" };
	const [spans, setSpans] = createSignal<TextSpan[]>([
		{ text: "bold", style: bold },
		{ text: "      ", style: plain },
	]);
	render(
		element(<Text style={{ fontSize: 14, height: 18 }} cellWidth={8.4} spans={spans()} />),
		vh.host,
		vh.root,
	);

	const dump = (label: string): void => {
		vh.layout(400.0, 100.0);
		const t = (vh.root as VoidNode).children[0];
		const para = t.para;
		if (para === null) { console.log(`${label}: no paragraph`); return; }
		let out = "";
		for (const r of labelTexts[vh.scene.payloads[para.id.index]].runs) {
			out += ` [len=${r.len} font=${r.font as int32} ul=${r.underline.a} wavy=${r.wavy}]`;
		}
		console.log(`${label}:${out}`);
	};

	dump("first");
	setSpans([
		{ text: "bold", style: bold },
		{ text: " ", style: plain },
		{ text: "curly", style: curly },
		{ text: " plain", style: plain },
	]);
	dump("after set");
}
