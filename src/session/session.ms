import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { Vt } from "../vt/vt";

export enum SessionError {
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
	pty: Pty,
	cols: int32,
	rows: int32,
): Result<Session, SessionError> {
	const vt = Vt.create(cols, rows);
	if (!vt.ok) {
		pty.close();
		return Result.err(SessionError.VtCreateFailed);
	}
	return Result.ok({ pty: pty, vt: vt.value });
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
	let buf: Vec<uint8> = new Array(4096);
	while (true) {
		const ready = s.pty.wait(timeoutMs);
		if (!ready.ok) { return Result.err(SessionError.PtyReadFailed); }
		if (!ready.value) { return Result.ok(false); }
		const alive = try s.pump(buf);
		if (!alive) { return Result.ok(true); }
	}
}

function replaySession(recording: string, cols: int32, rows: int32): Session | null {
	const started = Session.start(Replay.ofText(recording).toPty(), cols, rows);
	if (!started.ok) { return null; }
	return started.value;
}

function pumpInChunks(this s: Session, chunk: int32): Result<boolean, SessionError> {
	let buf: Vec<uint8> = new Array(chunk);
	while (true) {
		const alive = try s.pump(buf);
		if (!alive) { return Result.ok(true); }
	}
}

test "a replayed recording ends in the rows the recorded program drew" {
	const s = replaySession("one\r\ntwo\r\n\x1b[1;31mred\x1b[0m done", 20, 4);
	assert s !== null;
	if (s !== null) {
		const ended = s.runToExit(1000);
		assert ended.ok;
		if (ended.ok) { assert ended.value; }
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) { assert screen.value.join("\n") == "one\ntwo\nred done\n"; }
		assert s.pty.exitCode() === 0;
		s.close();
		assert !s.pty.wait(0).ok;
	}
}

test "a recording cut into one-byte reads draws the rows a single read does" {
	const recording = "top\x1b[3;4Hdeep\x1b[1;1H\x1b[2Kfresh\x1b[2;2H\x1b[31mred";
	const whole = replaySession(recording, 20, 4);
	const bytes = replaySession(recording, 20, 4);
	assert whole !== null && bytes !== null;
	if (whole !== null && bytes !== null) {
		assert whole.pumpInChunks(4096).ok;
		assert bytes.pumpInChunks(1).ok;
		const a = whole.screen();
		const b = bytes.screen();
		assert a.ok && b.ok;
		if (a.ok && b.ok) {
			assert a.value.join("\n") == "fresh\n red\n   deep\n";
			assert b.value.join("\n") == a.value.join("\n");
		}
		whole.close();
		bytes.close();
	}
}

test "a replay drops the answer to a terminal query and the screen carries on" {
	const s = replaySession("\x1b[>qafter", 20, 4);
	assert s !== null;
	if (s !== null) {
		const ended = s.runToExit(1000);
		assert ended.ok;
		if (ended.ok) { assert ended.value; }
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) { assert screen.value[0] == "after"; }
		s.close();
	}
}

// msc compiles the C file of every module a build imports, test-only imports included: keep
// ConPTY out of non-test builds so a web build of this module never needs conpty.c.
when (testBuild) {
	import { ConPty } from "../pty/pty";
	import { readFile } from "std/fs";

	test "a recorded Get-ChildItem replays to the table pwsh drew" {
		const recording = readFile("fixtures/getChildItem.ansi");
		assert recording.ok;
		if (recording.ok) {
			const s = replaySession(recording.value, 105, 30);
			assert s !== null;
			if (s !== null) {
				const ended = s.runToExit(1000);
				assert ended.ok;
				if (ended.ok) { assert ended.value; }
				const screen = s.screen();
				assert screen.ok;
				if (screen.ok) {
					const rows = screen.value;
					assert rows[1].startsWith("    Directory: ");
					assert rows[3] == "Mode                 LastWriteTime         Length Name";
					assert rows[4].startsWith("----                 -------------         ------ ----");
					assert rows[5].startsWith("d----");
					assert rows[5].endsWith("assets");
					assert rows[13].startsWith("-a---");
					assert rows[13].endsWith(".gitattributes");
					assert rows[16] == "";
				}
				s.close();
			}
		}
	}

	function conPtySession(commandLine: string, cols: int32, rows: int32): Session | null {
		const pty = ConPty.spawn(commandLine, cols, rows);
		if (!pty.ok) { return null; }
		const started = Session.start(pty.value, cols, rows);
		if (!started.ok) { return null; }
		return started.value;
	}

	test "a real command's output, run through ConPTY, lands on the VT screen" {
		const s = conPtySession("cmd.exe /c echo hello", 40, 5);
		assert s !== null;
		if (s !== null) {
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
		const s = conPtySession(
			"powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/session/xtversion.ps1",
			60,
			5,
		);
		assert s !== null;
		if (s !== null) {
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
		const s = conPtySession(
			"powershell.exe -NoProfile -Command " +
				"Start-Sleep -Milliseconds 900; " +
				"[Console]::WriteLine([Console]::WindowWidth.ToString() + 'x' + " +
				"[Console]::WindowHeight.ToString())",
			80,
			24,
		);
		assert s !== null;
		if (s !== null) {
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
}
