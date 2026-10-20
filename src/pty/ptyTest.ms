import { Pty } from "./transport";

export function drainText(this p: Pty, chunk: int32): string {
	let buf: Vec<uint8> = new Array(chunk);
	let text = "";
	while (true) {
		const ready = p.wait(10000);
		if (!ready.ok || !ready.value) { return text; }
		const r = p.read(buf);
		if (!r.ok) { return text; }
		for (let i = 0; i < r.value; i++) { text += String.fromCharCode(buf[i] as int32); }
	}
}
