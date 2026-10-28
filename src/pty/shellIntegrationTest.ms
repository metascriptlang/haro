import { NativePty, close, open, read, wait, write } from "./pty";
import { Vt, pwd, takeEvents, takeReplies, write as feed } from "../vt/vt";
import { ShellMark, ShellStep } from "../vt/vtEffects";
import { withVt } from "../vt/vtRig";
import { cwd, env } from "std/process";
import { ensureDir, removeAll, writeFile } from "std/fs";
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
		const replies = vt.takeReplies();
		if (replies.length > 0) { const _sent = p.write(replies); }
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
): Run {
	let got: Run = { opened: false, reached: false, seen: { marks: [], text: "" }, pwd: "" };
	const _vt = withVt(80, 24, (vt: Vt): void => {
		const opened = NativePty.open(command, 80, 24, null, 0, 0, scripts);
		if (!opened.ok) { return; }
		got.opened = true;
		const p = opened.value;
		defer p.close();
		const first = (s: Seen): boolean => scripts === null || prompts(s) == 1;
		if (!pumpUntil(p, vt, got.seen, first) || !p.write(typed.asBytes()).ok) { return; }
		got.reached = pumpUntil(p, vt, got.seen, done);
		const dir = vt.pwd();
		if (dir.ok) { got.pwd = dir.value; }
		const _left = p.write("exit\r".asBytes());
	});
	return got;
}

function promptAgain(s: Seen): boolean { return prompts(s) >= 2; }

function inHome(home: string, zdotdir: string, body: () => Run): Run {
	const inheritedHome = env.get("HOME");
	const inheritedZdotdir = env.get("ZDOTDIR");
	const _home = env.set("HOME", home);
	const _zdotdir = zdotdir == "" ? env.delete("ZDOTDIR") : env.set("ZDOTDIR", zdotdir);
	const got = body();
	const _backHome = env.set("HOME", inheritedHome);
	const _backZdotdir = inheritedZdotdir == "" ?
		env.delete("ZDOTDIR") :
		env.set("ZDOTDIR", inheritedZdotdir);
	const _removed = removeAll(home);
	return got;
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

test "a bash login shell under Haro marks a failed command and still reads the login files" {
	const home = homeWith([".bash_profile", "echo \"profile:$((40 + 2))\"\n"]);
	const got = inHome(home, "", (): Run => {
		return run("/bin/bash -l", SCRIPTS, "sh -c 'exit 3'\r", promptAgain);
	});
	assert got.reached;
	assert finished(got.seen).join("|") == "3 sh -c 'exit 3'";
	assert got.seen.text.includes("profile:42");
	assert got.pwd.startsWith("file://") && got.pwd.endsWith(cwd());
}

test "an interactive bash under Haro reads the user's bashrc and names a subshell command" {
	const home = homeWith([".bashrc", "echo \"bashrc:$((40 + 2))\"\n"]);
	const got = inHome(home, "", (): Run => {
		return run("/bin/bash", SCRIPTS, "(exit 3)\r", promptAgain);
	});
	assert got.reached;
	assert finished(got.seen).join("|") == "3 (exit 3)";
	assert got.seen.text.includes("bashrc:42");
}

test "a shell started with integration off emits no marks" {
	const home = homeWith(["zdot/.zshrc", "print \"rc:$((40 + 2))\"\n"]);
	const got = inHome(home, `${home}/zdot`, (): Run => {
		const typed = "(exit 3); echo \"after:$((40 + 2))\"\r";
		return run("/bin/zsh -l", null, typed, (s: Seen): boolean => s.text.includes("after:42"));
	});
	assert got.reached;
	assert got.seen.text.includes("rc:42");
	assert got.seen.marks.length == 0;
}
