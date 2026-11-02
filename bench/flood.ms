import { argv, exit } from "std/process";
import { NativePty, spawn } from "../src/pty/pty";
import { Pty, PtyError } from "../src/pty/transport";
import { send } from "../src/session/session";
import { Term, drain, openTerm, pumpFrame, shutdown } from "../src/controller/term";

const COLS: int32 = 120;
const ROWS: int32 = 40;
const FRAME_PERIOD_MS: float64 = 8.33;
const FLOOD_MIB: int32 = 64;
const LINE = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" +
	"0123456789abcdefg";
const FLOOD_BEFORE_INTERRUPT_MS: float64 = 500;
const QUIET_AFTER_INTERRUPT_MS: float64 = 3000;
const REPS: int32 = 5;
const MIB: float64 = 1048576.0;
const INTERRUPT: Vec<uint8> = [0x03];

interface Meter {
	bytes: int64;
	firstAt: float64;
	lastAt: float64;
}

struct Waits {
	keys: Vec<float64>;
	slices: Vec<float64>;
	frames: int32;
}

function counted(native: Pty, meter: Meter): Pty {
	return {
		...native,
		read: (buf: Span<uint8>): Result<int32, PtyError> => {
			const r = native.read(buf);
			if (r.ok && r.value > 0) {
				const at = performance.now();
				if (meter.bytes == 0) { meter.firstAt = at; }
				meter.bytes += r.value as int64;
				meter.lastAt = at;
			}
			return r;
		},
	};
}

function spin(ms: float64): void {
	const until = performance.now() + ms;
	while (performance.now() < until) {}
}

function nextGap(ref seed: uint32): float64 {
	seed = seed * 1664525 + 1013904223;
	const spread = ((seed >> 8) % 9000) as float64;
	return 2.0 + spread / 1000.0;
}

function percentile(values: Vec<float64>, p: float64): float64 {
	if (values.length == 0) { return 0; }
	let sorted = values.slice();
	sorted.sort((a: float64, b: float64): number => a - b);
	const at = Math.min(sorted.length - 1, (p * sorted.length as float64) as int32);
	return sorted[at];
}

function appLoop(
	t: Term,
	frameMs: float64,
	stop: () => boolean,
): Result<Waits, string> {
	let waits: Waits = { keys: [], slices: [], frames: 0 };
	let seed: uint32 = 12345;
	let keyDue = performance.now() + nextGap(seed);
	let nextFrame = performance.now() + FRAME_PERIOD_MS;
	while (t.alive && !stop()) {
		const now = performance.now();
		if (now >= keyDue) {
			waits.keys.push(now - keyDue);
			keyDue = now + nextGap(seed);
		}
		const began = performance.now();
		if (now >= nextFrame) {
			const framed = t.pumpFrame();
			if (!framed.ok) { return Result.err(`frame: ${framed.error.toString()}`); }
			spin(frameMs);
			waits.frames += 1;
			nextFrame = Math.max(nextFrame + FRAME_PERIOD_MS, performance.now());
		} else {
			const s = t.session;
			if (s === null) { return Result.err("no session"); }
			const ready = s.pty.wait(1);
			if (!ready.ok || !ready.value) { continue; }
			const drained = t.drain();
			if (!drained.ok) { return Result.err(`drain: ${drained.error.toString()}`); }
		}
		waits.slices.push(performance.now() - began);
	}
	return Result.ok(waits);
}

function onTerm(
	command: string,
	meter: Meter,
	body: (t: Term) => Result<void, string>,
): Result<void, string> {
	const opener = (cols: int32, rows: int32): Result<Pty, PtyError> => {
		const native = NativePty.spawn(command, cols, rows);
		if (!native.ok) { return Result.err(native.error); }
		return Result.ok(counted(native.value, meter));
	};
	const opened = openTerm(opener);
	if (!opened.ok) { return Result.err(`open: ${opened.error.toString()}`); }
	const t = opened.value;
	defer t.shutdown();
	const fitted = t.fit(COLS, ROWS);
	if (!fitted.ok) { return Result.err(`fit: ${fitted.error.toString()}`); }
	return body(t);
}

function describeWaits(w: Waits): string {
	return `key wait p50 ${percentile(w.keys, 0.5).toFixed(2)} ` +
		`p99 ${percentile(w.keys, 0.99).toFixed(2)} ` +
		`max ${percentile(w.keys, 1.0).toFixed(2)} ms (n=${w.keys.length}); ` +
		`busy slice p99 ${percentile(w.slices, 0.99).toFixed(2)} ` +
		`max ${percentile(w.slices, 1.0).toFixed(2)} ms; frames ${w.frames}`;
}

function throughput(frameMs: float64): Result<float64, string> {
	let meter: Meter = { bytes: 0, firstAt: 0, lastAt: 0 };
	let mibPerSecond: float64 = 0;
	const flood = `yes ${LINE} | head -c ${FLOOD_MIB * 1048576}`;
	try onTerm(flood, meter, (t: Term): Result<void, string> => {
		const waits = try appLoop(t, frameMs, (): boolean => false);
		const seconds = (meter.lastAt - meter.firstAt) / 1000.0;
		mibPerSecond = (meter.bytes as float64) / MIB / seconds;
		console.log(`flood: ${(meter.bytes as float64 / MIB).toFixed(1)} MiB ` +
			`${mibPerSecond.toFixed(1)} MiB/s; ${describeWaits(waits)}`);
		return Result.ok(null);
	});
	return Result.ok(mibPerSecond);
}

function interrupt(frameMs: float64): Result<void, string> {
	let meter: Meter = { bytes: 0, firstAt: 0, lastAt: 0 };
	return onTerm(`yes ${LINE}`, meter, (t: Term): Result<void, string> => {
		const began = performance.now();
		const _flooded = try appLoop(t, frameMs, (): boolean => {
			return performance.now() - began >= FLOOD_BEFORE_INTERRUPT_MS;
		});
		const s = t.session;
		if (s === null) { return Result.err("no session"); }
		const sent = s.send(INTERRUPT);
		if (!sent.ok) { return Result.err(`send: ${sent.error.toString()}`); }
		const sentAt = performance.now();
		const before = meter.bytes;
		const waits = try appLoop(t, frameMs, (): boolean => {
			return performance.now() - meter.lastAt >= QUIET_AFTER_INTERRUPT_MS;
		});
		const stale = meter.bytes - before;
		console.log(`interrupt: ${(stale as float64 / 1024.0).toFixed(0)} KiB ` +
			`after ^C, last byte ${(meter.lastAt - sentAt).toFixed(2)} ms after it; ` +
			describeWaits(waits));
		return Result.ok(null);
	});
}

function flagNumber(flag: string, fallback: float64): float64 {
	for (let i = 1; i + 1 < argv.length; i++) {
		if (argv[i] == flag) { return parseFloat(argv[i + 1]); }
	}
	return fallback;
}

function run(): Result<void, string> {
	const frameMs = flagNumber("--frame-ms", 3.0);
	let rates: Vec<float64> = [];
	for (let i = 0; i < REPS; i++) { rates.push(try throughput(frameMs)); }
	console.log(`flood median ${percentile(rates, 0.5).toFixed(1)} MiB/s ` +
		`(frame ${frameMs} ms every ${FRAME_PERIOD_MS} ms)`);
	for (let i = 0; i < REPS; i++) { try interrupt(frameMs); }
	return Result.ok(null);
}

when (!testBuild) {
	const ran = run();
	if (!ran.ok) {
		console.log(`flood bench failed: ${ran.error}`);
		exit(1);
	}
}
