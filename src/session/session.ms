import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { Vt } from "../vt/vt";

export enum SessionError {
	PtyReadFailed,
	PtyWriteFailed,
	PtyBacklogged,
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
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<Session, SessionError> {
	const vt = Vt.create(cols, rows);
	if (!vt.ok) {
		pty.close();
		return Result.err(SessionError.VtCreateFailed);
	}
	const pullFailed = pty.ownsScreen && !vt.value.setPullScrollback(false).ok;
	if (pullFailed || !vt.value.resize(cols, rows, cellWidth, cellHeight).ok) {
		vt.value.free();
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
		try s.sendReplies();
	}
	return Result.ok(true);
}

export function sendReplies(this s: Session): Result<void, SessionError> {
	const replies = s.vt.effects.replies;
	if (replies.length == 0) { return Result.ok(null); }
	try s.send(replies);
	s.vt.effects.replies = [];
	return Result.ok(null);
}

export function screen(this s: Session): Result<Vec<string>, SessionError> {
	if (!s.vt.update().ok) { return Result.err(SessionError.VtReadFailed); }
	const lines = s.vt.lines();
	if (!lines.ok) { return Result.err(SessionError.VtReadFailed); }
	return Result.ok(lines.value);
}

export function send(this s: Session, data: Readonly<Span<uint8>>): Result<void, SessionError> {
	const wrote = s.pty.write(data);
	if (wrote.ok || s.pty.exitCode() !== null) { return Result.ok(null); }
	if (wrote.error == PtyError.Backlogged) { return Result.err(SessionError.PtyBacklogged); }
	return Result.err(SessionError.PtyWriteFailed);
}

export function resize(
	this s: Session,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<void, SessionError> {
	const resizedVt = s.vt.resize(cols, rows, cellWidth, cellHeight);
	if (!resizedVt.ok) { return Result.err(SessionError.ResizeFailed); }
	const resizedPty = s.pty.resize(cols, rows, cellWidth, cellHeight);
	if (!resizedPty.ok && s.pty.exitCode() === null) {
		return Result.err(SessionError.ResizeFailed);
	}
	return s.sendReplies();
}

export function close(this s: Session): void {
	s.pty.close();
	s.vt.free();
}

function runToExit(
	this s: Session,
	timeoutMs: int32,
	chunk: int32 = 4096,
): Result<boolean, SessionError> {
	let buf: Vec<uint8> = new Array(chunk);
	while (true) {
		const ready = s.pty.wait(timeoutMs);
		if (!ready.ok) { return Result.err(SessionError.PtyReadFailed); }
		if (!ready.value) { return Result.ok(false); }
		const alive = try s.pump(buf);
		if (!alive) { return Result.ok(true); }
	}
}

function ranToExit(this s: Session, timeoutMs: int32, chunk: int32 = 4096): boolean {
	const ended = s.runToExit(timeoutMs, chunk);
	return ended.ok && ended.value;
}

function startedOrNull(pty: Pty, cols: int32, rows: int32): Session | null {
	const started = Session.start(pty, cols, rows);
	if (!started.ok) { return null; }
	return started.value;
}

function replaySession(recording: string, cols: int32, rows: int32): Session | null {
	return startedOrNull(Replay.ofText(recording).toPty(), cols, rows);
}

test "a replayed recording ends in the rows the recorded program drew" {
	const s = replaySession("one\r\ntwo\r\n\x1b[1;31mred\x1b[0m done", 20, 4);
	assert s !== null;
	if (s !== null) {
		assert s.ranToExit(1000);
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
		assert whole.ranToExit(1000);
		assert bytes.ranToExit(1000, 1);
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
		assert s.ranToExit(1000);
		const screen = s.screen();
		assert screen.ok;
		if (screen.ok) { assert screen.value[0] == "after"; }
		s.close();
	}
}

// msc compiles the C file of every module a build imports, test-only imports included: keep
// the native pty out of non-test builds so a web build of this module never needs its C file.
when (testBuild) {
	import { NativePty } from "../pty/pty";
	import { readFile } from "std/fs";

	test "a recorded Get-ChildItem replays to the table pwsh drew" {
		const recording = readFile("fixtures/getChildItem.ansi");
		assert recording.ok;
		if (recording.ok) {
			const s = replaySession(recording.value, 105, 30);
			assert s !== null;
			if (s !== null) {
				assert s.ranToExit(1000);
				const screen = s.screen();
				assert screen.ok;
				if (screen.ok) {
					const rows = screen.value;
					assert rows[1].startsWith("    Directory: ");
					assert rows[3] == "Mode                 LastWriteTime         Length Name";
					assert rows[4].startsWith(
						"----                 -------------         ------ ----",
					);
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

	when (windows) {
		const ECHO_HELLO = "cmd.exe /c echo hello";
		const ASK_XTVERSION = "powershell.exe -NoProfile -ExecutionPolicy Bypass " +
			"-File src/session/xtversion.ps1";
		const PRINT_SIZE_LATE = "powershell.exe -NoProfile -Command " +
			"Start-Sleep -Milliseconds 900; " +
			"[Console]::WriteLine([Console]::WindowWidth.ToString() + 'x' + " +
			"[Console]::WindowHeight.ToString())";
	} else {
		const ECHO_HELLO = "echo hello";
		const ASK_XTVERSION = "sh src/session/xtversion.sh";
		const PRINT_SIZE_LATE = "sh -c 'sleep 0.9; " +
			"stty size | while read r c; do echo \"${c}x$r\"; done'";
	}

	function nativePtySession(commandLine: string, cols: int32, rows: int32): Session | null {
		const pty = NativePty.spawn(commandLine, cols, rows);
		if (!pty.ok) { return null; }
		return startedOrNull(pty.value, cols, rows);
	}

	test "a real command's output, run through the native pty, lands on the VT screen" {
		const s = nativePtySession(ECHO_HELLO, 40, 5);
		assert s !== null;
		if (s !== null) {
			assert s.ranToExit(10000);
			const screen = s.screen();
			assert screen.ok;
			if (screen.ok) {
				assert screen.value.join("\n") == "hello\n\n\n\n";
			}
			s.close();
		}
	}

	test "a program's terminal query gets an answer back through the pty" {
		const s = nativePtySession(ASK_XTVERSION, 60, 5);
		assert s !== null;
		if (s !== null) {
			assert s.ranToExit(10000);
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
		const s = nativePtySession(PRINT_SIZE_LATE, 80, 24);
		assert s !== null;
		if (s !== null) {
			const ready = s.pty.wait(300);
			assert ready.ok;
			const resized = s.resize(100, 30);
			assert resized.ok;
			assert s.ranToExit(15000);
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

function sentAfterExit(running: boolean): string {
	const base = Replay.ofText("bye").toPty();
	const pty: Pty = {
		...base,
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			return Result.err(PtyError.Closed);
		},
		resize: (
			cols: int32,
			rows: int32,
			cellWidth: int32,
			cellHeight: int32,
		): Result<void, PtyError> => {
			return Result.err(PtyError.Closed);
		},
		exitCode: (): int32 | null => { return running ? null : 0; },
	};
	const started = Session.start(pty, 10, 3);
	if (!started.ok) { return "start failed"; }
	const s = started.value;
	let bytes: Vec<uint8> = [0x61];
	const sent = s.send(bytes);
	const resized = s.resize(12, 4);
	s.close();
	return `${sent.ok ? "sent" : "send failed"}, ${resized.ok ? "resized" : "resize failed"}`;
}

test "input and a resize after the shell exited are dropped, and still fail while it runs" {
	assert sentAfterExit(false) == "sent, resized";
	assert sentAfterExit(true) == "send failed, resize failed";
}

function rowsAfterGrowing(ownsScreen: boolean): string {
	const replayed = Replay.ofText("l1\r\nl2\r\nl3\r\nl4\r\nl5").toPty();
	const pty: Pty = { ...replayed, ownsScreen: ownsScreen };
	const started = Session.start(pty, 10, 3);
	if (!started.ok) { return "start failed"; }
	const s = started.value;
	if (!s.runToExit(1000).ok) { return "pump failed"; }
	if (!s.resize(10, 5).ok) { return "resize failed"; }
	const screen = s.screen();
	s.close();
	if (!screen.ok) { return "read failed"; }
	return screen.value.join("|");
}

test "a session keeps scrollback out of a grown grid when its pty owns the screen" {
	assert rowsAfterGrowing(false) == "l1|l2|l3|l4|l5";
	assert rowsAfterGrowing(true) == "l3|l4|l5||";
}

test "a resize sends a mode 2048 subscriber its new size in cells and pixels at once" {
	let sent = "";
	const pty: Pty = {
		...Replay.ofText("\x1b[?2048h").toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			sent += data.asString();
			return Result.ok(null);
		},
	};
	const s = startedOrNull(pty, 20, 4);
	assert s !== null;
	if (s !== null) {
		assert s.ranToExit(1000);
		sent = "";
		assert s.resize(30, 6, 8, 16).ok;
		assert sent == "\x1b[48;6;30;96;240t";
		s.close();
	}
}
