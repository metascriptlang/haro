import { Marked, Point } from "../select/select";
import {
	Vt,
	VtError,
	create,
	free,
	lines,
} from "./vt";

export function withVt(cols: int32, rows: int32, body: (vt: Vt) => void): boolean {
	const created = Vt.create(cols, rows);
	if (!created.ok) { return false; }
	body(created.value);
	created.value.free();
	return true;
}

export function ascii(bytes: Span<uint8>): string {
	let text = "";
	for (const b of bytes) { text += String.fromCharCode(b as int32); }
	return text;
}

export function shown(r: Result<string | null, VtError>): string {
	if (!r.ok) { return "<failed>"; }
	const got = r.value;
	if (got !== null) { return got; }
	return "<none>";
}

export function numberedLines(count: int32): string {
	let text = "r0";
	for (let i = 1; i < count; i++) { text += `\r\nr${i}`; }
	return text;
}

export function linefeedLines(count: int32): string {
	let text = "";
	for (let i = 0; i < count; i++) { text += `\nq${i}`; }
	return text;
}

export function topLine(vt: Vt): string {
	const lines = vt.lines();
	if (lines.ok) { return lines.value[0]; }
	return "<unreadable>";
}

export function at(row: int32, col: int32): Point {
	return { row: row, col: col };
}

export function marked(r0: int32, c0: int32, r1: int32, c1: int32): Marked {
	return { range: { start: at(r0, c0), end: at(r1, c1) }, block: false };
}
