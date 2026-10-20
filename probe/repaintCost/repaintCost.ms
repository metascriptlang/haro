import { element } from "../../../neon/src/macros/ui/element";
import { render } from "../../../neon/src/render/host";
import { View, Text } from "../../../neon/src/components/primitives";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { createList, List } from "../../../neon/src/core/list";
import { Accessor } from "../../../neon/src/core/signal";
import { NeonNode } from "../../../neon/src/render/node";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Style } from "../../../neon/src/render/style";
import { createVoidHostWith } from "../../../neon/src/platform/void/host";
import { Scene2D, clearChanges } from "../../../void/src/void2d/node";
import { create, paint as paintScene } from "../../../void/src/void2d/scene";
import { frameEnd } from "../../../void/src/void2d/draw";
import { rgba } from "../../../void/src/void2d/types";
import { addFont } from "../../../void/src/void2d/font";

struct Slot { spans: TextSpan[]; }

const COLS: int32 = 105;
const ROWS: int32 = 30;
const plain: Style = { color: "#cccccc" };
const keyword: Style = { color: "#c678dd", fontWeight: "normal" };

function rowText(seed: int32, y: int32): string {
	let s = "";
	for (let x = 0; x < COLS; x++) { s += String.fromCharCode(97 + ((seed + y * 7 + x * 3) % 26)); }
	return s;
}

function slot(seed: int32, y: int32): Slot {
	const t = rowText(seed, y);
	return {
		spans: [{ text: t.slice(0, 20), style: keyword }, { text: t.slice(20), style: plain }],
	};
}

test "time a full-screen repaint through Neon and void2d" {
	const font = addFont("assets/JetBrainsMonoNL-Regular.ttf");
	assert font.ok;
	if (!font.ok) { return; }
	const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), font.value);
	const items: List<Slot> = createList<Slot>([]);
	for (let y = 0; y < ROWS; y++) { items.push(slot(0, y)); }
	const row = (item: Accessor<Slot>): NeonNode => element(
		<Text style={{ fontSize: 14, height: 18 }} cellWidth={8.4} spans={item().spans} />
	);
	render(
		element(
			<View style={{ flexGrow: 1 }}>{ForList<Slot>({ each: items, children: row })}</View>
		),
		vh.host,
		vh.root,
	);
	vh.layout(948.0, 588.0);
	vh.scene.paintScene(948.0, 588.0, 1.0);
	frameEnd();
	vh.scene.clearChanges();
	const frames: int32 = 60;
	let setMs = 0.0;
	let layoutMs = 0.0;
	let paintMs = 0.0;
	for (let f = 1; f <= frames; f++) {
		const setStart = performance.now();
		for (let y = 0; y < ROWS; y++) { items.set(y, slot(f, y)); }
		const layoutStart = performance.now();
		vh.layout(948.0, 588.0);
		const paintStart = performance.now();
		vh.scene.paintScene(948.0, 588.0, 1.0);
		frameEnd();
		vh.scene.clearChanges();
		const paintEnd = performance.now();
		setMs += layoutStart - setStart;
		layoutMs += paintStart - layoutStart;
		paintMs += paintEnd - paintStart;
	}
	console.log(
		`per full repaint of ${ROWS}x${COLS}: set ${(setMs / frames)} ms, ` +
		`layout ${(layoutMs / frames)} ms, paint ${(paintMs / frames)} ms`,
	);
}
