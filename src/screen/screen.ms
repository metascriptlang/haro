import { GridLine, LineRun } from "../grid/lines";
import { Rgb, Underline } from "../vt/vt";
import {
	Scene2D, NodeRef, group, rect, label, refOf, setPosition, setVisible, setText, setTextRuns, local, order, content, textStyle, text,
	layoutGetChildren,
	setFont, setForceWidth, addChild, addChildAt, dispose,
} from "../../../void/src/void2d/node";
import { Color, rgba } from "../../../void/src/void2d/types";
import { FontId } from "../../../void/src/void2d/font";
import { TextRun } from "../../../void/src/void2d/textLayout";
import { DEFAULT_FONT } from "../../../void/src/void2d/font";
import { labelTexts } from "../../../void/src/void2d/labelText";
import "../../../void/src/void2d/scene";

export struct ScreenFonts {
	regular: FontId;
	bold: FontId;
	italic: FontId;
	boldItalic: FontId;
}

// Cell sizes are whole device pixels; `size` is the font size the cell was measured for.
export struct ScreenStyle {
	fonts: ScreenFonts;
	size: float32;
	cellWidth: int32;
	cellHeight: int32;
	foreground: Rgb;
	background: Rgb;
	cursor: Rgb;
}

export interface Screen {
	scene: Scene2D;
	style: ScreenStyle;
	cols: int32;
	rows: int32;
	rowGroups: Vec<NodeRef>;
	rowLabels: Vec<NodeRef>;
	cursor: NodeRef;
}

const CLEAR: Color = rgba(0.0, 0.0, 0.0, 0.0);

function colorOf(c: Rgb): Color {
	return rgba((c.r as float32) / 255.0, (c.g as float32) / 255.0, (c.b as float32) / 255.0, 1.0);
}

function fontFor(this style: ScreenStyle, run: LineRun): FontId {
	return run.bold
		? (run.italic ? style.fonts.boldItalic : style.fonts.bold)
		: (run.italic ? style.fonts.italic : style.fonts.regular);
}

// void2d draws one underline colour and a straight or wavy stroke; the other kinds are Single.
function textRunOf(this style: ScreenStyle, run: LineRun): TextRun {
	const fg = colorOf(run.fg);
	return {
		len: run.units,
		font: style.fontFor(run),
		color: fg,
		background: run.bg == style.background ? CLEAR : colorOf(run.bg),
		underline: run.underline == Underline.None ? CLEAR : fg,
		wavy: run.underline == Underline.Curly,
		strikethrough: run.strikethrough ? fg : CLEAR,
	};
}

function newRow(this s: Screen, row: int32): void {
	const g = s.scene.group();
	g.setPosition(0.0, (row * s.style.cellHeight) as float32);
	const text = s.scene.label("", s.style.size, colorOf(s.style.foreground));
	text.setFont(s.style.fonts.regular).setForceWidth(s.style.cellWidth as float32);
	g.addChild(text);
	s.scene.refOf(s.scene.root).addChildAt(g, row);
	s.rowGroups.push(g);
	s.rowLabels.push(text);
}

export function create(
	this typeof Screen, scene: Scene2D, style: ScreenStyle, cols: int32, rows: int32,
): Screen {
	const cursor = scene.rect(style.cellWidth as float32, style.cellHeight as float32, colorOf(style.cursor));
	cursor.setVisible(false);
	const s: Screen = {
		scene: scene, style: style, cols: 0, rows: 0,
		rowGroups: [], rowLabels: [], cursor: cursor,
	};
	scene.add(cursor);
	s.resize(cols, rows);
	return s;
}

// Rewrites one row's text and runs. A run's background is the label's own run decoration, so a
// row stays one node; the foreground, underline and strikethrough ride the same run.
export function setLine(this s: Screen, row: int32, line: GridLine): void {
	let runs: Vec<TextRun> = [];
	for (const run of line.runs) { runs.push(s.style.textRunOf(run)); }
	s.rowLabels[row].setText(line.text).setTextRuns(runs);
}

export function setCursor(this s: Screen, col: int32, row: int32, visible: boolean): void {
	const shown = visible && col >= 0 && col < s.cols && row >= 0 && row < s.rows;
	s.cursor.setVisible(shown);
	if (shown) {
		s.cursor.setPosition((col * s.style.cellWidth) as float32, (row * s.style.cellHeight) as float32);
	}
}

// New rows start empty and the caller sets every line again, as the VT marks them all dirty.
export function resize(this s: Screen, cols: int32, rows: int32): void {
	while (s.rows > rows) {
		s.rowGroups[s.rows - 1].dispose();
		s.rowGroups.pop();
		s.rowLabels.pop();
		s.rows -= 1;
	}
	while (s.rows < rows) {
		s.newRow(s.rows);
		s.rows += 1;
	}
	s.cols = cols;
}

// Parked: runtime run waits on compiler card 2026-10-15 extern Span+out emission (vt.ms:733).
const DEFAULT_BG: Rgb = { r: 0, g: 0, b: 0 };
const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const RED: Rgb = { r: 255, g: 0, b: 0 };
const BLUE: Rgb = { r: 0, g: 0, b: 255 };

function testScreen(cols: int32, rows: int32): Screen {
	const fonts: ScreenFonts = {
		regular: DEFAULT_FONT, bold: DEFAULT_FONT, italic: DEFAULT_FONT, boldItalic: DEFAULT_FONT,
	};
	const style: ScreenStyle = {
		fonts: fonts, size: 14.0, cellWidth: 9, cellHeight: 18, foreground: WHITE, background: DEFAULT_BG,
		cursor: WHITE,
	};
	return Screen.create(Scene2D.create(rgba(0.0, 0.0, 0.0, 1.0)), style, cols, rows);
}

function runOf(units: int32, fg: Rgb, bg: Rgb): LineRun {
	return {
		units: units, fg: fg, bg: bg, underline: Underline.None,
		bold: false, italic: false, strikethrough: false,
	};
}

test "each row is a group on the cell grid holding one label with forced width" {
	const s = testScreen(10, 3);
	assert s.rows == 3;
	for (let r = 0; r < 3; r++) {
		assert s.rowGroups[r].local().y == (r * 18) as float32;
		assert s.rowGroups[r].local().x == 0.0;
		assert s.rowLabels[r].textStyle().size == 14.0;
	}
}

test "setLine rewrites only its row, text and runs" {
	const s = testScreen(4, 2);
	const runs: Vec<LineRun> = [runOf(1, RED, DEFAULT_BG), runOf(3, WHITE, BLUE)];
	s.setLine(1, { text: "abcd", runs: runs, cursorCell: -1 });
	assert s.rowLabels[1].text() == "abcd";
	assert s.rowLabels[0].text() == "";
	const placed = labelTexts[s.scene.payloads[s.rowLabels[1].id.index]].runs;
	assert placed.length == 2;
	assert placed[0].len == 1 && placed[0].color == colorOf(RED) && placed[0].background == CLEAR;
	assert placed[1].len == 3 && placed[1].background == colorOf(BLUE);
}

test "the cursor is its own rect on the k*cell grid" {
	const s = testScreen(10, 3);
	assert !s.cursor.order().visible;
	s.setCursor(4, 2, true);
	assert s.cursor.order().visible;
	assert s.cursor.local().x == 36.0 && s.cursor.local().y == 36.0;
	assert s.cursor.content().w == 9.0 && s.cursor.content().h == 18.0;
	s.setCursor(4, 2, false);
	assert !s.cursor.order().visible;
	s.setCursor(10, 0, true);
	assert !s.cursor.order().visible;
}

test "resize adds and drops rows and keeps the rest" {
	const s = testScreen(10, 2);
	s.setLine(0, { text: "x", runs: [runOf(1, WHITE, DEFAULT_BG)], cursorCell: -1 });
	s.resize(12, 4);
	assert s.rows == 4 && s.cols == 12;
	assert s.rowGroups[3].local().y == 54.0;
	assert s.rowLabels[0].text() == "x";
	s.resize(12, 1);
	assert s.rows == 1 && s.rowGroups.length == 1;
	assert s.scene.refOf(s.scene.root).layoutGetChildren().length == 2;
}
