// The rows inside one full-window <Void>, under a window host that accepts only that tag:
//   probe/web/ui/buildWeb.sh neonVoid

@include("../../../../void/src/sokol/bridge.h");

import { element } from "../../../../neon/src/macros/ui/element";
import { Host, HostNode, NeonNode, VoidArea, render } from "../../../../neon/src/render/host";
import { NeonEvent } from "../../../../neon/src/render/event";
import { createAreaHub } from "../../../../neon/src/render/voidAreaHandle";
import { createList } from "../../../../neon/src/core/list";
import { ForList } from "../../../../neon/src/macros/ui/flow";
import { Void } from "../../../../neon/src/components/primitives";
import { Style } from "../../../../neon/src/render/style";
import {
	VoidHost, VoidNode, createVoidHostWith, asFlexStyle, parseColor,
} from "../../../../neon/src/platform/void/host";
import { gfxSetup, fbWidth, fbHeight, dpiScale } from "../../../../void/src/sokol/gpu";
import { setup2d } from "../../../../void/src/void2d/draw";
import { addFont, FontId } from "../../../../void/src/void2d/font";
import { Scene2D } from "../../../../void/src/void2d/node";
import { create, present } from "../../../../void/src/void2d/scene";
import { Color, rgba } from "../../../../void/src/void2d/types";
import { GridRow, FONT_PATH, BACKGROUND, PADDING, rows, lineRow } from "./rows";

extern function voidRun(w: int32, h: int32, init: () => void, frame: () => void): void;

interface WindowNode {
	tag: string;
}

function windowNode(tag: string): HostNode {
	const n: WindowNode = { tag };
	return n as unknown as HostNode;
}

let _vh: VoidHost | null = null;
let _font: FontId = 0 as FontId;

function applyAreaStyle(vh: VoidHost, style: Style): void {
	(vh.root as VoidNode).flex = asFlexStyle(style);
	if (style.backgroundColor !== null) {
		const c = parseColor(style.backgroundColor as string);
		if (c !== null) { vh.scene.clear = c as Color; }
	}
}

function windowHost(): Host {
	let pendingStyle: Style | null = null;
	const refuse = (what: string): void => {
		throw `browser window host: ${what}; the window holds exactly one <Void>`;
	};
	const openArea = (node: HostNode): VoidArea => {
		if (_vh !== null) { refuse("a second <Void> was mounted"); }
		const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), _font);
		const hub = createAreaHub({
			initialPixelWidth: 800 as int32,
			initialPixelHeight: 400 as int32,
			requestFrame: (): void => {},
			setImeRect: (x: int32, y: int32, w: int32, h: int32): void => {},
		});
		_vh = vh;
		if (pendingStyle !== null) { applyAreaStyle(vh, pendingStyle as Style); }
		return {
			host: vh.host,
			root: vh.root as unknown as HostNode,
			hub,
			release: (): void => {
				vh.scene.close();
				_vh = null;
			},
		};
	};
	return {
		createElement: (tag: string): HostNode => {
			if (tag !== "void") { refuse(`<${tag}> cannot be a child of the window`); }
			return windowNode(tag);
		},
		createText: (s: string): HostNode => {
			refuse(`text "${s}" cannot be a child of the window`);
			return windowNode("");
		},
		setText: (node: HostNode, s: string): void => {
			refuse("text cannot be set on the window");
		},
		setAttr: (node: HostNode, name: string, value: string): void => {},
		removeAttr: (node: HostNode, name: string): void => {},
		setStyle: (node: HostNode, style: Style): void => {
			pendingStyle = style;
			const vh = _vh;
			if (vh !== null) { applyAreaStyle(vh as VoidHost, style); }
		},
		setStyleProp: null,
		setStyleClass: null,
		addEvent: (node: HostNode, name: string, handler: (e: NeonEvent) => void): void => {
			refuse(`${name} on the window element`);
		},
		append: (parent: HostNode, child: HostNode): void => {},
		insertBefore: (parent: HostNode, node: HostNode, ref: HostNode | null): void => {},
		removeChild: (parent: HostNode, node: HostNode): void => {},
		nextSibling: (node: HostNode): HostNode | null => null,
		firstChild: (node: HostNode): HostNode | null => null,
		cloneNode: null,
		voidArea: openArea,
		scrollTo: null,
	};
}

function App(): NeonNode {
	return element(
		<Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
			{ForList<GridRow>({ each: createList<GridRow>(rows()), children: lineRow })}
		</Void>
	);
}

function init(): void {
	gfxSetup();
	setup2d();
}

function frame(): void {
	const vh = _vh;
	if (vh === null) { return; }
	const h = vh as VoidHost;
	const scale = dpiScale();
	h.layout((fbWidth() as float32) / scale, (fbHeight() as float32) / scale);
	h.scene.present();
}

function main(): int32 {
	const font = addFont(FONT_PATH);
	if (!font.ok) {
		console.log(`neonVoid: the font ${FONT_PATH} did not load`);
		return 1;
	}
	_font = font.value;
	render(App(), windowHost(), windowNode("window"));
	console.log("neonVoid: mounted <Void> with 4 rows");
	voidRun(800, 400, init, frame);
	return 0;
}

main();
