import { basename } from "std/fs/path";

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

function bashLaunch(program: string, flags: string[], scripts: string): ShellLaunch {
	const login = flags.includes("-l") || flags.includes("--login");
	const interactive = flags.includes("-i") ? " -i" : "";
	return {
		commandLine: `${program} --rcfile ${quoted(`${scripts}/bash/haro.bash`)}${interactive}`,
		env: [`HARO_BASH_LOGIN=${login ? "1" : ""}`],
	};
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
	return match (basename(program)) {
		"zsh" => zshLaunch(commandLine, scripts, inherited("ZDOTDIR")),
		"bash" => bashLaunch(words[0], flags, scripts),
		"fish" => fishLaunch(commandLine, scripts, inherited("XDG_DATA_DIRS")),
		_ => untouched,
	};
}

function inheritedOf(shell: string, zdotdir: string): (name: string) => string {
	return (name: string): string => {
		return match (name) {
			"SHELL" => shell,
			"ZDOTDIR" => zdotdir,
			_ => "",
		};
	};
}

test "a zsh started from SHELL loads Haro's zshenv first and keeps the user's ZDOTDIR to restore" {
	const shells = inheritedOf("/bin/zsh", "/me/zsh");
	const got = launchOf("${SHELL:-/bin/zsh} -l", "/haro/shell", shells);
	assert got.commandLine == "${SHELL:-/bin/zsh} -l";
	assert got.env.join(" ") == "ZDOTDIR=/haro/shell/zsh HARO_ZDOTDIR=/me/zsh";
}

test "an empty SHELL falls back to the default the command names" {
	const got = launchOf("${SHELL:-/bin/zsh} -l", "/haro/shell", inheritedOf("", ""));
	assert got.env.join(" ") == "ZDOTDIR=/haro/shell/zsh HARO_ZDOTDIR=";
}

test "a bash login shell reads Haro's rc file, which sources the login files itself" {
	const got = launchOf("$SHELL --login", "/it's/shell", inheritedOf("/opt/bin/bash", ""));
	assert got.commandLine == "$SHELL --rcfile '/it'\\''s/shell/bash/haro.bash'";
	assert got.env.join(" ") == "HARO_BASH_LOGIN=1";
	const plainBash = launchOf("/bin/bash -i", "/haro", inheritedOf("", ""));
	assert plainBash.commandLine == "/bin/bash --rcfile '/haro/bash/haro.bash' -i";
	assert plainBash.env.join(" ") == "HARO_BASH_LOGIN=";
}

test "a fish finds Haro's vendor directory ahead of the default data directories" {
	const got = launchOf("fish", "/haro/shell", inheritedOf("", ""));
	assert got.commandLine == "fish";
	assert got.env.join(" ") ==
		"XDG_DATA_DIRS=/haro/shell:/usr/local/share:/usr/share HARO_XDG_DATA_DIRS=";
}

test "an unknown shell, a command with arguments or shell syntax is left untouched" {
	const shells = inheritedOf("/bin/zsh", "");
	const commands = ["/bin/sh -l", "zsh -c 'echo hi'", "cd /tmp; zsh", "FOO=1 zsh", "nu", ""];
	for (const command of commands) {
		const got = launchOf(command, "/haro", shells);
		assert got.commandLine == command;
		assert got.env.length == 0;
	}
}
