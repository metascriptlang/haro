import { Vt } from "../src/vt/vt";

const COLS: int32 = 200;
const ROWS: int32 = 60;
const RUNS: int32 = 50;

function fullScreen(): string {
	let text = "";
	for (let y = 0; y < ROWS; y++) {
		for (let x = 0; x < COLS / 10; x++) {
			text += `\x1b[38;2;${x * 10};${y * 4};200m`;
			text += x % 2 == 0 ? "\x1b[1m" : "\x1b[0m";
			text += "abcdefghij";
		}
		if (y < ROWS - 1) { text += "\r\n"; }
	}
	return text;
}

function median(samples: Vec<float64>): float64 {
	let sorted = samples;
	for (let i = 1; i < sorted.length; i++) {
		for (let j = i; j > 0 && sorted[j - 1] > sorted[j]; j--) {
			const t = sorted[j];
			sorted[j] = sorted[j - 1];
			sorted[j - 1] = t;
		}
	}
	return sorted[sorted.length / 2];
}

function main(): int32 {
	const created = Vt.create(COLS, ROWS);
	if (!created.ok) { return 1; }
	const vt = created.value;
	vt.writeText(fullScreen());
	let update: Vec<float64> = [];
	let full: Vec<float64> = [];
	let oneRow: Vec<float64> = [];
	let cells = 0;
	let dirtyCount = 0;
	for (let run = 0; run < RUNS; run++) {
		if (!vt.update().ok) { return 1; }
		const f0: float64 = performance.now();
		const rows = vt.rows();
		full.push(performance.now() - f0);
		if (!rows.ok) { return 1; }
		cells = 0;
		for (const row of rows.value) { cells += row.cells.length; }
		vt.clean();
		vt.writeText("\x1b[1;1H\x1b[31mx");
		const u0: float64 = performance.now();
		if (!vt.update().ok) { return 1; }
		update.push(performance.now() - u0);
		const d0: float64 = performance.now();
		const dirty = vt.dirtyRows();
		oneRow.push(performance.now() - d0);
		if (!dirty.ok) { return 1; }
		dirtyCount = dirty.value.length;
		vt.clean();
	}
	console.log(`cells=${cells} runs=${RUNS} dirty rows after one write=${dirtyCount}`);
	console.log(`update after one write median ${median(update)} ms`);
	console.log(`rows() full ${COLS}x${ROWS} median ${median(full)} ms`);
	console.log(`dirtyRows() after one write median ${median(oneRow)} ms`);
	vt.free();
	return 0;
}

process.exit(main());
