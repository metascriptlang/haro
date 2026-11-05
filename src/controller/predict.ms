import { Cell, CellFlag, Cursor, Row, Underline } from "../vt/vt";

export const SHOW_AT_RTT_MS: float64 = 30;
export const HIDE_AT_RTT_MS: float64 = 20;
const GLITCH_MS: float64 = 250;
const FIRST_PRINTABLE: uint8 = 0x20;
const LAST_PRINTABLE: uint8 = 0x7e;

export enum Predicting {
	Auto,
	On,
	Off,
}

export function predicts(mode: Predicting, rttMs: float64 | null, was: boolean): boolean {
	if (mode == Predicting.Off || rttMs === null) { return false; }
	if (mode == Predicting.On) { return true; }
	return was ? rttMs > HIDE_AT_RTT_MS : rttMs >= SHOW_AT_RTT_MS;
}

export struct Guess {
	x: int32;
	y: int32;
	cp: uint32;
	at: float64;
	epoch: int32;
}

export struct Overlay {
	x: int32;
	text: string;
}

export interface Ahead {
	enabled: boolean;
	unseen: boolean;
	rttMs: float64;
	guesses: Vec<Guess>;
	epoch: int32;
	confirmed: int32;
	waiting: boolean;
	heard: boolean;
	misses: int32;
}

export function idle(this typeof Ahead): Ahead {
	return {
		enabled: false,
		unseen: false,
		rttMs: 0,
		guesses: [],
		epoch: 1,
		confirmed: 0,
		waiting: false,
		heard: false,
		misses: 0,
	};
}

function printable(bytes: Readonly<Span<uint8>>): boolean {
	if (bytes.length == 0) { return false; }
	for (const b of bytes) {
		if (b < FIRST_PRINTABLE || b > LAST_PRINTABLE) { return false; }
	}
	return true;
}

export function drop(this a: Ahead): void {
	a.guesses = [];
	a.epoch += 1;
}

function missed(this a: Ahead): void {
	a.misses += 1;
	a.drop();
}

export function predict(this a: Ahead, enabled: boolean, rttMs: float64): void {
	a.enabled = enabled;
	a.rttMs = rttMs;
	if (!enabled) { a.drop(); }
}

export function hide(this a: Ahead, unseen: boolean): void {
	a.unseen = unseen;
	if (unseen) { a.drop(); }
}

export function heardOutput(this a: Ahead): void {
	a.heard = true;
}

export function typed(
	this a: Ahead,
	bytes: Readonly<Span<uint8>>,
	cursor: Cursor | null,
	cols: int32,
	alternate: boolean,
	now: float64,
): void {
	if (bytes.length == 0) { return; }
	if (!a.enabled || a.unseen || alternate || cursor === null) {
		a.drop();
		return;
	}
	if (!printable(bytes)) {
		a.epoch += 1;
		a.waiting = true;
		a.heard = false;
		return;
	}
	if (a.waiting) { return; }
	for (const b of bytes) {
		const last = a.guesses.length > 0 ? a.guesses[a.guesses.length - 1] : null;
		const x = last === null ? cursor.x : last.x + 1;
		const y = last === null ? cursor.y : last.y;
		if (x >= cols) {
			a.drop();
			return;
		}
		a.guesses.push({ x: x, y: y, cp: b as uint32, at: now, epoch: a.epoch });
	}
}

function patienceMs(this a: Ahead): float64 {
	return GLITCH_MS + 2 * a.rttMs;
}

export function settle(this a: Ahead, rows: Vec<Row>, cursor: Cursor | null, alternate: boolean, now: float64): void {
	if (a.guesses.length > 0 && (alternate || cursor === null)) {
		a.drop();
		return;
	}
	let kept: Vec<Guess> = [];
	for (const g of a.guesses) {
		if (cursor === null || g.y >= rows.length || g.x >= rows[g.y].cells.length) {
			a.missed();
			return;
		}
		const passed = cursor.y != g.y || cursor.x > g.x;
		const same = rows[g.y].cells[g.x].cp == g.cp;
		if (passed && same) {
			a.confirmed = Math.max(a.confirmed, g.epoch);
		} else if (passed || now - g.at > a.patienceMs()) {
			a.missed();
			return;
		} else {
			kept.push(g);
		}
	}
	a.guesses = kept;
	if (a.waiting && a.heard && a.guesses.length == 0) { a.waiting = false; }
}

function shown(this a: Ahead, g: Guess): boolean {
	return a.enabled && g.epoch <= a.confirmed;
}

export function overlayAt(this a: Ahead, y: int32): Overlay | null {
	let x: int32 = -1;
	let text = "";
	for (const g of a.guesses) {
		if (g.y != y || !a.shown(g)) { continue; }
		if (x < 0) { x = g.x; }
		text += String.fromCharCode(g.cp as int32);
	}
	return x < 0 ? null : { x: x, text: text };
}

export function cursorAhead(this a: Ahead, cursor: Cursor | null, cols: int32): Cursor | null {
	if (cursor === null) { return null; }
	const over = a.overlayAt(cursor.y);
	if (over === null) { return cursor; }
	const x = over.x + over.text.length as int32;
	return x < cols ? { ...cursor, x: x } : cursor;
}

function plain(cell: Cell): boolean {
	return cell.extra == 0 && !cell.flags.has(CellFlag.Wide) && !cell.flags.has(CellFlag.Invisible);
}

export function overlaid(this row: Row, over: Overlay | null): Row {
	if (over === null) { return row; }
	if (over.x + (over.text.length as int32) > row.cells.length) { return row; }
	for (let i: int32 = 0; i < (over.text.length as int32); i++) {
		const cell = row.cells[over.x + i];
		if (!plain(cell) || over.x + i > 0 && row.cells[over.x + i - 1].flags.has(CellFlag.Wide)) { return row; }
	}
	let cells: Vec<Cell> = [];
	for (const c of row.cells) { cells.push(c); }
	for (let i: int32 = 0; i < (over.text.length as int32); i++) {
		const was = cells[over.x + i];
		cells[over.x + i] = { ...was, cp: over.text.charCodeAt(i) as uint32, underline: Underline.Single };
	}
	return { y: row.y, cells: cells, extra: row.extra, selected: row.selected };
}

const INK: Cell = {
	cp: 0x20,
	extra: 0,
	fg: { r: 200, g: 200, b: 200 },
	bg: { r: 0, g: 0, b: 0 },
	flags: 0 as BitSet<CellFlag>,
	underline: Underline.None,
	underlineColor: null,
};

function rowOf(y: int32, text: string, cols: int32): Row {
	let cells: Vec<Cell> = [];
	for (let x: int32 = 0; x < cols; x++) {
		cells.push({ ...INK, cp: x < (text.length as int32) ? text.charCodeAt(x) as uint32 : 0x20 });
	}
	return { y: y, cells: cells, extra: [], selected: null };
}

function screenOf(text: string): Vec<Row> {
	let rows: Vec<Row> = [];
	rows.push(rowOf(0, text, 20));
	rows.push(rowOf(1, "", 20));
	return rows;
}

function at(x: int32, y: int32): Cursor | null {
	return { x: x, y: y, wide: false };
}

function key(a: Ahead, text: string, x: int32, now: float64): void {
	a.typed(text.asBytes(), at(x, 0), 20, false, now);
}

function shows(a: Ahead): string {
	const over = a.overlayAt(0);
	return over === null ? "" : `${over.x}:${over.text}`;
}

function confirmedAhead(): Ahead {
	const a = Ahead.idle();
	a.predict(true, 100);
	key(a, "a", 2, 0);
	a.settle(screenOf("$ a"), at(3, 0), false, 50);
	return a;
}

test "auto prediction starts at 30 ms of round trip and stops only at 20 ms, on and off ignore it" {
	assert !predicts(Predicting.Auto, 25, false);
	assert predicts(Predicting.Auto, 30, false);
	assert predicts(Predicting.Auto, 25, true);
	assert !predicts(Predicting.Auto, 20, true);
	assert predicts(Predicting.On, 1, false);
	assert !predicts(Predicting.On, null, true);
	assert !predicts(Predicting.Off, 300, true);
}

test "a key in a fresh epoch waits for its echo, then the next keys show at once until their echo confirms them" {
	const a = Ahead.idle();
	a.predict(true, 100);
	key(a, "a", 2, 0);
	assert a.overlayAt(0) === null;
	a.settle(screenOf("$ a"), at(3, 0), false, 50);
	assert a.guesses.length == 0 && a.overlayAt(0) === null;
	key(a, "bc", 3, 60);
	assert shows(a) == "3:bc", shows(a);
	assert a.cursorAhead(at(3, 0), 20)?.x == 5;
	a.settle(screenOf("$ ab"), at(4, 0), false, 160);
	assert shows(a) == "4:c", shows(a);
	a.settle(screenOf("$ abc"), at(5, 0), false, 170);
	assert a.overlayAt(0) === null && a.misses == 0;
}

test "a wrong prediction is dropped whole, and the keys after it wait for an echo again" {
	const a = confirmedAhead();
	key(a, "xy", 3, 60);
	assert shows(a) == "3:xy", shows(a);
	a.settle(screenOf("$ aQ"), at(4, 0), false, 100);
	assert a.guesses.length == 0 && a.overlayAt(0) === null && a.misses == 1;
	key(a, "z", 4, 110);
	assert a.overlayAt(0) === null;
}

test "a prediction no echo answers is dropped after its patience" {
	const a = confirmedAhead();
	key(a, "p", 3, 60);
	a.settle(screenOf("$ a"), at(3, 0), false, 100);
	assert shows(a) == "3:p", shows(a);
	a.settle(screenOf("$ a"), at(3, 0), false, 60 + 250 + 200 + 1);
	assert a.overlayAt(0) === null && a.misses == 1;
}

test "nothing is predicted at the alternate screen, while the pane reads unseen, for control keys or until their echo settles" {
	const a = confirmedAhead();
	a.typed("q".asBytes(), at(3, 0), 20, true, 60);
	assert a.guesses.length == 0;
	a.hide(true);
	key(a, "q", 3, 61);
	assert a.guesses.length == 0;
	a.hide(false);
	key(a, "\r", 3, 62);
	key(a, "q", 3, 63);
	assert a.guesses.length == 0 && a.waiting;
	a.heardOutput();
	a.settle(screenOf("$ a"), at(0, 1), false, 150);
	assert !a.waiting;
	key(a, "q", 3, 160);
	assert a.guesses.length == 1 && a.overlayAt(0) === null;
	a.predict(false, 100);
	assert a.guesses.length == 0;
	key(a, "q", 3, 170);
	assert a.guesses.length == 0;
}

test "an overlay underlines its keys over a copy of the row, and leaves a row with wide cells as it is" {
	const row = rowOf(0, "$ ", 20);
	const over = row.overlaid({ x: 2, text: "ls" });
	assert over.cells[2].cp == 0x6c && over.cells[3].cp == 0x73;
	assert over.cells[2].underline == Underline.Single;
	assert row.cells[2].cp == 0x20 && row.cells[2].underline == Underline.None;
	let wide = rowOf(0, "$ ", 20);
	wide.cells[2] = { ...wide.cells[2], flags: (0 as BitSet<CellFlag>).incl(CellFlag.Wide) };
	assert wide.overlaid({ x: 2, text: "l" }).cells[2].cp == 0x20;
}
