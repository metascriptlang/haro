import { List } from "../../../neon/src/core/list";
import { frameCounts } from "../../../neon/src/platform/ion/window";
import { exit } from "std/process";
import { Term, shutdown, sendText } from "./term";

function dump(t: Term, label: string): void {
	console.log(`smoke: ${label}`);
	const n = t.grid.length() as int32;
	for (let i = 0; i < n; i++) {
		const text = t.grid.at(i).line.text.trimEnd();
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
