import { writeFile } from "std/fs";
import { env } from "std/process";
import { PaneId } from "../workspace/tree";
import { Connection } from "./transport";

const ECHO_BYTES: int32 = 16;
const MAX_ROWS: int32 = 200000;
const UNSET: float64 = -1;

struct InputRow {
	pane: PaneId;
	ordinal: int32;
	receivedAt: float64;
	wroteAt: float64;
}

struct OutputRow {
	pane: PaneId;
	seq: int64;
	readAt: float64;
	handedAt: float64;
	sentAt: float64;
	end: int64;
}

struct JumpRow {
	at: float64;
	pane: PaneId;
	queued: int64;
}

struct PaneCount {
	pane: PaneId;
	count: int32;
}

export class Trace {
	readonly path: string;
	inputs: Vec<InputRow> = [];
	outputs: Vec<OutputRow> = [];
	jumps: Vec<JumpRow> = [];
	counts: Vec<PaneCount> = [];
	unsent: int32 = 0;
	followed: Connection | null = null;

	constructor(path: string) { this.path = path; }
}

export function tracing(): Trace | null {
	const path = env.get("HARO_SERVER_TRACE");
	return path == "" ? null : new Trace(path);
}

function ordinalOf(this t: Trace, pane: PaneId): int32 {
	for (let i = 0; i < t.counts.length; i++) {
		if (t.counts[i].pane == pane) {
			t.counts[i].count += 1;
			return t.counts[i].count - 1;
		}
	}
	t.counts.push({ pane: pane, count: 1 });
	return 0;
}

export function received(this t: Trace, pane: PaneId): int32 {
	const ordinal = t.ordinalOf(pane);
	if (t.inputs.length >= MAX_ROWS) { return -1; }
	t.inputs.push({ pane: pane, ordinal: ordinal, receivedAt: performance.now(), wroteAt: UNSET });
	return t.inputs.length - 1;
}

export function wrote(this t: Trace, row: int32, at: float64): void {
	if (row >= 0) { t.inputs[row].wroteAt = at; }
}

export function follow(this t: Trace, conn: Connection): void {
	if (t.followed !== null) { return; }
	t.followed = conn;
	conn.watchSent((total: int64): void => { t.sentUpTo(total); });
}

function sentUpTo(this t: Trace, total: int64): void {
	const at = performance.now();
	while (t.unsent < t.outputs.length && t.outputs[t.unsent].end <= total) {
		t.outputs[t.unsent].sentAt = at;
		t.unsent += 1;
	}
}

export function handed(this t: Trace, conn: Connection, pane: PaneId, seq: int64, readAt: float64, bytes: int32): void {
	if (conn !== t.followed || bytes > ECHO_BYTES || t.outputs.length >= MAX_ROWS) { return; }
	t.outputs.push({
		pane: pane,
		seq: seq,
		readAt: readAt,
		handedAt: performance.now(),
		sentAt: UNSET,
		end: conn.sentBytes + conn.queued(),
	});
}

export function jumped(this t: Trace, pane: PaneId, queued: int64): void {
	if (t.jumps.length < MAX_ROWS) { t.jumps.push({ at: performance.now(), pane: pane, queued: queued }); }
}

export function save(this t: Trace): void {
	const lines: string[] = [];
	for (const r of t.inputs) {
		lines.push(`in\t${r.pane as int32}\t${r.ordinal}\t${r.receivedAt.toFixed(3)}\t${r.wroteAt.toFixed(3)}`);
	}
	for (const r of t.outputs) {
		lines.push(`out\t${r.pane as int32}\t${r.seq}\t${r.readAt.toFixed(3)}\t${r.handedAt.toFixed(3)}\t${r.sentAt.toFixed(3)}`);
	}
	for (const r of t.jumps) { lines.push(`jump\t${r.pane as int32}\t${r.at.toFixed(3)}\t${r.queued}`); }
	const _saved = writeFile(t.path, `${lines.join("\n")}\n`);
}
