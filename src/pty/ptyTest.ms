import { PtyError } from "./transport";
import {
	NativePty,
	busy,
	close,
	exitCode,
	envBlock,
	exitSignal,
	jobRunning,
	mergedEnv,
	open,
	read,
	resize,
	sortedByName,
	spawn,
	toPty,
	wait,
	write,
} from "./pty";
import { ensureDir, normalize, remove, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";
import { bash5OnPath, drainText, withPty } from "./ptyRig";

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
		try p.read(buf);
	}
}

test "the child's environment keeps inherited entries and applies Haro's replacements, the given entries and the cwd" {
	const inherited: Vec<string> = [
		"PATH=/bin", "TERM=dumb", "TERM_PROGRAM=Other", "PWD=/old", "LANG=C", "EDITOR=vi",
	];
	const got = mergedEnv(inherited, ["LANG=fr", "ZDOTDIR=/z"] as Vec<string>, "/new");
	assert got.join("|") == "PATH=/bin|EDITOR=vi|TERM=xterm-256color|COLORTERM=truecolor|" +
		"TERM_PROGRAM=Haro|LANG=fr|ZDOTDIR=/z|PWD=/new";
	const keptPwd = mergedEnv(inherited, [] as Vec<string>, "");
	assert keptPwd.includes("PWD=/old");
	assert !keptPwd.some((entry: string): boolean => entry.startsWith("PWD=/new"));
}

test "on Windows a given or Haro entry replaces an inherited one whatever its letter case" {
	const inherited: Vec<string> = ["Path=C:\\old", "Term=dumb", "term_program=Other", "SystemRoot=C:\\W"];
	const got = mergedEnv(inherited, ["PATH=C:\\new"] as Vec<string>, "", true);
	assert got.join("|") == "SystemRoot=C:\\W|TERM=xterm-256color|COLORTERM=truecolor|" +
		"TERM_PROGRAM=Haro|PATH=C:\\new";
	const exact = mergedEnv(["Path=1"] as Vec<string>, ["PATH=2"] as Vec<string>, "");
	assert exact.join("|").startsWith("Path=1|");
}

test "entries are ordered by upper-cased name, as CreateProcess requires of an environment block" {
	const got = sortedByName(["b=1", "Zed=2", "=C:=C:\\x", "alpha=3", "Beta=4", "A_=5"] as Vec<string>);
	assert got.join("|") == "=C:=C:\\x|alpha=3|A_=5|b=1|Beta=4|Zed=2";
}

test "an environment block is each entry NUL-terminated, bytes in UTF-8" {
	const block = envBlock(["A=1", "é=2"] as Vec<string>);
	assert block.length == 3 + 1 + 4 + 1;
	assert block[3] == 0 && block[block.length - 1] == 0;
	assert block[4] == 0xc3 && block[5] == 0xa9;
}

test "a Windows shell tree is idle when only shells are in it and busy when anything else runs" {
	assert !jobRunning("pwsh.exe\n");
	assert !jobRunning("CMD.EXE\n");
	assert !jobRunning("bash.exe\nsh\n");
	assert !jobRunning("");
	assert jobRunning("cmd.exe\nping.exe\n");
	assert jobRunning("wsl.exe\n");
	assert jobRunning("PowerShell.exe\nnode.EXE\n");
}

test "a child's output reaches read and its exit ends the stream" {
	assert withPty(ECHO_HELLO, (p: NativePty): void => {
		const text = p.toPty().drainText(4096);
		assert text.ok, text.error;
		if (text.ok) { assert text.value.includes("hello"); }
		assert p.exitCode() === 0;
	});
}

test "a wait returns as soon as the child writes" {
	assert withPty(ECHO_HELLO, (p: NativePty): void => {
		const start: float64 = performance.now();
		const ready = p.wait(10000);
		assert ready.ok;
		if (ready.ok) { assert ready.value; }
		assert performance.now() - start < 5000;
	});
}

test "a wait on a quiet child sleeps until its timeout" {
	assert withPty(QUIET_FOR_3S, (p: NativePty): void => {
		const waited = p.quietWaitMs(300);
		assert waited.ok;
		if (waited.ok) { assert waited.value >= 250; }
		assert p.exitCode() === null;
	});
}

test "a resize of a live console succeeds" {
	assert withPty(QUIET_FOR_3S, (p: NativePty): void => {
		assert p.resize(120, 40).ok;
	});
}

test "the table holds sixteen ptys with distinct ids and refuses a seventeenth" {
	let held: Vec<NativePty> = [];
	defer { for (const p of held) { p.close(); } }
	let ids = new Set<int32>();
	for (let i = 0; i < 16; i++) {
		const opened = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			held.push(opened.value);
			ids.add(opened.value.id);
		}
	}
	assert ids.size == 16;
	const seventeenth = NativePty.open(QUIET_FOR_3S, 80, 24);
	assert !seventeenth.ok;
	if (!seventeenth.ok) { assert seventeenth.error == PtyError.OpenTableFull; }
}

when (windows) {
	test "a command that cannot start is an error" {
		const opened = NativePty.open(MISSING_PROGRAM, 80, 24);
		assert !opened.ok;
	}
} else {
	test "a command the shell cannot find shows the shell's reason and exits 127" {
		assert withPty(MISSING_PROGRAM, (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes(MISSING_PROGRAM); }
			assert p.exitCode() === 127;
		});
	}
}

test "an empty command is refused as blank" {
	const opened = NativePty.open("  ", 80, 24);
	assert !opened.ok;
	if (!opened.ok) { assert opened.error == PtyError.OpenBlankCommand; }
}

test "a closed pty's id refuses read, write and close and never reaches the pty that took its slot" {
	const first = NativePty.open(QUIET_FOR_3S, 80, 24);
	assert first.ok;
	if (first.ok) {
		const stale = first.value;
		stale.close();
		const second = NativePty.open(QUIET_FOR_3S, 80, 24);
		assert second.ok;
		if (second.ok) {
			const live = second.value;
			let buf: Vec<uint8> = new Array(16);
			const bytes: Vec<uint8> = [0x78];
			assert !stale.read(buf).ok;
			assert !stale.write(bytes).ok;
			assert !stale.wait(0).ok;
			stale.close();
			assert live.exitCode() === null;
			assert live.write(bytes).ok;
			live.close();
		}
	}
}

test "a native pty starts its command in the directory it is given" {
	const dir = normalize(tmpDir());
	const spawned = NativePty.spawn(PRINT_DIRECTORY, 80, 24, dir);
	assert spawned.ok;
	if (spawned.ok) {
		const drained = spawned.value.drainText(4096);
		assert drained.ok, drained.error;
		if (drained.ok) {
			const out = drained.value.replaceAll("\\", "/");
			when (windows) {
				assert out.toLowerCase().includes(`[${dir.toLowerCase()}]`);
			} else {
				assert out.includes(`[${dir}]`);
			}
		}
		spawned.value.close();
	}
}

test "a directory that does not exist is skipped and the command still runs" {
	const spawned = NativePty.spawn(ECHO_HELLO, 80, 24, "/no/such/haro/directory");
	assert spawned.ok;
	if (spawned.ok) {
		const out = spawned.value.drainText(4096);
		assert out.ok, out.error;
		if (out.ok) { assert out.value.includes("hello"); }
		spawned.value.close();
	}
}

when (!windows) {
	import { env } from "std/process";

	extern function dup(fd: int32): int32;
	extern function dup2(from: int32, to: int32): int32;
	extern function closeFd(fd: int32): int32 from "close";

	test "a child does not inherit a descriptor the app holds without close-on-exec" {
		const leaked = 200;
		const spare = dup(2);
		assert spare >= 0;
		assert dup2(spare, leaked) == leaked;
		assert closeFd(spare) == 0;
		assert withPty("sh -c 'ls -1 /dev/fd'", (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) {
				const listing = out.value.split("\r\n");
				assert listing.includes("0");
				assert !listing.includes(`${leaked}`);
			}
		});
		assert closeFd(leaked) == 0;
	}


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
		assert withPty("sh -c 'exit 3'", (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			assert p.exitCode() === 3;
			assert !p.busy();
		});
	}

	function endOf(command: string): Result<string, string> {
		const opened = NativePty.open(command, 80, 24);
		if (!opened.ok) { return Result.err(`open failed: ${opened.error.toString()}`); }
		const p = opened.value;
		defer p.close();
		const drained = p.toPty().drainText(4096);
		if (!drained.ok) { return Result.err(drained.error); }
		return Result.ok(`${p.exitCode() ?? -1} ${p.exitSignal()}`);
	}

	test "a shell killed by a signal reports the signal apart from a status that only looks like one" {
		const killed = endOf("sh -c 'kill -KILL $$'");
		assert killed.ok, killed.error;
		if (killed.ok) { assert killed.value == "137 9"; }
		const lookalike = endOf("sh -c 'exit 137'");
		assert lookalike.ok, lookalike.error;
		if (lookalike.ok) { assert lookalike.value == "137 0"; }
		const clean = endOf("sh -c 'exit 0'");
		assert clean.ok, clean.error;
		if (clean.ok) { assert clean.value == "0 0"; }
	}

	function becomesBusy(this p: NativePty, wanted: boolean, withinMs: float64): boolean {
		const start: float64 = performance.now();
		while (p.busy() != wanted) {
			if (performance.now() - start > withinMs) { return false; }
		}
		return true;
	}

	test "a shell is busy while a job it runs holds the terminal, and idle back at its own read" {
		assert withPty("sh -c 'set -m; sleep 2; read line'", (p: NativePty): void => {
			assert p.becomesBusy(true, 5000);
			assert p.becomesBusy(false, 5000);
		});
	}

	test "a program a shell without job control runs stays in the shell's group and is not busy" {
		assert withPty("sh -c 'echo go; sleep 2; read line'", (p: NativePty): void => {
			assert p.readLine().includes("go");
			assert !p.becomesBusy(true, 1000);
		});
	}

	test "the child is told the terminal is Haro, not the one Haro was started from" {
		const inheritedProgram = env.get("TERM_PROGRAM");
		const inheritedSession = env.get("TERM_SESSION_ID");
		defer {
			const _program = env.set("TERM_PROGRAM", inheritedProgram);
			const _session = env.set("TERM_SESSION_ID", inheritedSession);
		}
		assert env.set("TERM_PROGRAM", "OtherTerminal");
		assert env.set("TERM_SESSION_ID", "w0t0");
		const printEnv = "sh -c 'echo \"[$TERM_PROGRAM|$TERM_SESSION_ID|$TERM]\"'";
		assert withPty(printEnv, (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes("[Haro||xterm-256color]"); }
		});
		assert env.get("TERM_PROGRAM") == "OtherTerminal";
	}

	function childLang(): Result<string, string> {
		const opened = NativePty.open("env", 80, 24);
		if (!opened.ok) { return Result.err(`open failed: ${opened.error.toString()}`); }
		defer opened.value.close();
		const out = try opened.value.toPty().drainText(65536);
		const langs = out.split("\r\n").filter((line: string): boolean => line.startsWith("LANG="));
		return Result.ok(langs.join("|"));
	}

	test "the child keeps an inherited LANG" {
		const inherited = env.get("LANG");
		defer { const _back = env.set("LANG", inherited); }
		assert env.set("LANG", "fr_FR.UTF-8");
		const lang = childLang();
		assert lang.ok, lang.error;
		if (lang.ok) { assert lang.value == "LANG=fr_FR.UTF-8"; }
	}

	when (macos) {
		import { preferredLang } from "./locale";

		test "a child started without a LANG gets one from the macOS locale preference" {
			const inherited = env.get("LANG");
			defer { const _back = env.set("LANG", inherited); }
			assert env.delete("LANG");
			const lang = childLang();
			assert lang.ok, lang.error;
			if (lang.ok) { assert lang.value == `LANG=${preferredLang()}`; }
			assert env.set("LANG", "");
			const blank = childLang();
			assert blank.ok, blank.error;
			if (blank.ok) { assert blank.value == `LANG=${preferredLang()}`; }
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
			assert out.ok, out.error;
			if (out.ok) {
				assert out.value.includes("(24, 80, 640, 384)");
				assert out.value.includes("(30, 100, 900, 540)");
			}
			p.close();
		}
	}

	test "closing returns at once while a job in its own session holds the terminal and reads nothing" {
		const job = "stty raw -echo; " +
			"perl -e 'use POSIX; exit 0 if fork(); POSIX::setsid(); sleep 6'";
		const opened = NativePty.open(job, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const p = opened.value;
			while (p.exitCode() === null) { const _ready = p.wait(100); }
			let chunk: Vec<uint8> = new Array(1048576);
			for (let i = 0; i < chunk.length; i++) { chunk[i] = 0x61; }
			assert p.write(chunk).ok;
			const start: float64 = performance.now();
			p.close();
			assert performance.now() - start < 3000;
		}
	}

	function closeMs(this p: NativePty): float64 {
		const start: float64 = performance.now();
		p.close();
		return performance.now() - start;
	}

	test "closing returns while the child writes to the terminal on its way out after hangup" {
		const trap = "trap 'head -c 200000 /dev/zero; exit' HUP; while :; do sleep 0.1; done";
		const opened = NativePty.open(trap, 80, 24);
		assert opened.ok;
		if (opened.ok) {
			const _quiet = opened.value.quietWaitMs(300);
			assert opened.value.closeMs() < 3000;
		}
	}

	function readUntil(this p: NativePty, wanted: string, withinMs: float64): boolean {
		let buf: Vec<uint8> = new Array(4096);
		let text = "";
		const start: float64 = performance.now();
		while (!text.includes(wanted) && performance.now() - start < withinMs) {
			const ready = p.wait(100);
			if (ready.ok && ready.value) {
				const r = p.read(buf);
				if (r.ok) { text += buf[0..r.value].asString(); }
			}
		}
		return text.includes(wanted);
	}

	function bashCloseMs(
		bash: string,
		flags: string,
		typed: string,
		waitForPrompt: boolean,
	): float64 {
		const home = `${normalize(tmpDir())}/haroBashHome${getpid()}`;
		if (!ensureDir(home).ok) { return -1; }
		const opened = NativePty.open(`HOME='${home}' ${bash} ${flags}`, 80, 24);
		let took: float64 = -1;
		if (opened.ok) {
			const p = opened.value;
			const prompted = p.readUntil("$ ", 5000);
			let bytes: Vec<uint8> = [...typed.asBytes()];
			const wrote = p.write(bytes).ok;
			const settled = !waitForPrompt || p.readUntil("$ ", 5000);
			const closed = p.closeMs();
			took = prompted && wrote && settled ? closed : -1;
		}
		const _removed = removeAll(home);
		return took;
	}

	test "closing returns right after exit is typed into a login shell" {
		const bash = bash5OnPath();
		if (bash !== null) {
			const took = bashCloseMs(bash, "-l", "exit\r", false);
			assert took >= 0 && took < 3000;
		}
	}

	test "closing returns right after a shell finishes a command" {
		const bash = bash5OnPath();
		if (bash !== null) {
			const took = bashCloseMs(bash, "", "sh -c 'exit 3'\r", true);
			assert took >= 0 && took < 3000;
		}
	}

	test "a command line means what it means to the shell, run in the start directory" {
		const dir = `${normalize(tmpDir())}/haroStartDir${getpid()}`;
		assert ensureDir(dir).ok;
		assert writeFile(`${dir}/only.md`, "").ok;
		const command = "cd . && echo got *.md ${HARO_UNSET_VAR:-fallback} end";
		const spawned = NativePty.spawn(command, 80, 24, dir);
		assert spawned.ok;
		if (spawned.ok) {
			const out = spawned.value.drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes("got only.md fallback end"); }
			spawned.value.close();
		}
		assert removeAll(dir).ok;
	}

	test "a shell that exits ends the stream, though a job in its own session still writes" {
		let ticks = "";
		for (let i = 0; i < 300; i++) { ticks += " x"; }
		const job = `setsid sh -c "for t in${ticks}; do echo spam; sleep 0.01; done"`;
		assert withPty(`sh -c '${job} & sleep 0.2; echo done'`, (p: NativePty): void => {
			const start: float64 = performance.now();
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes("done"); }
			assert performance.now() - start < 2500;
			assert p.exitCode() === 0;
		});
	}
}

when (windows) {
	test "a resize after the child exited is refused, since its console is already closed" {
		assert withPty(ECHO_HELLO, (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes("hello"); }
			assert p.exitCode() === 0;
			assert !p.resize(100, 30).ok;
		});
	}

	test "environment variables in the command line are expanded, as Windows shortcuts do" {
		assert withPty("%SystemRoot%\\System32\\cmd.exe /c echo hello", (p: NativePty): void => {
			const out = p.toPty().drainText(4096);
			assert out.ok, out.error;
			if (out.ok) { assert out.value.includes("hello"); }
		});
	}
}

test "a native pty spawned as a Pty reads its output and reports its exit through the interface" {
	const spawned = NativePty.spawn(ECHO_HELLO, 80, 24);
	assert spawned.ok;
	if (spawned.ok) {
		const pty = spawned.value;
		const out = pty.drainText(4096);
		assert out.ok, out.error;
		if (out.ok) { assert out.value.includes("hello"); }
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
	assert withPty(QUIET_FOR_3S, (p: NativePty): void => {
		let chunk: Vec<uint8> = new Array(1048576);
		for (let i = 0; i < chunk.length; i++) { chunk[i] = "a".code + (i % 26) as uint8; }
		const start: float64 = performance.now();
		for (let i = 0; i < 4; i++) { assert p.write(chunk).ok; }
		assert performance.now() - start < 200;
	});
}

test "input a child has not read stops being queued past its limit, and the write says so" {
	assert withPty(QUIET_FOR_3S, (p: NativePty): void => {
		let chunk: Vec<uint8> = new Array(1048576);
		for (let i = 0; i < chunk.length; i++) { chunk[i] = "a".code + (i % 26) as uint8; }
		let refused: PtyError | null = null;
		for (let i = 0; i < 40 && refused === null; i++) {
			const wrote = p.write(chunk);
			if (!wrote.ok) { refused = wrote.error; }
		}
		assert refused == PtyError.Backlogged;
	});
}

test "a line written to the child reaches it" {
	assert withPty(ECHO_LINE_READ, (p: NativePty): void => {
		let line: Vec<uint8> = [0x68, 0x69, 0x0D];
		assert p.write(line).ok;
		const out = p.toPty().drainText(4096);
		assert out.ok, out.error;
		if (out.ok) { assert out.value.includes("[hi]"); }
	});
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
	assert withPty(printFile(path), (p: NativePty): void => {
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
	});
	assert remove(path).ok;
}
