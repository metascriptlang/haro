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
import { Pty, PtyError } from "./transport";

extern function ptyOpen(commandLine: cstring, cwd: cstring, cols: int32, rows: int32): int32;
extern function ptyRead(id: int32, buf: Span<uint8>): int64;
extern function ptyWait(id: int32, timeoutMs: int32): int32;
extern function ptyWrite(id: int32, data: Span<uint8>): int64;
extern function ptyResize(id: int32, cols: int32, rows: int32): int32;
extern function ptyExited(id: int32): int32;
extern function ptyExitCode(id: int32): int32;
extern function ptyClose(id: int32): void;

export struct NativePty { id: int32; }

export function open(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
): Result<NativePty, PtyError> {
	const dir = cwd !== null && isDir(cwd) ? cwd : "";
	const id = ptyOpen(commandLine, dir, cols, rows);
	if (id < 0) { return Result.err(PtyError.OpenFailed); }
	return Result.ok({ id: id });
}

export function read(this p: NativePty, buf: Span<uint8>): Result<int32, PtyError> {
	const n = ptyRead(p.id, buf);
	return match (n) {
		-2 => Result.err(PtyError.OutOfMemory),
		_ when n < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(n as int32),
	};
}

export function wait(this p: NativePty, timeoutMs: int32): Result<boolean, PtyError> {
	const r = ptyWait(p.id, timeoutMs);
	return match (r) {
		-2 => Result.err(PtyError.WaitFailed),
		_ when r < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(r == 1),
	};
}

export function write(this p: NativePty, data: Span<uint8>): Result<int32, PtyError> {
	const n = ptyWrite(p.id, data);
	return match (n) {
		-2 => Result.err(PtyError.OutOfMemory),
		_ when n < 0 => Result.err(PtyError.Closed),
		_ => Result.ok(n as int32),
	};
}

export function resize(this p: NativePty, cols: int32, rows: int32): Result<NativePty, PtyError> {
	if (ptyResize(p.id, cols, rows) != 0) { return Result.err(PtyError.ResizeFailed); }
	return Result.ok(p);
}

export function exitCode(this p: NativePty): int32 | null {
	if (ptyExited(p.id) == 0) { return null; }
	return ptyExitCode(p.id);
}

export function close(this p: NativePty): void {
	ptyClose(p.id);
}

export function toPty(this p: NativePty): Pty {
	return {
		wait: (timeoutMs: int32): Result<boolean, PtyError> => { return p.wait(timeoutMs); },
		read: (buf: Span<uint8>): Result<int32, PtyError> => { return p.read(buf); },
		write: (data: Span<uint8>): Result<int32, PtyError> => { return p.write(data); },
		resize: (cols: int32, rows: int32): Result<void, PtyError> => {
			const _resized = try p.resize(cols, rows);
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return p.exitCode(); },
		close: (): void => { p.close(); },
		ownsScreen: true,
	};
}

export function spawn(
	this typeof NativePty,
	commandLine: string,
	cols: int32,
	rows: int32,
	cwd: string | null = null,
): Result<Pty, PtyError> {
	const opened = try NativePty.open(commandLine, cols, rows, cwd);
	return Result.ok(opened.toPty());
}

when (testBuild) {
	import { normalize, remove, writeFile } from "std/fs";
	import { tmpDir } from "std/os";
	import { drainText } from "./ptyTest";

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

	test "a resize of a live console succeeds and hands the pty back" {
		const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const resized = opened.value.resize(120, 40);
			assert resized.ok;
			if (resized.ok) { assert resized.value.id == opened.value.id; }
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
			assert pty.resize(100, 30).ok;
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
		digits: string;
		inNumber: boolean;
		inEscape: boolean;
		byteCount: int64;
	}

	const NO_LINES: LineCheck = {
		linesInOrder: 0,
		digits: "",
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
				c.digits = "";
			} else if (c.inNumber && b >= "0".code && b <= "9".code) {
				c.digits += String.fromCharCode(b as int32);
			} else if (c.inNumber) {
				if (b == ".".code && c.digits == `${c.linesInOrder}`) { c.linesInOrder++; }
				c.inNumber = false;
			}
		}
		return c;
	}

	test "the flood check counts a line ended by a cursor move, not a newline, and skips its escapes" {
		const text = "\x1b]0;cmd\x07line L0.\x1b[2;1Hline\x1b[1CL1.\x1b[K\r\nline L3.\r\nline L2.\r\n";
		assert NO_LINES.feed(text.asBytes()).linesInOrder == 3;
	}

	test "output past the read buffer's limit arrives whole and in order while the app reads late" {
		const path = `${tmpDir()}/haroPtyFlood.txt`;
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
