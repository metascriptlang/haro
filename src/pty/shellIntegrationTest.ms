import { NativePty, close, open, read, wait, write } from "./pty";
import { Vt, dropReplies, pendingReplies, pwd, takeEvents, write as feed } from "../vt/vt";
import { ShellMark, ShellStep } from "../vt/vtEffects";
import { withVt } from "../vt/vtRig";
import { cwd, env } from "std/process";
import { ensureDir, removeAll, writeFile } from "std/fs";
import { bashMajorOf } from "./shellIntegration";
import { bash5OnPath } from "./ptyRig";
import { tmpDir } from "std/os";

const SCRIPTS = `${cwd()}/assets/shell`;
const WAIT_MS: float64 = 20000;

interface Seen {
	marks: Vec<ShellMark>;
	text: string;
}

function pumpUntil(p: NativePty, vt: Vt, seen: Seen, done: (s: Seen) => boolean): boolean {
	let buf: Vec<uint8> = new Array(16384);
	const deadline = performance.now() + WAIT_MS;
	while (!done(seen) && performance.now() < deadline) {
		const ready = p.wait(100);
		if (!ready.ok) { return done(seen); }
		if (!ready.value) { continue; }
		const r = p.read(buf);
		if (!r.ok) { return done(seen); }
		const chunk = buf[0..r.value];
		vt.feed(chunk);
		seen.text += chunk.asString();
		for (const m of vt.takeEvents().shell) { seen.marks.push(m); }
		const replies = vt.pendingReplies();
		if (replies.length > 0) {
			const _sent = p.write(replies);
			vt.dropReplies();
		}
	}
	return done(seen);
}

function prompts(s: Seen): int32 {
	return s.marks.filter((m: ShellMark): boolean => m.step === ShellStep.Prompt).length;
}

function finished(s: Seen): Vec<string> {
	let done: Vec<string> = [];
	for (const m of s.marks) {
		if (m.step === ShellStep.CommandDone) {
			done.push(`${m.done.exitCode ?? -1} ${m.done.command}`);
		}
	}
	return done;
}

interface Run {
	opened: boolean;
	reached: boolean;
	seen: Seen;
	pwd: string;
}

function homeWith(files: string[]): string {
	const home = `${tmpDir()}/haroShellHome${performance.now()}`;
	const _made = ensureDir(`${home}/zdot`);
	for (let i = 0; i + 1 < files.length; i += 2) {
		const _written = writeFile(`${home}/${files[i]}`, files[i + 1]);
	}
	return home;
}

function run(
	command: string,
	scripts: string | null,
	typed: string,
	done: (s: Seen) => boolean,
	ready: string = "\x1b]133;A",
): Run {
	let got: Run = { opened: false, reached: false, seen: { marks: [], text: "" }, pwd: "" };
	const _vt = withVt(80, 24, (vt: Vt): void => {
		const opened = NativePty.open(command, 80, 24, null, 0, 0, scripts);
		if (!opened.ok) { return; }
		got.opened = true;
		const p = opened.value;
		defer p.close();
		const first = (s: Seen): boolean => s.text.includes(ready) || prompts(s) == 1;
		if (!pumpUntil(p, vt, got.seen, first) || !p.write(typed.asBytes()).ok) { return; }
		got.reached = pumpUntil(p, vt, got.seen, done);
		const dir = vt.pwd();
		if (dir.ok) { got.pwd = dir.value; }
		if (p.write("exit\r".asBytes()).ok) {
			const _ended = pumpUntil(p, vt, got.seen, (s: Seen): boolean => false);
		}
	});
	return got;
}

function promptAgain(s: Seen): boolean { return prompts(s) >= 2; }

function promptAfterDone(s: Seen): boolean {
	const last = s.marks.length - 1;
	return last > 0 && s.marks[last].step === ShellStep.Prompt &&
		s.marks[last - 1].step === ShellStep.CommandDone;
}

function times(text: string, part: string): int32 {
	return text.split(part).length - 1;
}

const BASH3 = "/bin/bash";

function bashes(): Vec<string> {
	let found: Vec<string> = [BASH3];
	const bash5 = bash5OnPath();
	if (bash5 !== null) { found.push(bash5); }
	return found;
}

function inHome(home: string, zdotdir: string, body: () => Run): Run {
	const inheritedHome = env.get("HOME");
	const inheritedZdotdir = env.get("ZDOTDIR");
	defer {
		const _backHome = env.set("HOME", inheritedHome);
		const _backZdotdir = inheritedZdotdir == "" ?
			env.delete("ZDOTDIR") :
			env.set("ZDOTDIR", inheritedZdotdir);
		const _removed = removeAll(home);
	}
	const _home = env.set("HOME", home);
	const _zdotdir = zdotdir == "" ? env.delete("ZDOTDIR") : env.set("ZDOTDIR", zdotdir);
	return body();
}

test "a zsh under Haro marks its prompt and a failed command, and still loads the user's files" {
	const home = homeWith([
		"zdot/.zshenv", "export HARO_TEST_ENV=env-ran\n",
		"zdot/.zshrc", "print \"rc:$HARO_TEST_ENV:$ZDOTDIR\"\n",
	]);
	const got = inHome(home, `${home}/zdot`, (): Run => {
		return run("/bin/zsh -l", SCRIPTS, "(exit 3)\r", promptAgain);
	});
	assert got.reached;
	assert finished(got.seen).join("|") == "3 (exit 3)";
	assert got.seen.text.includes(`rc:env-ran:${home}/zdot`);
	assert got.pwd.startsWith("file://") && got.pwd.endsWith(cwd());
}

test "a bash login shell stays a login shell, reads its profile once and marks a command" {
	for (const bash of bashes()) {
		const home = homeWith([
			".bash_profile", "echo \"profile:$((40 + 2)):$(shopt -q login_shell && echo on)\"\n",
		]);
		const got = inHome(home, "", (): Run => {
			return run(`${bash} -l`, SCRIPTS, "\r(exit 3)\r", promptAfterDone);
		});
		assert got.reached;
		assert finished(got.seen).join("|") == "3 (exit 3)";
		assert times(got.seen.text, "profile:42:on") == 1;
		assert got.pwd.startsWith("file://") && got.pwd.endsWith(cwd());
	}
}

test "an interactive bash under Haro reads the user's bashrc and names a subshell command" {
	for (const bash of bashes()) {
		const home = homeWith([".bashrc", "echo \"bashrc:$((40 + 2))\"\n"]);
		const got = inHome(home, "", (): Run => {
			return run(bash, SCRIPTS, "sh -c 'exit 3'\r", promptAfterDone);
		});
		assert got.reached;
		assert finished(got.seen).join("|") == "3 sh -c 'exit 3'";
		assert times(got.seen.text, "bashrc:42") == 1;
	}
}

test "a bash 4 or later under Haro keeps its history in .bash_history and does not export it" {
	const bash5 = bash5OnPath();
	if (bash5 === null) {
		console.log("skipped: no bash 5 on PATH");
		return;
	}
	const inherited = env.get("HISTFILE");
	defer {
		const _back = inherited == "" ? env.delete("HISTFILE") : env.set("HISTFILE", inherited);
	}
	const _unset = env.delete("HISTFILE");
	const home = homeWith([".bashrc", ""]);
	const got = inHome(home, "", (): Run => {
		return run(
			bash5,
			SCRIPTS,
			"echo \"hist:$HISTFILE:$(sh -c 'echo ${HISTFILE-unset}')\"\r",
			promptAfterDone,
		);
	});
	assert got.reached;
	assert times(got.seen.text, `hist:${home}/.bash_history:unset`) == 1;
}

test "a bash 3 whose bashrc replaces PROMPT_COMMAND loses the marks" {
	const home = homeWith([".bashrc", "PROMPT_COMMAND=true\necho \"bashrc:$((40 + 2))\"\n"]);
	const got = inHome(home, "", (): Run => {
		const typed = "(exit 3); echo \"after:$((40 + 2))\"\r";
		const after = (s: Seen): boolean => s.text.includes("after:42");
		return run(BASH3, SCRIPTS, typed, after, "bashrc:42");
	});
	assert got.reached;
	assert got.seen.text.includes("bashrc:42");
	assert got.seen.marks.length == 0;
}

test "the bash version probe answers within its bound" {
	for (const bash of bashes()) {
		let slowest: float64 = 0;
		for (let i = 0; i < 5; i++) {
			const start: float64 = performance.now();
			const major = bashMajorOf(bash);
			slowest = Math.max(slowest, performance.now() - start);
			assert major !== null && major >= 3;
		}
		console.log(`bash version probe: ${bash} slowest of 5 in ${Math.round(slowest)} ms`);
		assert slowest < 500;
	}
}

test "a shell started with integration off emits no marks" {
	const home = homeWith(["zdot/.zshrc", "print \"rc:$((40 + 2))\"\n"]);
	const got = inHome(home, `${home}/zdot`, (): Run => {
		const typed = "(exit 3); echo \"after:$((40 + 2))\"\r";
		const after = (s: Seen): boolean => s.text.includes("after:42");
		return run("/bin/zsh -l", null, typed, after, "rc:42");
	});
	assert got.reached;
	assert got.seen.text.includes("rc:42");
	assert got.seen.marks.length == 0;
}
