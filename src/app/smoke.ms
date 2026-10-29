import { frameCounts } from "../../../neon/src/platform/ion/window";
import { Pace } from "./pace";
import { IoPort } from "../controller/io";
import { View, text } from "./frame";


function dump(this view: View, label: string): void {
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

export function smokeReplay(io: IoPort, view: View, quit: () => void): void {
	setTimeout((): void => {
		view.dump("replayed");
		counts("after the replay");
		quit();
	}, 3000);
}

export function smoke(io: IoPort, view: View, quit: () => void): void {
	setTimeout((): void => { view.dump("prompt"); counts("after the prompt"); }, 4000);
	setTimeout((): void => {
		io.text("1..200 | % { \"line $_\" }\r", performance.now());
		console.log("smoke: sent 200 lines");
	}, 4200);
	setTimeout((): void => { view.dump("after 200 lines"); }, 6500);
	setTimeout((): void => { counts("idle begins"); }, 7000);
	setTimeout((): void => {
		counts("idle 2 s later");
		console.log("smoke: waiting for keys");
	}, 9000);
	setTimeout((): void => {
		view.dump("after keys");
		counts("end");
		quit();
	}, 42000);
}

function shows(this view: View, wanted: string): boolean {
	const n = view.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		if (view.text(i) == wanted) { return true; }
	}
	return false;
}

const FLOOD_LINES: int32 = 200000;
const FLOOD_IDLE_TICKS: int32 = 3;
const FLOOD_MAX_TICKS: int32 = 90;

export function smokeFlood(io: IoPort, view: View, pace: Pace, quit: () => void): void {
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
		if (doneAt < 0 && view.shows(`line ${FLOOD_LINES}`)) { doneAt = ticks; }
		const finished = doneAt >= 0 && ticks >= doneAt + FLOOD_IDLE_TICKS;
		if (finished || ticks >= FLOOD_MAX_TICKS) {
			console.log(`smoke: flood ${doneAt >= 0 ? "ended" : "did not end"} at tick ${doneAt}`);
			view.dump("after the flood");
			quit();
			return;
		}
		setTimeout(tick, 1000);
	};
	setTimeout((): void => {
		report("before the flood");
		io.text(`1..${FLOOD_LINES} | % { "line $_" }\r`, performance.now());
		console.log(`smoke: sent ${FLOOD_LINES} lines`);
		setTimeout(tick, 1000);
	}, 4000);
}

const TYPED_KEYS: int32 = 200;
const TYPING_GAP_MS = 50;

export function smokeTyping(io: IoPort, quit: () => void): void {
	let typed = 0;
	const type = (): void => {
		if (typed == TYPED_KEYS) {
			console.log(`smoke: typed ${TYPED_KEYS} keys`);
			setTimeout(quit, 1500);
			return;
		}
		typed += 1;
		io.text(typed % 40 == 0 ? "\r" : "x", performance.now());
		setTimeout(type, TYPING_GAP_MS);
	};
	setTimeout(type, 3000);
}
