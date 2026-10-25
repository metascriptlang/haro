@include("./nativePty.h");
when (windows) {
	@compile("./conpty.c");
} else {
	@compile("./posixPty.c");
}
when (linux) {
	@passL("-lutil");
}

import { isDir } from "std/fs";
import { langEntry } from "./locale";
import { Pty, PtyError } from "./transport";

extern function ptyOpen(
	commandLine: cstring,
	cwd: cstring,
	langEntry: cstring,
	cols: int32,
	rows: int32,
	widthPx: int32,
	heightPx: int32,
): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Readonly<Span<uint8>>): int64;
extern function ptyResize(
	id: int32,
	cols: int32,
	rows: int32,
	widthPx: int32,
	heightPx: int32,
): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

when (!windows) {
	@include("unistd.h");

	extern function ptyMaster(id: int32): int32;
	extern function ptyChildPid(id: int32): int32;
	extern function ptyExitSignal(id: int32): int32;
	extern function tcgetpgrp(fd: int32): int32;
}

export struct NativePty { id: int32; }

export function open(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<NativePty, PtyError> {
	const dir = cwd !== null && isDir(cwd) ? cwd : "";
	const id = ptyOpen(
		commandLine,
		dir,
		langEntry(),
		cols,
		rows,
		cols * cellWidth,
		rows * cellHeight,
	);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

const PTY_OUT_OF_MEMORY: int64 = -2;

function transferred(n: int64): Result<int32, PtyError> {
	return match (n) {
		PTY_OUT_OF_MEMORY => Result.err(PtyError.OutOfMemory),
		_ when n < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(n as int32),
	};
}

export function read(this p: NativePty, buf: Span<uint8>): Result<int32, PtyError> {
	return transferred(ptyRead(p.id, buf));
}

export function wait(this p: NativePty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	return match (r) {
		-2 => Result.err(PtyError.WaitFailed),
		_ when r < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(r == 1),
	};
}

export function write(this p: NativePty, data: Readonly<Span<uint8>>): Result<int32, PtyError> {
	return transferred(ptyWrite(p.id, data));
}

export function resize(
	this p: NativePty,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<void, PtyError> {
	if (ptyResize(p.id, cols, rows, cols * cellWidth, rows * cellHeight) != 0) {
		return Result.err(PtyError.ResizeFailed);
	}
	return Result.ok(null);
}

export function exitCode(this p: NativePty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function exitSignal(this p: NativePty): int32 {
	when (windows) {
		return 0;
	} else {
		if (ptyExited(p.id) == 0) { return 0; }
		return ptyExitSignal(p.id);
	}
}

export function close(this p: NativePty): void {
	ptyClose(p.id);
}

export function busy(this p: NativePty): boolean {
	when (windows) {
		return false;
	} else {
		if (ptyExited(p.id) != 0) { return false; }
		const group = tcgetpgrp(ptyMaster(p.id));
		return group > 0 && group != ptyChildPid(p.id);
	}
}

export function toPty(this p: NativePty): Pty {
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => { return p.wait(timeoutMs); },
		read: (buf: Span<uint8>): Result<int32, PtyError> => { return p.read(buf); },
		write: (data: Readonly<Span<uint8>>): Result<int32, PtyError> => { return p.write(data); },
		resize: (
			cols: int32,
			rows: int32,
			cellWidth: int32,
			cellHeight: int32,
		): Result<void, PtyError> => {
			return p.resize(cols, rows, cellWidth, cellHeight);
		},
		exitCode: (): int32 | null => { return p.exitCode(); },
		exitSignal: (): int32 => { return p.exitSignal(); },
		close: (): void => { p.close(); },
		busy: (): boolean => { return p.busy(); },
		ownsScreen: true,
	};
}

export function spawn(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<Pty, PtyError> {
	const opened = try NativePty.open(commandLine, cols, rows, cwd, cellWidth, cellHeight);
	return Result.ok(opened.toPty());
}

when (testBuild) {
	import { normalize, remove, writeFile } from "std/fs";
	import { tmpDir } from "std/os";
	import { drainText } from "./ptyTest";

	@include("unistd.h");

	extern function getpid(): int32;

	when (windows) {
		const ECHO_HELLO = "cmd.exe /c echo hello";
		const QUIET_FOR_3S = "cmd.exe /c ping -n 4 127.0.0.1 > nul";
		const MISSING_PROGRAM = "no-such-program-haro.exe";
		const ECHO_LINE_READ = "cmd.exe /v:on /c \"set /p line=& echo [!line!]\"";
		function printFile(path: string): string {
			return `cmd.exe /c type "${path.replaceAll("/", "\\")}"`;
		}
		const PRINT_DIRECTORY = "cmd.exe /c echo [%CD%]";
	} else {
		const ECHO_HELLO = "echo hello";
		const QUIET_FOR_3S = "sleep 3";
		const MISSING_PROGRAM = "no-such-program-haro";
		const ECHO_LINE_READ = "sh -c 'read line; echo \"[$line]\"'";
		function printFile(path: string): string { return `cat "${path}"`; }
		const PRINT_DIRECTORY = "sh -c 'echo \"[$PWD]\"'";
	}

	function quietWaitMs(this p: NativePty, timeoutMs: int32): Result<float64, PtyError> {
		let buf: Vec<uint8> = new Array(4096);
		while (true) {
			const start: float64 = performance.now();
			const ready = try p.wait(timeoutMs);
			if (!ready) { return Result.ok(performance.now() - start); }
			const _read = try p.read(buf);
		}
	}

	test "a child's output reaches read and its exit ends the stream" {
		const opened = NativePty.open(ECHO_HELLO, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			const text = p.toPty().drainText(4096);
			assert text.includes("hello");
			assert p.exitCode() === 0;
			p.close();
		}
	}

	test "a wait returns as soon as the child writes" {
		const opened = NativePty.open(ECHO_HELLO, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			const start: float64 = performance.now();
			const ready = p.wait(10000);
			assert ready.ok;
			if (ready.ok) { assert ready.value; }
			assert performance.now() - start < 5000;
			p.close();
		}
	}

	test "a wait on a quiet child sleeps until its timeout" {
		const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			const waited = p.quietWaitMs(300);
			assert waited.ok;
			if (waited.ok) { assert waited.value >= 250; }
			assert p.exitCode() === null;
			p.close();
		}
	}

	test "a resize of a live console succeeds" {
		const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			assert opened.value.resize(120, 40).ok;
			opened.value.close();
		}
	}

	test "a command that cannot start is an error" {
		const opened = NativePty.open(MISSING_PROGRAM, 80, 24);
		assert !opened.ok;
	}

	test "a native pty starts its command in the directory it is given" {
		const dir = normalize(tmpDir());
		const spawned = NativePty.spawn(PRINT_DIRECTORY, 80, 24, dir);
		assert spawned.ok;
		if (spawned.ok) {
			const out = spawned.value.drainText(4096).replaceAll("\\", "/");
			when (windows) {
				assert out.toLowerCase().includes(`[${dir.toLowerCase()}]`);
			} else {
				assert out.includes(`[${dir}]`);
			}
			spawned.value.close();
		}
	}

	test "a directory that does not exist is skipped and the command still runs" {
		const spawned = NativePty.spawn(ECHO_HELLO, 80, 24, "/no/such/haro/directory");
		assert spawned.ok;
		if (spawned.ok) {
			assert spawned.value.drainText(4096).includes("hello");
			spawned.value.close();
		}
	}

	when (!windows) {
		import { env } from "std/process";

		@include("signal.h");

		extern function kill(pid: int32, signal: int32): int32;

		function readLine(this p: NativePty): string {
			let buf: Vec<uint8> = new Array(256);
			let text = "";
			while (!text.includes("\n")) {
				const ready = p.wait(5000);
				if (!ready.ok || !ready.value) { return text; }
				const r = p.read(buf);
				if (!r.ok) { return text; }
				text += buf[0..r.value].asString();
			}
			return text;
		}

		test "closing a pty ends the child's whole process group, a job that ignores hangup too" {
			const opened = NativePty.open("sh -c 'trap \"\" HUP; sleep 30 & echo $!; wait'", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				const job = p.readLine().trim().parseInt() as int32;
				assert job > 0;
				assert kill(job, 0) == 0;
				p.close();
				const closed: float64 = performance.now();
				while (kill(job, 0) == 0 && performance.now() - closed < 3000) {}
				assert kill(job, 0) != 0;
			}
		}

		test "a shell that has exited is not busy, and reports its exit code" {
			const opened = NativePty.open("sh -c 'exit 3'", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				const _text = p.toPty().drainText(4096);
				assert p.exitCode() === 3;
				assert !p.busy();
				p.close();
			}
		}

		function endOf(command: string): string {
			const opened = NativePty.open(command, 80, 24);
			if (!opened.ok) { return "not opened"; }
			const p = opened.value;
			const _text = p.toPty().drainText(4096);
			const ended = `${p.exitCode() ?? -1} ${p.exitSignal()}`;
			p.close();
			return ended;
		}

		test "a shell killed by a signal reports the signal apart from a status that only looks like one" {
			assert endOf("sh -c 'kill -KILL $$'") == "137 9";
			assert endOf("sh -c 'exit 137'") == "137 0";
			assert endOf("sh -c 'exit 0'") == "0 0";
		}

		function becomesBusy(this p: NativePty, wanted: boolean, withinMs: float64): boolean {
			const start: float64 = performance.now();
			while (p.busy() != wanted) {
				if (performance.now() - start > withinMs) { return false; }
			}
			return true;
		}

		test "a shell is busy while a job it runs holds the terminal, and idle back at its own read" {
			const opened = NativePty.open("sh -c 'set -m; sleep 2; read line'", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				assert p.becomesBusy(true, 5000);
				assert p.becomesBusy(false, 5000);
				p.close();
			}
		}

		test "a program a shell without job control runs stays in the shell's group and is not busy" {
			const opened = NativePty.open("sh -c 'echo go; sleep 2; read line'", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				assert p.readLine().includes("go");
				assert !p.becomesBusy(true, 1000);
				p.close();
			}
		}

		test "the child is told the terminal is Haro, not the one Haro was started from" {
			assert env.set("TERM_PROGRAM", "OtherTerminal");
			assert env.set("TERM_SESSION_ID", "w0t0");
			const opened = NativePty.open("sh -c 'echo \"[$TERM_PROGRAM|$TERM_SESSION_ID|$TERM]\"'", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				assert opened.value.toPty().drainText(4096).includes("[Haro||xterm-256color]");
				opened.value.close();
			}
			assert env.get("TERM_PROGRAM") == "OtherTerminal";
		}

		function childLang(): string {
			const opened = NativePty.open("env", 80, 24);
			if (!opened.ok) { return "open failed"; }
			const out = opened.value.toPty().drainText(65536);
			opened.value.close();
			return out.split("\r\n").filter((line: string): boolean => line.startsWith("LANG=")).join("|");
		}

		test "the child keeps an inherited LANG" {
			const inherited = env.get("LANG");
			assert env.set("LANG", "fr_FR.UTF-8");
			assert childLang() == "LANG=fr_FR.UTF-8";
			assert env.set("LANG", inherited);
		}

		when (macos) {
			import { preferredLang } from "./locale";

			test "a child started without a LANG gets one from the macOS locale preference" {
				const inherited = env.get("LANG");
				assert env.delete("LANG");
				assert childLang() == `LANG=${preferredLang()}`;
				assert env.set("LANG", "");
				assert childLang() == `LANG=${preferredLang()}`;
				assert env.set("LANG", inherited);
			}
		}

		test "a child reads its size in pixels from the cell size at open and after a resize" {
			const printSizes = "python3 -c 'import fcntl, termios, struct, time; " +
				"size = lambda: struct.unpack(\"4H\", fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8))); " +
				"print(size()); time.sleep(0.9); print(size())'";
			const opened = NativePty.open(printSizes, 80, 24, null, 8, 16);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				assert p.wait(5000).ok;
				assert p.resize(100, 30, 9, 18).ok;
				const out = p.toPty().drainText(4096);
				assert out.includes("(24, 80, 640, 384)");
				assert out.includes("(30, 100, 900, 540)");
				p.close();
			}
		}

		test "a shell that exits ends the stream, though a job in its own session still writes" {
			let ticks = "";
			for (let i = 0; i < 300; i++) { ticks += " x"; }
			const job = `setsid sh -c "for t in${ticks}; do echo spam; sleep 0.01; done"`;
			const opened = NativePty.open(`sh -c '${job} & sleep 0.2; echo done'`, 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const start: float64 = performance.now();
				assert opened.value.toPty().drainText(4096).includes("done");
				assert performance.now() - start < 2500;
				assert opened.value.exitCode() === 0;
				opened.value.close();
			}
		}
	}

	when (windows) {
		test "a resize after the child exited is refused, since its console is already closed" {
			const opened = NativePty.open(ECHO_HELLO, 80, 24);
			assert opened.ok;
			if (opened.ok) {
				const p = opened.value;
				assert p.toPty().drainText(4096).includes("hello");
				assert p.exitCode() === 0;
				assert !p.resize(100, 30).ok;
				p.close();
			}
		}

		test "environment variables in the command line are expanded, as Windows shortcuts do" {
			const opened = NativePty.open("%SystemRoot%\\System32\\cmd.exe /c echo hello", 80, 24);
			assert opened.ok;
			if (opened.ok) {
				assert opened.value.toPty().drainText(4096).includes("hello");
				opened.value.close();
			}
		}
	}

	test "a native pty spawned as a Pty reads its output and reports its exit through the interface" {
		const spawned = NativePty.spawn(ECHO_HELLO, 80, 24);
		assert spawned.ok;
		if (spawned.ok) {
			const pty = spawned.value;
			assert pty.drainText(4096).includes("hello");
			assert pty.exitCode() === 0;
			pty.close();
		}
	}

	test "a resize through the Pty interface reaches a live native pty" {
		const spawned = NativePty.spawn(QUIET_FOR_3S, 80, 24);
		assert spawned.ok;
		if (spawned.ok) {
			const pty = spawned.value;
			assert pty.resize(100, 30, 8, 16).ok;
			pty.close();
		}
	}

	test "a write to a child that does not read its input returns at once" {
		const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			let chunk: Vec<uint8> = new Array(1048576);
			for (let i = 0; i < chunk.length; i++) { chunk[i] = "a".code + (i % 26) as uint8; }
			const start: float64 = performance.now();
			for (let i = 0; i < 4; i++) { assert p.write(chunk).ok; }
			assert performance.now() - start < 200;
			p.close();
		}
	}

	test "a line written to the child reaches it" {
		const opened = NativePty.open(ECHO_LINE_READ, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			let line: Vec<uint8> = [0x68, 0x69, 0x0D];
			assert p.write(line).ok;
			assert p.toPty().drainText(4096).includes("[hi]");
			p.close();
		}
	}

	struct LineCheck {
		linesInOrder: int32;
		number: int64;
		hasDigits: boolean;
		inNumber: boolean;
		inEscape: boolean;
		byteCount: int64;
	}

	const CANNOT_MATCH: int64 = -1;

	const NO_LINES: LineCheck = {
		linesInOrder: 0,
		number: 0,
		hasDigits: false,
		inNumber: false,
		inEscape: false,
		byteCount: 0,
	};

	function feed(this before: LineCheck, bytes: Readonly<Span<uint8>>): LineCheck {
		let c = before;
		c.byteCount += bytes.length;
		for (const b of bytes) {
			if (c.inEscape) {
				c.inEscape = b < "@".code || b > "~".code || b == "[".code;
			} else if (b == 0x1B) {
				c.inEscape = true;
			} else if (b == "L".code) {
				c.inNumber = true;
				c.number = 0;
				c.hasDigits = false;
			} else if (c.inNumber && b >= "0".code && b <= "9".code) {
				const leadingZero = c.hasDigits && c.number == 0;
				const canMatch = c.number >= 0 && c.number <= c.linesInOrder && !leadingZero;
				c.number = canMatch ? c.number * 10 + (b - "0".code) : CANNOT_MATCH;
				c.hasDigits = true;
			} else if (c.inNumber) {
				const ended = b == ".".code && c.hasDigits;
				if (ended && c.number == c.linesInOrder) { c.linesInOrder++; }
				c.inNumber = false;
			}
		}
		return c;
	}

	test "the flood check counts a line ended by a cursor move, not a newline, and skips its escapes" {
		const text = "\x1b]0;cmd\x07line L0.\x1b[2;1Hline\x1b[1CL1.\x1b[K\r\nline L3.\r\nline L2.\r\n";
		assert NO_LINES.feed(text.asBytes()).linesInOrder == 3;
	}

	test "the flood check counts no line whose number has a leading zero or runs past the count" {
		const text = "L0.L01.L99999999999999999999999999.L1.";
		assert NO_LINES.feed(text.asBytes()).linesInOrder == 2;
	}

	test "output past the read buffer's limit arrives whole and in order while the app reads late" {
		const path = `${tmpDir()}/haroPtyFlood${getpid()}.txt`;
		let text = "";
		const count = 400000;
		for (let i = 0; i < count; i++) { text += `line L${i}.\r\n`; }
		text += "end";
		assert writeFile(path, text).ok;
		const opened = NativePty.open(printFile(path), 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			const late: float64 = performance.now();
			while (performance.now() - late < 1500) {}
			let buf: Vec<uint8> = new Array(65536);
			let check = NO_LINES;
			while (true) {
				const ready = p.wait(10000);
				if (!ready.ok || !ready.value) { break; }
				const r = p.read(buf);
				if (!r.ok) { break; }
				check = check.feed(buf[0..r.value]);
			}
			const inOrder = `${check.linesInOrder} of ${count} lines in order`;
			console.log(`flood: ${check.byteCount} bytes, ${inOrder}`);
			const readLimit = 4 << 20;
			assert check.byteCount > readLimit;
			assert check.linesInOrder == count;
			p.close();
		}
		const _gone = remove(path);
	}
}
