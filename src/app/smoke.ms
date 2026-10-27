import { frameCounts } from "../../../neon/src/platform/ion/window";
import { exit } from "std/process";
import { Pace } from "./pace";
import { Io, shutdown, text as typed } from "./components/features/terminal/io";
import { View, text } from "./frame";


function dump(view: View, label: string): void {
	console.log(`smoke: ${label}`);
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		const shown = view.text(i);
		if (shown != "") { console.log(`smoke: row ${i}: ${shown}`); }
	}
}

function counts(label: string): void {
	const c = frameCounts();
	console.log(`smoke: ${label}: requested=${c[0]} drawn=${c[1]}`);
}

export function smokeReplay(io: Io, view: View): void {
	setTimeout((): void => {
		dump(view, "replayed");
		counts("after the replay");
		io.shutdown();
		exit(0);
	}, 3000);
}

export function smoke(io: Io, view: View): void {
	setTimeout((): void => { dump(view, "prompt"); counts("after the prompt"); }, 4000);
	setTimeout((): void => {
		io.typed("1..200 | % { \"line $_\" }\r", performance.now());
		console.log("smoke: sent 200 lines");
	}, 4200);
	setTimeout((): void => { dump(view, "after 200 lines"); }, 6500);
	setTimeout((): void => { counts("idle begins"); }, 7000);
	setTimeout((): void => {
		counts("idle 2 s later");
		console.log("smoke: waiting for keys");
	}, 9000);
	setTimeout((): void => {
		dump(view, "after keys");
		counts("end");
		io.shutdown();
		exit(0);
	}, 42000);
}

function shows(view: View, wanted: string): boolean {
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (view.text(i) == wanted) { return true; }
	}
	return false;
}

const FLOOD_LINES: int32 = 200000;
const FLOOD_IDLE_TICKS: int32 = 3;
const FLOOD_MAX_TICKS: int32 = 90;

export function smokeFlood(io: Io, view: View, pace: Pace): void {
	let ticks = 0;
	let doneAt = -1;
	const report = (label: string): void => {
		const c = frameCounts();
		console.log(
			`smoke: ${label}: wakes=${pace.wakes} applies=${pace.applies} ` +
			`requested=${c[0]} drawn=${c[1]}`,
		);
	};
	const tick = (): void => {
		ticks += 1;
		report(`tick ${ticks}`);
		if (doneAt < 0 && shows(view, `line ${FLOOD_LINES}`)) { doneAt = ticks; }
		const finished = doneAt >= 0 && ticks >= doneAt + FLOOD_IDLE_TICKS;
		if (finished || ticks >= FLOOD_MAX_TICKS) {
			console.log(`smoke: flood ${doneAt >= 0 ? "ended" : "did not end"} at tick ${doneAt}`);
			dump(view, "after the flood");
			io.shutdown();
			exit(0);
			return;
		}
		setTimeout(tick, 1000);
	};
	setTimeout((): void => {
		report("before the flood");
		io.typed(`1..${FLOOD_LINES} | % { "line $_" }\r`, performance.now());
		console.log(`smoke: sent ${FLOOD_LINES} lines`);
		setTimeout(tick, 1000);
	}, 4000);
}
