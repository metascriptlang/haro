import { isFile } from "std/fs";
import { env } from "std/process";
import { bashMajorOf } from "./shellIntegration";
import { NativePty, close, open } from "./pty";
import { Pty, PtyError } from "./transport";

const DRAIN_TIMEOUT_MS: int32 = 10000;

export function drainText(this p: Pty, chunk: int32): Result<string, string> {
	let buf: Vec<uint8> = new Array(chunk);
	let text = "";
	while (true) {
		const ready = p.wait(DRAIN_TIMEOUT_MS);
		if (!ready.ok) {
			if (ready.error == PtyError.Closed) { return Result.ok(text); }
			return Result.err(`wait failed: ${ready.error.toString()}`);
		}
		if (!ready.value) { return Result.err(`no output for ${DRAIN_TIMEOUT_MS} ms`); }
		const r = p.read(buf);
		if (!r.ok) {
			if (r.error == PtyError.Closed) { return Result.ok(text); }
			return Result.err(`read failed: ${r.error.toString()}`);
		}
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

export function bash5OnPath(): string | null {
	for (const dir of env.get("PATH").split(":")) {
		const candidate = `${dir}/bash`;
		if (dir != "" && isFile(candidate) && (bashMajorOf(candidate) ?? 0) >= 5) { return candidate; }
	}
	console.log("skipped: no bash 5 on PATH");
	return null;
}
