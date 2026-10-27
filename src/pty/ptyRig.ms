import { NativePty, close, open } from "./pty";
import { Pty } from "./transport";

export function drainText(this p: Pty, chunk: int32): string {
	let buf: Vec<uint8> = new Array(chunk);
	let text = "";
	while (true) {
		const ready = p.wait(10000);
		if (!ready.ok || !ready.value) { return text; }
		const r = p.read(buf);
		if (!r.ok) { return text; }
		text += buf[0..r.value].asString();
	}
}

export function withPty(command: string, body: (p: NativePty) => void): boolean {
	const opened = NativePty.open(command, 80, 24);
	if (!opened.ok) { return false; }
	const p = opened.value;
	defer p.close();
	body(p);
	return true;
}
