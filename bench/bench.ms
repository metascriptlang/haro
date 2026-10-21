import { argv } from "std/process";
import { createList } from "../../neon/src/core/list";
import { RowSlot, Styles, applyFrame, empty, spansOf } from "../src/app/frame";
import { GridLine, cellOnRow, line } from "../src/grid/lines";
import { plan } from "../src/screen/plan";
import { Cursor, Vt, palette } from "../src/vt/vt";
import {
	WORKLOAD_NAMES,
	Workload,
	buildWorkload,
	bytesOf,
} from "./workloads";

const CHUNK_BYTES: int32 = 65536;
const DEFAULT_REPS: int32 = 7;
const DEFAULT_FRAME_KIB: int32 = 64;
const FRAME_MS: float64 = 16.0;
const MIB: float64 = 1048576.0;

enum Stage {
	Write,
	Lines,
	Spans,
	Apply,
}

enum BenchError {
	VtCreate,
	Plan,
	Cursor,
	Palette,
}

struct Totals {
	write: float64;
	plan: float64;
	lines: float64;
	spans: float64;
	apply: float64;
	frames: int32;
	rows: int32;
	lineErrors: int32;
	spanCount: int32;
}

struct Cadence {
	frameBytes: int32;
	gapMs: float64;
}

struct Measured {
	median: Totals;
	bestMs: float64;
}

function zero(this typeof Totals): Totals {
	return {
		write: 0.0, plan: 0.0, lines: 0.0, spans: 0.0, apply: 0.0,
		frames: 0, rows: 0, lineErrors: 0, spanCount: 0,
	};
}

function totalMs(this t: Totals): float64 {
	return t.write + t.plan + t.lines + t.spans + t.apply;
}

function stageName(stage: Stage): string {
	return match (stage) {
		Stage.Write => "write",
		Stage.Lines => "plan+lines",
		Stage.Spans => "plan+lines+spans",
		Stage.Apply => "applyFrame",
	};
}

function blankSlots(rows: int32): RowSlot[] {
	const slots: RowSlot[] = [];
	for (let i = 0; i < rows; i++) {
		slots.push({ line: { text: "", runs: [], cursorCell: -1 }, spans: [] });
	}
	return slots;
}

function framePass(
	vt: Vt, stage: Stage, styles: Styles, ref totals: Totals,
): Result<void, BenchError> {
	const planStart: float64 = performance.now();
	const planned = vt.plan();
	if (!planned.ok) { return Result.err(BenchError.Plan); }
	const cursorRead = vt.cursor();
	if (!cursorRead.ok) { return Result.err(BenchError.Cursor); }
	const colors = vt.palette();
	if (!colors.ok) { return Result.err(BenchError.Palette); }
	const linesStart: float64 = performance.now();
	const cursor: Cursor | null = cursorRead.value;
	let built: Vec<GridLine> = [];
	for (const row of planned.value.rows) {
		const l = row.line(cursor.cellOnRow(row.y), colors.value.bg);
		if (l.ok) { built.push(l.value); } else { totals.lineErrors += 1; }
	}
	const spansStart: float64 = performance.now();
	let spanCount = 0;
	if (stage == Stage.Spans) {
		for (const l of built) { spanCount += spansOf(styles, l, colors.value.bg).length as int32; }
	}
	const spansEnd: float64 = performance.now();
	totals.plan += linesStart - planStart;
	totals.lines += spansStart - linesStart;
	totals.spans += spansEnd - spansStart;
	totals.rows += planned.value.rows.length as int32;
	totals.spanCount += spanCount;
	return Result.ok(null);
}

function runPass(w: Workload, stage: Stage, cadence: Cadence): Result<Totals, BenchError> {
	const created = Vt.create(w.cols, w.rows);
	if (!created.ok) { return Result.err(BenchError.VtCreate); }
	const vt = created.value;
	let setup = w.setup;
	let payload = w.payload;
	vt.write(setup);
	if (stage != Stage.Write && !vt.plan().ok) { return Result.err(BenchError.Plan); }
	const styles = Styles.empty();
	const grid = createList<RowSlot>(blankSlots(w.rows));
	let totals = Totals.zero();
	const size = payload.length as int32;
	let at = 0;
	let sinceFrame = 0;
	let lastFrame: float64 = performance.now();
	const paced = cadence.gapMs > 0.0;
	while (at < size) {
		const toFrame = paced ? size - at : cadence.frameBytes - sinceFrame;
		const room = Math.min(toFrame, size - at);
		const n = Math.min(CHUNK_BYTES, room);
		const writeStart: float64 = performance.now();
		vt.write(payload[at..at + n]);
		const writeEnd: float64 = performance.now();
		totals.write += writeEnd - writeStart;
		at += n;
		sinceFrame += n;
		const due = paced
			? writeEnd - lastFrame >= cadence.gapMs
			: sinceFrame >= cadence.frameBytes;
		if (!(due || at == size)) { continue; }
		sinceFrame = 0;
		if (stage == Stage.Write) { continue; }
		totals.frames += 1;
		if (stage == Stage.Apply) {
			const applied = applyFrame(grid, styles, vt);
			totals.apply += performance.now() - writeEnd;
			if (!applied.ok) { totals.lineErrors += 1; }
		} else {
			const _framed = try framePass(vt, stage, styles, totals);
		}
		lastFrame = performance.now();
	}
	vt.free();
	return Result.ok(totals);
}

function measure(
	w: Workload, stage: Stage, reps: int32, cadence: Cadence,
): Result<Measured, BenchError> {
	const _warmUp = try runPass(w, stage, cadence);
	let samples: Vec<Totals> = [];
	for (let i = 0; i < reps; i++) { samples.push(try runPass(w, stage, cadence)); }
	for (let i = 1; i < reps; i++) {
		for (let j = i; j > 0 && samples[j - 1].totalMs() > samples[j].totalMs(); j--) {
			const t = samples[j];
			samples[j] = samples[j - 1];
			samples[j - 1] = t;
		}
	}
	return Result.ok({ median: samples[reps / 2], bestMs: samples[0].totalMs() });
}

function fixed(value: float64, places: int32): string {
	let scale = 1;
	for (let i = 0; i < places; i++) { scale *= 10; }
	const scaled = (value * (scale as float64) + 0.5) as int64;
	const whole = scaled / (scale as int64);
	const fraction = `${scaled % (scale as int64)}`;
	const padded = "0".repeat(places - (fraction.byteLength as int32)) + fraction;
	return places == 0 ? `${whole}` : `${whole}.${padded}`;
}

function pad(text: string, width: int32): string {
	return " ".repeat(width - (text.byteLength as int32)) + text;
}

function describe(w: Workload, stage: Stage, m: Measured): string {
	const t = m.median;
	const ms = t.totalMs();
	const bytes = w.payload.length as float64;
	const mibPerSecond = bytes / MIB / (ms / 1000.0);
	const frameMs = ms - t.write;
	const nsPerRow = t.rows > 0 && stage != Stage.Write
		? fixed(frameMs * 1000000.0 / (t.rows as float64), 0)
		: "-";
	let split = `write ${fixed(t.write, 2)}`;
	if (stage == Stage.Lines || stage == Stage.Spans) {
		split += ` plan ${fixed(t.plan, 2)} lines ${fixed(t.lines, 2)}`;
	}
	if (stage == Stage.Spans) { split += ` spans ${fixed(t.spans, 2)}`; }
	if (stage == Stage.Apply) { split += ` apply ${fixed(t.apply, 2)}`; }
	const failures = t.lineErrors > 0 ? ` lineErrors ${t.lineErrors}` : "";
	return (
		`${pad(w.name, 30)} ${pad(stageName(stage), 17)} ${pad(fixed(bytes / MIB, 2), 6)} MiB ` +
		`${pad(`${t.frames}`, 5)} frames ${pad(`${t.rows}`, 6)} rows ` +
		`${pad(fixed(ms, 2), 9)} ms (best ${fixed(m.bestMs, 2)}) ` +
		`${pad(fixed(mibPerSecond, 1), 8)} MiB/s ${pad(nsPerRow, 8)} ns/row ` +
		`[${split} ms]${failures}`
	);
}

function flagValue(flag: string): string | null {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == flag) { return argv[i + 1]; }
	}
	return null;
}

function hasFlag(flag: string): boolean {
	for (const arg of argv) {
		if (arg == flag) { return true; }
	}
	return false;
}

function intOption(flag: string, fallback: int32): int32 {
	const text = flagValue(flag);
	if (text === null) { return fallback; }
	return text.parseInt() as int32;
}

function selectedWorkloads(): string[] {
	const only = flagValue("--only");
	if (only === null) { return WORKLOAD_NAMES; }
	return only.split(",");
}

function main(): int32 {
	if (hasFlag("--list")) {
		for (const name of WORKLOAD_NAMES) { console.log(name); }
		return 0;
	}
	const reps = intOption("--reps", DEFAULT_REPS);
	const paced = hasFlag("--paced");
	const cadence: Cadence = {
		frameBytes: intOption("--frame-kib", DEFAULT_FRAME_KIB) * 1024,
		gapMs: paced ? FRAME_MS : 0.0,
	};
	const stages = [Stage.Write, Stage.Lines, Stage.Spans, Stage.Apply];
	const frames = paced
		? `a frame every ${fixed(FRAME_MS, 0)} ms, one apply per window frame (src/app/pace.ms)`
		: `a frame every ${cadence.frameBytes / 1024} KiB`;
	console.log(`# haroBench reps=${reps} (median, plus 1 warm-up), ${frames}`);
	console.log(`# the vt is written ${CHUNK_BYTES} B at a time`);
	for (const name of selectedWorkloads()) {
		const built = buildWorkload(name);
		if (!built.ok) {
			console.log(`unknown workload ${name}; --list names them`);
			return 2;
		}
		const w = built.value;
		console.log(`# ${w.name}: grid ${w.cols}x${w.rows}`);
		for (const stage of stages) {
			const m = measure(w, stage, reps, cadence);
			if (!m.ok) {
				console.log(`${w.name} ${stageName(stage)}: ${m.error.toString()}`);
				return 1;
			}
			console.log(describe(w, stage, m.value));
		}
	}
	return 0;
}

function once(): Cadence {
	return { frameBytes: 65536, gapMs: 0.0 };
}

function tiny(cols: int32, rows: int32, text: string): Workload {
	return { name: "tiny", cols: cols, rows: rows, setup: [], payload: bytesOf(text) };
}

test "a write pass plans no frames and no rows" {
	const r = runPass(tiny(10, 3, "hello\nworld"), Stage.Write, once());
	assert r.ok;
	if (r.ok) {
		assert r.value.frames == 0;
		assert r.value.rows == 0;
		assert r.value.write > 0.0;
	}
}

test "a lines pass reads the rows the bytes dirtied and splits the time" {
	const r = runPass(tiny(10, 3, "hello\nworld"), Stage.Lines, once());
	assert r.ok;
	if (r.ok) {
		assert r.value.frames == 1;
		assert r.value.rows == 2;
		assert r.value.lineErrors == 0;
		assert r.value.spanCount == 0;
		assert r.value.plan > 0.0 && r.value.lines > 0.0;
	}
}

test "a spans pass turns each styled stretch of a row into a span" {
	const r = runPass(tiny(10, 3, "a\x1b[31mb\x1b[0mc"), Stage.Spans, once());
	assert r.ok;
	if (r.ok) {
		assert r.value.rows == 1;
		assert r.value.spanCount == 3;
		assert r.value.lineErrors == 0;
	}
}

test "a frame every few bytes plans a frame each time" {
	const every: Cadence = { frameBytes: 5, gapMs: 0.0 };
	const r = runPass(tiny(10, 3, "ab\r\ncd\r\nef\r\ngh\r\n"), Stage.Lines, every);
	assert r.ok;
	if (r.ok) { assert r.value.frames == 4; }
}

test "a paced pass still ends on a frame" {
	const paced: Cadence = { frameBytes: 0, gapMs: 1000000.0 };
	const r = runPass(tiny(10, 3, "hello\nworld"), Stage.Lines, paced);
	assert r.ok;
	if (r.ok) {
		assert r.value.frames == 1;
		assert r.value.rows == 2;
	}
}

test "a code point above U+FFFF is a line like any other" {
	const r = runPass(tiny(10, 3, "a😀"), Stage.Spans, once());
	assert r.ok;
	if (r.ok) {
		assert r.value.rows == 1;
		assert r.value.lineErrors == 0;
		assert r.value.spanCount == 1;
	}
}

test "applyFrame runs headless on the same bytes" {
	const r = runPass(tiny(10, 3, "hello\nworld"), Stage.Apply, once());
	assert r.ok;
	if (r.ok) {
		assert r.value.frames == 1;
		assert r.value.lineErrors == 0;
		assert r.value.apply > 0.0;
	}
}

test "a measured stage describes itself on one line" {
	const m = measure(tiny(10, 3, "hello\nworld"), Stage.Spans, 3, once());
	assert m.ok;
	if (m.ok) {
		const text = describe(tiny(10, 3, "hello\nworld"), Stage.Spans, m.value);
		assert text.includes("plan+lines+spans") && text.includes("MiB/s");
		assert text.includes("spans ");
		assert !text.includes("lineErrors");
	}
}

test "fixed keeps the places asked and leading zeros" {
	assert fixed(12.3, 2) == "12.30";
	assert fixed(0.04, 2) == "0.04";
	assert fixed(7.6, 0) == "8";
}

when (!testBuild) {
	process.exit(main());
}
