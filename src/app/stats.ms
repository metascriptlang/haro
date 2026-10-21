export interface Stats {
	refreshes: int32;
	more: int32;
	held: int32;
	rows: int32;
	scrolled: int32;
	chars: int32;
	keyAt: float64;
	wakeAt: float64;
	echoes: Vec<float64>;
	settles: Vec<float64>;
	marks: Vec<Mark>;
}

export struct Mark { name: string; at: float64; }

export function empty(this typeof Stats): Stats {
	return {
		refreshes: 0,
		more: 0,
		held: 0,
		rows: 0,
		scrolled: 0,
		chars: 0,
		keyAt: -1,
		wakeAt: -1,
		echoes: [],
		settles: [],
		marks: [],
	};
}

export const stats: Stats = Stats.empty();

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
	if (s.keyAt < 0) { s.keyAt = at; }
}

export function noteWake(this s: Stats, at: float64): void {
	s.mark("output", Date.now());
	if (s.keyAt >= 0) { s.wakeAt = at; }
}

export function noteApplied(
	this s: Stats,
	rows: int32,
	scrolled: int32,
	chars: int32,
	at: float64,
): void {
	s.rows += rows;
	s.scrolled += scrolled;
	s.chars += chars;
	if (chars > 0) { s.mark("painted", Date.now()); }
	if (rows > 0 && s.keyAt >= 0) {
		s.echoes.push(at - s.keyAt);
		if (s.wakeAt >= 0) { s.settles.push(at - s.wakeAt); }
		s.keyAt = -1;
		s.wakeAt = -1;
	}
}

function hundredths(ms: float64): float64 {
	return Math.round(ms * 100) / 100;
}

function summary(name: string, samples: Vec<float64>): string {
	if (samples.length == 0) { return `${name} n=0`; }
	let sorted: Vec<float64> = [...samples];
	sorted.sort((a: float64, b: float64): number => a - b);
	const middle = hundredths(sorted[Math.floor(sorted.length / 2)]);
	const highest = hundredths(sorted[sorted.length - 1]);
	return `${name} n=${sorted.length} p50=${middle} max=${highest}`;
}

export function line(this s: Stats): string {
	return `refreshes=${s.refreshes} more=${s.more} held=${s.held} rows=${s.rows} scrolled=${s.scrolled} ` +
		`chars=${s.chars} ${summary("echo", s.echoes)} ${summary("settle", s.settles)}`;
}

export function reset(this s: Stats): void {
	s.refreshes = 0;
	s.more = 0;
	s.held = 0;
	s.rows = 0;
	s.scrolled = 0;
	s.chars = 0;
	s.echoes = [];
	s.settles = [];
}

test "a key's echo runs to the first apply with rows, its settle from the last wake before it" {
	const s = Stats.empty();
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
