import { Setter, createSignal } from "../../../neon/src/core/signal";
import { flush } from "../../../neon/src/core/runtime";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { familyFont } from "../../../neon/src/platform/void/host";
import { spriteCellFor } from "../../../void/src/void2d/font";
import { Config, defaults, pxOf, steppedFont } from "../config/config";
import { Action } from "../input/bindings";
import { CellMetrics } from "./components/ui/cellText";

const FONT_STEP_POINTS: float64 = 1;

export interface CellFont {
	metrics: CellMetrics;
	setFontSize: Setter<number>;
	setFontFamily: Setter<string>;
	setCellWidth: Setter<number>;
	setRowHeight: Setter<number>;
	points: float64;
	configPoints: float64;
	adjusted: boolean;
	cellPx: int32;
	rowPx: int32;
}

export function open(
	this typeof CellFont,
	started: Config,
	family: string,
): CellFont {
	const [fontSize, setFontSize] = createSignal<number>(started.fontPx());
	const [fontFamily, setFontFamily] = createSignal<string>(family);
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	return {
		metrics: {
			fontSize: fontSize,
			fontFamily: fontFamily,
			cellWidth: cellWidth,
			rowHeight: rowHeight,
		},
		setFontSize: setFontSize,
		setFontFamily: setFontFamily,
		setCellWidth: setCellWidth,
		setRowHeight: setRowHeight,
		points: started.fontSize,
		configPoints: started.fontSize,
		adjusted: false,
		cellPx: 0,
		rowPx: 0,
	};
}

function sized(this f: CellFont, points: float64): void {
	f.points = points;
	f.setFontSize(pxOf(points));
	flush();
}

export function stepped(this f: CellFont, action: Action): boolean {
	match (action) {
		Action.IncreaseFontSize => {
			f.adjusted = true;
			f.sized(steppedFont(f.points, FONT_STEP_POINTS));
		},
		Action.DecreaseFontSize => {
			f.adjusted = true;
			f.sized(steppedFont(f.points, -FONT_STEP_POINTS));
		},
		Action.ResetFontSize => {
			f.adjusted = false;
			f.sized(f.configPoints);
		},
		_ => { return false; },
	}
	return true;
}

export function reconfigured(
	this f: CellFont,
	c: Config,
	family: string,
): boolean {
	f.configPoints = c.fontSize;
	const points = f.adjusted ? f.points : c.fontSize;
	const changed = pxOf(points) != f.metrics.fontSize() ||
		family != f.metrics.fontFamily();
	f.points = points;
	f.setFontSize(pxOf(points));
	f.setFontFamily(family);
	flush();
	return changed;
}

export function measured(this f: CellFont): Result<void, string> {
	const family = f.metrics.fontFamily();
	const font = familyFont(family, 400, false);
	if (!font.ok) {
		const why = font.error.toString();
		return Result.err(`family "${family}" has no face: ${why}`);
	}
	const ratio = PixelRatio.get();
	const size = (f.metrics.fontSize() * ratio) as float32;
	const cell = spriteCellFor(font.value, size);
	if (cell.width <= 0 || cell.height <= 0) {
		const shown = `${cell.width}x${cell.height}`;
		return Result.err(`cell ${shown} px is not a grid size`);
	}
	f.cellPx = cell.width;
	f.rowPx = cell.height;
	f.setCellWidth(cell.width / ratio);
	f.setRowHeight(cell.height / ratio);
	flush();
	return Result.ok(null);
}

test "the font steps by a point, resets to the config's, and keeps a step over a reload" {
	const started: Config = { ...defaults() };
	const f = CellFont.open(started, "");
	const base = started.fontSize;
	assert f.metrics.fontSize() == pxOf(base);
	assert f.stepped(Action.IncreaseFontSize);
	assert f.stepped(Action.IncreaseFontSize);
	assert f.metrics.fontSize() == pxOf(base + 2);
	assert f.stepped(Action.DecreaseFontSize);
	assert f.metrics.fontSize() == pxOf(base + 1);
	assert !f.reconfigured({ ...defaults(), fontSize: 30 }, "");
	assert f.metrics.fontSize() == pxOf(base + 1);
	assert f.stepped(Action.ResetFontSize);
	assert f.metrics.fontSize() == pxOf(30);
	assert f.reconfigured({ ...defaults(), fontSize: 20 }, "");
	assert f.metrics.fontSize() == pxOf(20);
	assert f.reconfigured({ ...defaults(), fontSize: 20 }, "Other Mono");
	assert f.metrics.fontFamily() == "Other Mono";
	for (let i = 0; i < 400; i++) { f.stepped(Action.DecreaseFontSize); }
	assert f.metrics.fontSize() == pxOf(1);
	assert !f.stepped(Action.Copy);
}
