// Neon rows mounted straight on the Void host, with no <Void> and no window host:
//   probe/web/ui/buildWeb.sh neonRows

@include("../../../../void/src/sokol/bridge.h");

import { render } from "../../../../neon/src/render/host";
import { createList } from "../../../../neon/src/core/list";
import { ForList } from "../../../../neon/src/macros/ui/flow";
import { Style } from "../../../../neon/src/render/style";
import {
	VoidHost, VoidNode, createVoidHostWith, asFlexStyle, parseColor,
} from "../../../../neon/src/platform/void/host";
import { addFont } from "../../../../void/src/void2d/font";
import { Scene2D } from "../../../../void/src/void2d/node";
import { create } from "../../../../void/src/void2d/scene";
import { Color, rgba } from "../../../../void/src/void2d/types";
import { GridRow, FONT_PATH, BACKGROUND, PADDING, rows, lineRow } from "./rows";
import { presentFrame, startGraphics } from "./present";

extern function voidRun(w: int32, h: int32, init: () => void, frame: () => void): void;

let _vh: VoidHost | null = null;

function frame(): void {
	const vh = _vh;
	if (vh !== null) { presentFrame(vh as VoidHost); }
}

function main(): int32 {
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
	render(
		ForList<GridRow>({ each: createList<GridRow>(rows()), children: lineRow }),
		vh.host,
		vh.root,
	);
	console.log("neonRows: mounted 4 rows on the Void host");
	voidRun(800, 400, startGraphics, frame);
	return 0;
}

main();
