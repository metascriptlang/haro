import { GhosttyMouseEncoder, GhosttyMouseEvent } from "../../vendor/ghostty/include/ghostty/vt.h";
import { KeyMod } from "../keys/keys";
import { RowSpan } from "../select/select";

export enum VtError {
	CreateFailed,
	UpdateFailed,
	ResizeFailed,
	ReadFailed,
	WriteFailed,
	GraphemeTooLong,
	CodepointInvalid,
	SelectFailed,
	PaletteTooLong,
	ScrollbackInvalid,
	CellSizeInvalid,
	GeometryInvalid,
}

export enum PasteError {
	Unsafe,
	EncodeFailed,
	ModeReadFailed,
}

export struct MouseCodec {
	encoder: GhosttyMouseEncoder;
	event: GhosttyMouseEvent;
}

export interface Mouse {
	codec: MouseCodec | null;
	stale: boolean;
	geometry: MouseGeometry | null;
}

export struct Rgb { r: uint8; g: uint8; b: uint8; }

export enum CellFlag {
	Bold,
	Italic,
	Faint,
	Blink,
	Inverse,
	Invisible,
	Strikethrough,
	Overline,
	Wide,
}

export enum Underline {
	None,
	Single,
	Double,
	Curly,
	Dotted,
	Dashed,
}

export struct Cell {
	cp: uint32;
	extra: uint16;
	fg: Rgb;
	bg: Rgb;
	flags: BitSet<CellFlag>;
	underline: Underline;
	underlineColor: Rgb | null;
}

export struct Row {
	y: int32;
	cells: Vec<Cell>;
	extra: Vec<uint32>;
	selected: RowSpan | null;
}

export interface Painted {
	alternate: boolean;
	rows: Vec<Row>;
	palette: Palette | null;
}

export struct Palette { fg: Rgb; bg: Rgb; cursor: Rgb | null; }

export enum MouseAction {
	Press,
	Release,
	Motion,
}

export struct MouseInput {
	action: MouseAction;
	button: int32;
	mods: BitSet<KeyMod>;
	x: float32;
	y: float32;
}

export struct MouseGeometry {
	cellWidth: int32;
	cellHeight: int32;
	width: int32;
	height: int32;
	padLeft: int32;
	padTop: int32;
	padRight: int32;
	padBottom: int32;
}
