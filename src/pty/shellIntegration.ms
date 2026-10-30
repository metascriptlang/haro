import { basename } from "std/fs/path";
import { ChildStream, spawn } from "std/process";

export struct ShellLaunch {
	commandLine: string;
	env: Vec<string>;
}

const STARTUP_FLAGS = ["-l", "--login", "-i"];
const SHELL_SYNTAX = "'\"\\$`;&|<>()*?[]{}=#";
const SHELL_FALLBACK = "${SHELL:-";
const XDG_DATA_DEFAULT = "/usr/local/share:/usr/share";

function wordsOf(commandLine: string): Vec<string> {
	let words: Vec<string> = [];
	for (const word of commandLine.replaceAll("\t", " ").replaceAll("\n", " ").split(" ")) {
		if (word != "") { words.push(word); }
	}
	return words;
}

function plain(word: string): boolean {
	if (word == "") { return false; }
	for (let i = 0; i < SHELL_SYNTAX.length; i++) {
		if (word.includes(SHELL_SYNTAX.charAt(i))) { return false; }
	}
	return true;
}

function programOf(word: string, inherited: (name: string) => string): string | null {
	if (word == "$SHELL" || word == "${SHELL}") { return inherited("SHELL"); }
	if (word.startsWith(SHELL_FALLBACK) && word.endsWith("}")) {
		const otherwise = word.slice(SHELL_FALLBACK.length, word.length - 1);
		if (!plain(otherwise)) { return null; }
		const shell = inherited("SHELL");
		return shell != "" ? shell : otherwise;
	}
	return plain(word) ? word : null;
}

function quoted(text: string): string {
	return `'${text.replaceAll("'", "'\\''")}'`;
}

function zshLaunch(commandLine: string, scripts: string, zdotdir: string): ShellLaunch {
	return {
		commandLine: commandLine,
		env: [`ZDOTDIR=${scripts}/zsh`, `HARO_ZDOTDIR=${zdotdir}`],
	};
}

const POSIX_ENV_MAJOR = 4;
const PROBE_MS: float64 = 500;

function bashLaunch(
	program: string,
	flags: string[],
	scripts: string,
	major: int32,
	inherited: (name: string) => string,
): ShellLaunch {
	if (major >= POSIX_ENV_MAJOR) {
		const given = flags.length > 0 ? ` ${flags.join(" ")}` : "";
		let env: Vec<string> = [`ENV=${scripts}/bash/posix.bash`, `HARO_ENV=${inherited("ENV")}`];
		if (inherited("HISTFILE") == "" && inherited("HOME") != "") {
			env.push(`HISTFILE=${inherited("HOME")}/.bash_history`);
			env.push("HARO_BASH_UNEXPORT_HISTFILE=1");
		}
		return { commandLine: `${program} --posix${given}`, env: env };
	}
	const boot = `. ${quoted(`${scripts}/bash/prompt.bash`)}`;
	const chain = inherited("PROMPT_COMMAND");
	return {
		commandLine: `${program}${flags.length > 0 ? ` ${flags.join(" ")}` : ""}`,
		env: [
			`PROMPT_COMMAND=${chain != "" ? `${boot}\n${chain}` : boot}`,
			`HARO_BASH_BOOT=${boot}`,
			`HARO_PROMPT_COMMAND=${chain}`,
		],
	};
}

function majorOf(text: string): int32 | null {
	const digits = text.trim();
	if (digits == "" || digits.length > 3) { return null; }
	let major = 0;
	for (let i = 0; i < digits.length; i++) {
		const c = digits.charCodeAt(i);
		if (c < "0".code || c > "9".code) { return null; }
		major = major * 10 + (c - "0".code);
	}
	return major;
}

export function bashMajorOf(program: string): int32 | null {
	const started = spawn(program, ["-c", "echo ${BASH_VERSINFO[0]}"]);
	if (!started.ok) { return null; }
	const child = started.value;
	defer child.close();
	const deadline = performance.now() + PROBE_MS;
	let text = "";
	while (true) {
		const left = deadline - performance.now();
		if (left <= 0) { return null; }
		const got = child.read(ChildStream.Stdout, left as int32);
		if (!got.ok) { return null; }
		if (got.value.ended) { break; }
		text += got.value.data;
	}
	const left = deadline - performance.now();
	if (left <= 0) { return null; }
	const exited = child.wait(left as int32);
	if (!exited.ok || exited.value.code != 0) { return null; }
	return majorOf(text);
}

function fishLaunch(commandLine: string, scripts: string, dataDirs: string): ShellLaunch {
	return {
		commandLine: commandLine,
		env: [
			`XDG_DATA_DIRS=${scripts}:${dataDirs != "" ? dataDirs : XDG_DATA_DEFAULT}`,
			`HARO_XDG_DATA_DIRS=${dataDirs}`,
		],
	};
}

export function launchOf(
	commandLine: string,
	scripts: string,
	inherited: (name: string) => string,
	bashMajor: (program: string) => int32 | null,
): ShellLaunch {
	const untouched: ShellLaunch = { commandLine: commandLine, env: [] };
	const words = wordsOf(commandLine);
	if (words.length == 0) { return untouched; }
	const program = programOf(words[0], inherited);
	if (program === null) { return untouched; }
	const flags = words.slice(1, words.length);
	for (const flag of flags) {
		if (!STARTUP_FLAGS.includes(flag)) { return untouched; }
	}
	const name = basename(program);
	return match (name) {
		"bash" => {
			const major = bashMajor(program);
			if (major === null) { return untouched; }
			bashLaunch(words[0], flags, scripts, major, inherited)
		},
		"zsh" => zshLaunch(commandLine, scripts, inherited("ZDOTDIR")),
		"fish" => fishLaunch(commandLine, scripts, inherited("XDG_DATA_DIRS")),
		_ => untouched,
	};
}

function inheritedOf(shell: string, zdotdir: string): (name: string) => string {
	return (name: string): string => {
		return match (name) {
			"SHELL" => shell,
			"ZDOTDIR" => zdotdir,
			"PROMPT_COMMAND" => "history -a",
			_ => "",
		};
	};
}

function bashOf(major: int32 | null): (program: string) => int32 | null {
	return (program: string): int32 | null => { return major; };
}

const BASH5 = bashOf(5);

test "a zsh started from SHELL loads Haro's zshenv first and keeps the user's ZDOTDIR to restore" {
	const shells = inheritedOf("/bin/zsh", "/me/zsh");
	const got = launchOf("${SHELL:-/bin/zsh} -l", "/haro/shell", shells, BASH5);
	assert got.commandLine == "${SHELL:-/bin/zsh} -l";
	assert got.env.join(" ") == "ZDOTDIR=/haro/shell/zsh HARO_ZDOTDIR=/me/zsh";
}

test "an empty SHELL falls back to the default the command names" {
	const got = launchOf("${SHELL:-/bin/zsh} -l", "/haro/shell", inheritedOf("", ""), BASH5);
	assert got.env.join(" ") == "ZDOTDIR=/haro/shell/zsh HARO_ZDOTDIR=";
}

test "a bash from 4 on starts in posix mode, keeping its flags, and reads Haro's script as ENV" {
	const got = launchOf("$SHELL --login", "/haro", inheritedOf("/opt/bin/bash", ""), BASH5);
	assert got.commandLine == "$SHELL --posix --login";
	assert got.env.join(" ") == "ENV=/haro/bash/posix.bash HARO_ENV=";
	const plainBash = launchOf("/bin/bash", "/haro", inheritedOf("", ""), BASH5);
	assert plainBash.commandLine == "/bin/bash --posix";
}

test "a bash 3 keeps its command and loads Haro's script from its first prompt command" {
	const got = launchOf("/bin/bash -l", "/it's", inheritedOf("", ""), bashOf(3));
	assert got.commandLine == "/bin/bash -l";
	const boot = ". '/it'\\''s/bash/prompt.bash'";
	assert got.env.join("|") ==
		`PROMPT_COMMAND=${boot}\nhistory -a|HARO_BASH_BOOT=${boot}|HARO_PROMPT_COMMAND=history -a`;
}

test "a bash whose version cannot be read is left untouched" {
	const got = launchOf("bash -l", "/haro", inheritedOf("", ""), bashOf(null));
	assert got.commandLine == "bash -l";
	assert got.env.length == 0;
	assert bashMajorOf("/no/such/bash") === null;
	assert bashMajorOf("/usr/bin/true") === null;
}

test "a fish finds Haro's vendor directory ahead of the default data directories" {
	const got = launchOf("fish", "/haro/shell", inheritedOf("", ""), BASH5);
	assert got.commandLine == "fish";
	assert got.env.join(" ") ==
		"XDG_DATA_DIRS=/haro/shell:/usr/local/share:/usr/share HARO_XDG_DATA_DIRS=";
}

test "an unknown shell, a command with arguments or shell syntax is left untouched" {
	const shells = inheritedOf("/bin/zsh", "");
	const commands = ["/bin/sh -l", "zsh -c 'echo hi'", "cd /tmp; zsh", "FOO=1 zsh", "nu", ""];
	for (const command of commands) {
		const got = launchOf(command, "/haro", shells, BASH5);
		assert got.commandLine == command;
		assert got.env.length == 0;
	}
}
