import { Mark } from "../controller/mark";

export struct Tally {
	refreshes: int64;
	more: int64;
	held: int64;
	rows: int64;
	scrolled: int64;
	chars: int64;
	echoes: Vec<float64>;
	settles: Vec<float64>;
}

function zero(this typeof Tally): Tally {
	return {
		refreshes: 0,
		more: 0,
		held: 0,
		rows: 0,
		scrolled: 0,
		chars: 0,
		echoes: [],
		settles: [],
	};
}

export interface Stats {
	tally: Tally;
	keyAt: float64;
	wakeAt: float64;
	marks: Vec<Mark>;
	recording: boolean;
}

export function empty(this typeof Stats): Stats {
	return { tally: Tally.zero(), keyAt: -1, wakeAt: -1, marks: [], recording: false };
}

function marked(this s: Stats, name: string): boolean {
	for (const m of s.marks) {
		if (m.name == name) { return true; }
	}
	return false;
}

export function mark(this s: Stats, name: string, at: float64): void {
	if (s.marked(name)) { return; }
	s.marks.push({ name: name, at: at });
}

export function launched(this s: Stats): boolean {
	return s.marked("painted");
}

export function launchLine(this s: Stats): string {
	let out = "";
	for (const m of s.marks) { out += `${out == "" ? "" : " "}${m.name}=${m.at}`; }
	return out;
}

export function noteKey(this s: Stats, at: float64): void {
	if (s.recording && s.keyAt < 0) { s.keyAt = at; }
}

export function noteWake(this s: Stats, at: float64): void {
	s.mark("output", Date.now());
	s.wakeAt = at;
}

export function noteApplied(
	this s: Stats,
	rows: int32,
	scrolled: int32,
	chars: int32,
	at: float64,
): void {
	s.tally.rows += rows;
	s.tally.scrolled += scrolled;
	s.tally.chars += chars;
	if (chars > 0 && !s.launched()) { s.mark("painted", Date.now()); }
	if (rows > 0 && s.keyAt >= 0) {
		s.tally.echoes.push(at - s.keyAt);
		if (s.wakeAt >= s.keyAt) { s.tally.settles.push(at - s.wakeAt); }
		s.keyAt = -1;
		s.wakeAt = -1;
	}
}

function hundredths(ms: float64): float64 {
	return Math.round(ms * 100) / 100;
}

function summary(name: string, samples: Readonly<Span<float64>>): string {
	if (samples.length == 0) { return `${name} n=0`; }
	let sorted: Vec<float64> = [...samples];
	sorted.sort((a: float64, b: float64): number => a - b);
	const middle = hundredths(sorted[Math.floor(sorted.length / 2)]);
	const highest = hundredths(sorted[sorted.length - 1]);
	return `${name} n=${sorted.length} p50=${middle} max=${highest}`;
}

export function line(this s: Stats): string {
	return `refreshes=${s.tally.refreshes} more=${s.tally.more} held=${s.tally.held} ` +
		`rows=${s.tally.rows} scrolled=${s.tally.scrolled} chars=${s.tally.chars} ` +
		`${summary("echo", s.tally.echoes)} ${summary("settle", s.tally.settles)}`;
}

export function reset(this s: Stats): void {
	s.tally = Tally.zero();
}

test "a key's echo runs to the first apply with rows, its settle from the last wake before it" {
	const s = Stats.empty();
	s.recording = true;
	s.noteWake(9);
	s.noteKey(10);
	s.noteKey(12);
	s.noteWake(14);
	s.noteWake(15);
	s.noteApplied(0, 0, 0, 13);
	s.noteApplied(2, 0, 160, 15.5);
	s.noteApplied(1, 0, 80, 20);
	assert s.line() == "refreshes=0 more=0 held=0 rows=3 scrolled=0 chars=240 " +
		"echo n=1 p50=5.5 max=5.5 settle n=1 p50=0.5 max=0.5";
	s.reset();
	assert s.line() == "refreshes=0 more=0 held=0 rows=0 scrolled=0 chars=0 echo n=0 settle n=0";
}

test "a key noted after the wake that carried its echo still settles from that wake" {
	const s = Stats.empty();
	s.recording = true;
	s.noteWake(17);
	s.noteWake(20);
	s.noteKey(18);
	s.noteApplied(1, 0, 80, 21);
	s.noteKey(30);
	s.noteApplied(1, 0, 80, 32);
	assert s.line() == "refreshes=0 more=0 held=0 rows=2 scrolled=0 chars=160 " +
		"echo n=2 p50=3 max=3 settle n=1 p50=1 max=1";
}

test "each launch mark keeps its first time, and the launch ends at the first painted rows" {
	const s = Stats.empty();
	s.mark("config", 5);
	s.mark("spawn", 9);
	s.mark("config", 30);
	assert !s.launched();
	s.mark("painted", 40);
	assert s.launched();
	assert s.launchLine() == "config=5 spawn=9 painted=40";
}

test "without stats logging a key leaves no echo or settle sample behind" {
	const s = Stats.empty();
	s.noteKey(10);
	s.noteWake(14);
	s.noteApplied(2, 0, 160, 15.5);
	assert s.line() == "refreshes=0 more=0 held=0 rows=2 scrolled=0 chars=160 echo n=0 settle n=0";
}

test "the line reports each counter under its own name, and a reset zeroes them all" {
	const s = Stats.empty();
	s.tally.refreshes = 7;
	s.tally.more = 3;
	s.tally.held = 2;
	s.noteApplied(4, 1, 90, 5);
	s.noteApplied(2, 2, 10, 6);
	assert s.line() == "refreshes=7 more=3 held=2 rows=6 scrolled=3 chars=100 echo n=0 settle n=0";
	s.reset();
	assert s.tally.refreshes == 0 && s.tally.more == 0 && s.tally.held == 0 && s.tally.scrolled == 0;
}

test "painted rows mark the launch only when characters were drawn" {
	const s = Stats.empty();
	s.noteApplied(3, 0, 0, 5);
	assert !s.launched();
	s.noteApplied(3, 0, 12, 6);
	assert s.launched();
}

test "the tally counts past the int32 range" {
	const s = Stats.empty();
	s.tally.chars = 2147483647;
	s.tally.rows = 2147483647;
	s.tally.scrolled = 2147483647;
	s.tally.refreshes = 2147483647;
	s.noteApplied(1, 1, 1, 5);
	s.tally.refreshes += 1;
	assert (s.tally.chars as int64) > 2147483647;
	assert (s.tally.rows as int64) > 2147483647;
	assert (s.tally.scrolled as int64) > 2147483647;
	assert (s.tally.refreshes as int64) > 2147483647;
}
