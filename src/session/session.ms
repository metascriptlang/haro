import { Pty, PtyError } from "../pty/pty";
import { Vt } from "../vt/vt";

export enum SessionError {
	PtyOpenFailed,
	PtyReadFailed,
	VtCreateFailed,
	VtReadFailed,
}

export struct Session {
	pty: Pty;
	vt: Vt;
}

export function start(
	this typeof Session,
	commandLine: string,
	cols: int32,
	rows: int32,
): Result<Session, SessionError> {
	const vt = Vt.create(cols, rows);
	if (!vt.ok) { return Result.err(SessionError.VtCreateFailed); }
	const pty = Pty.open(commandLine, cols, rows);
	if (!pty.ok) {
		vt.value.free();
		return Result.err(SessionError.PtyOpenFailed);
	}
	return Result.ok({ pty: pty.value, vt: vt.value });
}

export function pump(this s: Session, buf: Span<uint8>): Result<boolean, SessionError> {
	const r = s.pty.read(buf);
	if (!r.ok) {
		if (r.error == PtyError.Closed) { return Result.ok(false); }
		return Result.err(SessionError.PtyReadFailed);
	}
	if (r.value > 0) { s.vt.write(buf[0..r.value]); }
	return Result.ok(true);
}

export function screen(this s: Session): Result<string[], SessionError> {
	if (!s.vt.update().ok) { return Result.err(SessionError.VtReadFailed); }
	const rows = s.vt.rows();
	if (!rows.ok) { return Result.err(SessionError.VtReadFailed); }
	const lines: string[] = [];
	for (const row of rows.value) { lines.push(row.text.trimEnd()); }
	return Result.ok(lines);
}

export function close(this s: Session): void {
	s.pty.close();
	s.vt.free();
}

function runToExit(this s: Session, timeoutMs: int32): Result<boolean, SessionError> {
	const buf: Vec<uint8> = new Array(4096);
	while (true) {
		const ready = s.pty.wait(timeoutMs);
		if (!ready.ok) { return Result.err(SessionError.PtyReadFailed); }
		if (!ready.value) { return Result.ok(false); }
		const alive = try s.pump(buf);
		if (!alive) { return Result.ok(true); }
	}
}

test "a real command's output, run through ConPTY, lands on the VT screen" {
	const started = Session.start("cmd.exe /c echo hello", 40, 5);
	assert started.ok;
	if (started.ok) {
		const s = started.value;
		const ended = s.runToExit(10000);
		assert ended.ok;
		if (ended.ok) { assert ended.value; }
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) {
			assert screen.value.join("\n") == "hello\n\n\n\n";
		}
		s.close();
	}
}
