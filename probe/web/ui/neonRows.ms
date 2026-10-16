// W2a probe: Neon rows mounted straight on the Void host and drawn by void2d through sokol's
// browser canvas loop (--os=emcc). No <Void> and no window host: the Void host's root is the
// mount parent, the way the coordinator's pointer describes "the whole app on the Void host".
//   probe/web/ui/buildWeb.sh neonRows

@include("../../../../void/src/sokol/bridge.h");

import { render } from "../../../../neon/src/render/host";
import { createList } from "../../../../neon/src/core/list";
import { ForList } from "../../../../neon/src/macros/ui/flow";
import { Style } from "../../../../neon/src/render/style";
import {
	VoidHost, VoidNode, createVoidHostWith, asFlexStyle, parseColor,
} from "../../../../neon/src/platform/void/host";
import { gfxSetup, fbWidth, fbHeight, dpiScale } from "../../../../void/src/sokol/gpu";
import { setup2d } from "../../../../void/src/void2d/draw";
import { addFont } from "../../../../void/src/void2d/font";
import { Scene2D } from "../../../../void/src/void2d/node";
import { create, present } from "../../../../void/src/void2d/scene";
import { Color, rgba } from "../../../../void/src/void2d/types";
import { GridRow, FONT_PATH, BACKGROUND, PADDING, rows, lineRow } from "./rows";

extern function voidRun(w: int32, h: int32, init: () => void, frame: () => void): void;

let _vh: VoidHost | null = null;

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
	// naming the export keeps the module, and its @compile list, in the build
	const font = addFont(FONT_PATH);
	if (!font.ok) {
		console.log(`neonRows: the font ${FONT_PATH} did not load`);
		return 1;
	}
	const style: Style = { backgroundColor: BACKGROUND, padding: PADDING };
	const vh = createVoidHostWith(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), font.value);
	(vh.root as VoidNode).flex = asFlexStyle(style);
	const bg = parseColor(BACKGROUND);
	if (bg !== null) { vh.scene.clear = bg as Color; }
	_vh = vh;
	render(ForList<GridRow>({ each: createList<GridRow>(rows()), children: lineRow }), vh.host, vh.root);
	console.log("neonRows: mounted 4 rows on the Void host");
	voidRun(800, 400, init, frame);
	return 0;
}

main();
