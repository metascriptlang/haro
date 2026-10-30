import { fromCodePoint } from "std/core/string";
import { Unit } from "../select/select";
import {
	CellFlag,
	Row,
	Vt,
	VtError,
	isUnicodeScalar,
	linkAt,
	rows,
	scrollOffset,
	unitAt,
} from "../vt/vt";
import { urlAt } from "./links";

export struct Stretch {
	row: int32;
	from: int32;
	to: int32;
}

export struct Link {
	uri: string;
	stretches: Vec<Stretch>;
}

struct Walked {
	text: string;
	unitOf: Vec<int32>;
}

function walk(this row: Row, wrapped: boolean): Result<Walked, VtError> {
	let text = "";
	let unitOf: Vec<int32> = [];
	let extraAt = 0;
	const last = (row.cells.length as int32) - 1;
	for (let i = 0; i <= last; i++) {
		unitOf.push(text.length as int32);
		const cell = row.cells[i];
		const extra = cell.extra as int32;
		const extraStart = extraAt;
		extraAt += extra;
		if (cell.cp == 0 && i > 0 && row.cells[i - 1].flags.has(CellFlag.Wide)) { continue; }
		if (cell.cp == 0) {
			if (!(wrapped && i == last)) { text += " "; }
			continue;
		}
		if (cell.flags.has(CellFlag.Invisible)) {
			text += cell.flags.has(CellFlag.Wide) ? "  " : " ";
			continue;
		}
		for (let k = 0; k <= extra; k++) {
			const cp = k == 0 ? cell.cp : row.extra[extraStart + k - 1];
			if (!isUnicodeScalar(cp)) { return Result.err(VtError.CodepointInvalid); }
			text += fromCodePoint(cp as number);
		}
	}
	unitOf.push(text.length as int32);
	return Result.ok({ text: text, unitOf: unitOf });
}

function osc8(vt: Vt, all: Vec<Row>, uri: string, col: int32, row: int32): Result<Link, VtError> {
	const walked = try all[row].walk(false);
	const width = all[row].cells.length as int32;
	let from = col;
	while (from > 0 && (try vt.linkAt(from - 1, row)) == uri) { from--; }
	let to = col;
	while (to + 1 < width && (try vt.linkAt(to + 1, row)) == uri) { to++; }
	const stretch: Stretch = { row: row, from: walked.unitOf[from], to: walked.unitOf[to + 1] };
	return Result.ok({ uri: uri, stretches: [stretch] });
}

function plain(vt: Vt, all: Vec<Row>, col: int32, row: int32): Result<Link | null, VtError> {
	const top = try vt.scrollOffset();
	const line = try vt.unitAt(Unit.Line, { row: top + row, col: col });
	const first = Math.min(Math.max(line.start.row - top, 0), row) as int32;
	const end = Math.max(Math.min(line.end.row - top, (all.length as int32) - 1), row) as int32;
	let text = "";
	let walks: Vec<Walked> = [];
	let bases: Vec<int32> = [];
	for (let y = first; y <= end; y++) {
		const walked = try all[y].walk(y < end);
		bases.push(text.length as int32);
		text += walked.text;
		walks.push(walked);
	}
	const at = bases[row - first] + walks[row - first].unitOf[col];
	const span = urlAt(text, at);
	if (span === null) { return Result.ok(null); }
	let stretches: Vec<Stretch> = [];
	for (let k = 0; k < walks.length; k++) {
		const base = bases[k];
		const from = Math.max(span.from, base) as int32;
		const to = Math.min(span.to, base + (walks[k].text.length as int32)) as int32;
		if (from < to) { stretches.push({ row: first + k, from: from - base, to: to - base }); }
	}
	const found: Link | null = { uri: text.slice(span.from, span.to), stretches: stretches };
	return Result.ok(found);
}

export function linkUnder(this vt: Vt, col: int32, row: int32): Result<Link | null, VtError> {
	const all = try vt.rows();
	if (row < 0 || row >= (all.length as int32) || col < 0 || col >= (all[row].cells.length as int32)) {
		return Result.ok(null);
	}
	const hyperlink = try vt.linkAt(col, row);
	if (hyperlink !== null) {
		const found: Link | null = try osc8(vt, all, hyperlink, col, row);
		return Result.ok(found);
	}
	return plain(vt, all, col, row);
}
