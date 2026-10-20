import { frameCounts } from "../../../neon/src/platform/ion/window";
import { exit } from "std/process";
import { Pace } from "./pace";
import { Term, shutdown, sendText } from "./components/features/terminal/term";

function rowText(t: Term, row: int32): string {
	return t.grid.at(row).line.text.trimEnd();
}

function dump(t: Term, label: string): void {
	console.log(`smoke: ${label}`);
	const n = t.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		const text = rowText(t, i);
		if (text != "") { console.log(`smoke: row ${i}: ${text}`); }
	}
}

function counts(label: string): void {
	const c = frameCounts();
	console.log(`smoke: ${label}: requested=${c[0]} drawn=${c[1]}`);
}

export function smokeReplay(t: Term): void {
	setTimeout((): void => {
		dump(t, "replayed");
		counts("after the replay");
		t.shutdown();
		exit(0);
	}, 3000);
}

export function smoke(t: Term): void {
	setTimeout((): void => { dump(t, "prompt"); counts("after the prompt"); }, 4000);
	setTimeout((): void => {
		const sent = t.sendText("1..200 | % { \"line $_\" }\r");
		console.log(`smoke: sent 200 lines, ok=${sent.ok}`);
	}, 4200);
	setTimeout((): void => { dump(t, "after 200 lines"); }, 6500);
	setTimeout((): void => { counts("idle begins"); }, 7000);
	setTimeout((): void => {
		counts("idle 2 s later");
		console.log("smoke: waiting for keys");
	}, 9000);
	setTimeout((): void => {
		dump(t, "after keys");
		counts("end");
		t.shutdown();
		exit(0);
	}, 42000);
}

function shows(t: Term, text: string): boolean {
	const n = t.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (rowText(t, i) == text) { return true; }
	}
	return false;
}

const FLOOD_LINES: int32 = 200000;
const FLOOD_IDLE_TICKS: int32 = 3;
const FLOOD_MAX_TICKS: int32 = 90;

export function smokeFlood(t: Term, pace: Pace): void {
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
		if (doneAt < 0 && shows(t, `line ${FLOOD_LINES}`)) { doneAt = ticks; }
		const finished = doneAt >= 0 && ticks >= doneAt + FLOOD_IDLE_TICKS;
		if (finished || ticks >= FLOOD_MAX_TICKS) {
			console.log(`smoke: flood ${doneAt >= 0 ? "ended" : "did not end"} at tick ${doneAt}`);
			dump(t, "after the flood");
			t.shutdown();
			exit(0);
			return;
		}
		setTimeout(tick, 1000);
	};
	setTimeout((): void => {
		report("before the flood");
		const sent = t.sendText(`1..${FLOOD_LINES} | % { "line $_" }\r`);
		console.log(`smoke: sent ${FLOOD_LINES} lines, ok=${sent.ok}`);
		setTimeout(tick, 1000);
	}, 4000);
}
