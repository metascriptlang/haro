import { element } from "../../../neon/src/macros/ui/element";
import { render } from "../../../neon/src/render/host";
import { View, Text } from "../../../neon/src/components/primitives";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { createList, List } from "../../../neon/src/core/list";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { NeonNode } from "../../../neon/src/render/node";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { createVoidHostWith, VoidHost, VoidNode } from "../../../neon/src/platform/void/host";
import { Scene2D, localToGlobal } from "../../../void/src/void2d/node";
import { create } from "../../../void/src/void2d/scene";
import { rgba, vec2 } from "../../../void/src/void2d/types";
import { addFont } from "../../../void/src/void2d/font";

struct Slot { spans: TextSpan[]; }

function slot(s: string): Slot { return { spans: [{ text: s, style: { color: "#fff" } }] }; }

const [rowHeight, setRowHeight] = createSignal<number>(0);

function row(item: Accessor<Slot>): NeonNode {
	return element(
		<Text style={{ fontSize: 14, height: rowHeight() }} cellWidth={8.4} spans={item().spans} />
	);
}

function dump(label: string, vh: VoidHost): void {
	vh.layout(400.0, 300.0);
	const col = (vh.root as VoidNode).children[0];
	let ys = "";
	for (const c of col.children) {
		const at = c.ref.localToGlobal(vec2(0.0, 0.0));
		ys += ` ${at.y}`;
	}
	console.log(`${label}: ${col.children.length} children, y =${ys}`);
}

function mount(items: List<Slot>): VoidHost {
	const font = addFont("assets/JetBrainsMonoNL-Regular.ttf");
	if (!font.ok) { throw new Error("font"); }
	const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), font.value);
	render(
		element(
			<View style={{ flexGrow: 1 }}>{ForList<Slot>({ each: items, children: row })}</View>
		),
		vh.host,
		vh.root,
	);
	return vh;
}

const pushed = createList<Slot>([]);
const vh = mount(pushed);
pushed.push(slot("a"));
pushed.push(slot("b"));
dump("pushed at h=0", vh);
setRowHeight(18);
dump("after setH(18)", vh);
pushed.push(slot("c"));
dump("push after setH", vh);
