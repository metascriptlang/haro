import { KeyMod } from "../../../../keys/keys";
import { Keybind } from "../../../../input/bindings";
import { Pointer, Spot } from "../../../../input/pointer";
import { Wheel } from "../../../../input/wheel";
import { Held } from "../../../../input/paste";
import { MouseGeometry, Vt } from "../../../../vt/vt";
import { Term, TermError, fit } from "./term";

export enum ControlError {
	VtFailed,
	KeyFailed,
	WriteFailed,
	PasteEncodeFailed,
	PasteUnsafe,
	MouseFailed,
}

export interface Bridge {
	write: (text: string) => void;
	read: (done: (text: string) => void) => void;
	open: (uri: string) => void;
	close: () => void;
}

export struct Hit {
	at: Spot;
	x: float64;
	y: float64;
	scale: float64;
	mods: BitSet<KeyMod>;
	cell: MouseGeometry;
}

export interface Controls {
	pointer: Pointer;
	wheel: Wheel;
	held: Held | null;
	reading: string | null;
	button: int32;
	autoscroll: int32;
	keybinds: Vec<Keybind>;
	consumedKey: string;
}

export function open(this typeof Controls): Controls {
	return {
		pointer: Pointer.open(),
		wheel: Wheel.open(),
		held: null,
		reading: null,
		button: 0,
		autoscroll: 0,
		keybinds: [],
		consumedKey: "",
	};
}

export function vtOf(t: Term): Vt | null {
	const s = t.session;
	if (s === null) { return null; }
	return s.vt;
}

export function holding(this c: Controls): boolean {
	return c.held !== null || c.reading !== null;
}

export function refit(this c: Controls, t: Term, cols: int32, rows: int32): Result<boolean, TermError> {
	const reflows = cols != t.cols;
	const fitted = t.fit(cols, rows);
	const vt = vtOf(t);
	if (fitted.ok && reflows && vt !== null) { c.pointer.clear(vt); }
	return fitted;
}

export function typed(this c: Controls, t: Term): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const bottom = vt.atBottom();
	if (!bottom.ok) { return Result.err(ControlError.VtFailed); }
	if (c.pointer.sel === null && bottom.value) { return Result.ok(false); }
	c.pointer.clear(vt);
	vt.scrollBottom();
	return Result.ok(true);
}
