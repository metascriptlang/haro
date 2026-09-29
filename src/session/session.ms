import { Pty, PtyError } from "../pty/pty";
import { Vt } from "../vt/vt";

export enum SessionError {
	PtyOpenFailed,
	PtyReadFailed,
	PtyWriteFailed,
	VtCreateFailed,
	VtReadFailed,
	ResizeFailed,
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
	if (r.value > 0) {
		s.vt.write(buf[0..r.value]);
		const _answered = try s.answer(buf);
	}
	return Result.ok(true);
}

function answer(this s: Session, buf: Span<uint8>): Result<int32, SessionError> {
	let total = 0;
	while (true) {
		const n = s.vt.replies(buf);
		if (!n.ok) { return Result.err(SessionError.VtReadFailed); }
		if (n.value == 0) { return Result.ok(total); }
		if (!s.pty.write(buf[0..n.value]).ok) { return Result.err(SessionError.PtyWriteFailed); }
		total += n.value;
	}
}

export function screen(this s: Session): Result<Vec<string>, SessionError> {
	if (!s.vt.update().ok) { return Result.err(SessionError.VtReadFailed); }
	const lines = s.vt.lines();
	if (!lines.ok) { return Result.err(SessionError.VtReadFailed); }
	return Result.ok(lines.value);
}

export function resize(this s: Session, cols: int32, rows: int32): Result<Session, SessionError> {
	const resizedVt = s.vt.resize(cols, rows);
	if (!resizedVt.ok) { return Result.err(SessionError.ResizeFailed); }
	const resizedPty = s.pty.resize(cols, rows);
	if (!resizedPty.ok) { return Result.err(SessionError.ResizeFailed); }
	return Result.ok(s);
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

test "a program's terminal query gets an answer back through the pty" {
	const started = Session.start(
		"powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/session/xtversion.ps1",
		60,
		5,
	);
	assert started.ok;
	if (started.ok) {
		const s = started.value;
		const ended = s.runToExit(10000);
		assert ended.ok;
		if (ended.ok) { assert ended.value; }
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) {
			assert screen.value[0].startsWith("reply=");
			assert screen.value[0] != "reply=";
		}
		s.close();
	}
}

test "a resize reaches a live child as its console size" {
	const started = Session.start(
		"powershell.exe -NoProfile -Command " +
			"Start-Sleep -Milliseconds 900; " +
			"[Console]::WriteLine([Console]::WindowWidth.ToString() + 'x' + " +
			"[Console]::WindowHeight.ToString())",
		80,
		24,
	);
	assert started.ok;
	if (started.ok) {
		const s = started.value;
		const ready = s.pty.wait(300);
		assert ready.ok;
		const resized = s.resize(100, 30);
		assert resized.ok;
		const ended = s.runToExit(15000);
		assert ended.ok;
		if (ended.ok) { assert ended.value; }
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) {
			const joined = screen.value.join("\n");
			assert joined.includes("100x30");
			assert !joined.includes("80x24");
		}
		const size = s.vt.size();
		assert size.ok;
		if (size.ok) {
			assert size.value[0] == 100;
			assert size.value[1] == 30;
		}
		s.close();
	}
}
