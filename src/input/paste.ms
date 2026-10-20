import { Action, CLIPBOARD_MODS, resolve } from "./bindings";

export enum Warning {
	None,
	MultiLine,
	EndMarker,
	Large,
}

export enum Tone {
	Title,
	Body,
	Dim,
	Code,
}

export enum Reply {
	Confirm,
	Cancel,
	Ignore,
}

export struct Line {
	text: string;
	tone: Tone;
}

export struct Dialog {
	top: Vec<Line>;
	code: Vec<Line>;
}

export interface Held {
	text: string;
	warning: Warning;
}

const LARGE_UNITS: int32 = 5 * 1024;
const END_MARKER = "\x1b[201~";
const TAB = "    ";
const ASK_BODY = "A program is attempting to read from the clipboard. The current clipboard contents are shown below.";

export function warningFor(text: string, bracketed: boolean): Warning {
	if (text.indexOf(END_MARKER) >= 0) { return Warning.EndMarker; }
	if (!bracketed && (text.indexOf("\n") >= 0 || text.indexOf("\r") >= 0)) { return Warning.MultiLine; }
	if (text.length > LARGE_UNITS) { return Warning.Large; }
	return Warning.None;
}

export function replyTo(code: string, mods: number): Reply {
	const held = (mods as int32) & 15;
	if (code == "Escape" && held == 0) { return Reply.Cancel; }
	if ((code == "Enter" || code == "NumpadEnter") && held == 0) { return Reply.Confirm; }
	if (resolve(code, mods, false) == Action.Paste) { return Reply.Confirm; }
	return Reply.Ignore;
}

export function replyToRead(code: string, mods: number): Reply {
	const held = (mods as int32) & 15;
	if (code == "Escape" && held == 0) { return Reply.Cancel; }
	if ((code == "Enter" || code == "NumpadEnter") && held == 0) { return Reply.Cancel; }
	if ((code == "Enter" || code == "NumpadEnter") && held == 2) { return Reply.Confirm; }
	return Reply.Ignore;
}

function wrap(text: string, cols: int32): Vec<string> {
	let out: Vec<string> = [];
	let line = "";
	for (const word of text.split(" ")) {
		if (line == "") {
			line = word;
		} else if (line.length + 1 + word.length <= cols) {
			line += " " + word;
		} else {
			out.push(line);
			line = word;
		}
	}
	if (line != "") { out.push(line); }
	return out;
}

export function visible(line: string, cols: int32): string {
	const cut = line.length > cols;
	const head = cut ? line.slice(0, cols) : line;
	let out = "";
	for (let i = 0; i < head.length; i++) {
		const c = head.charCodeAt(i);
		if (c == 9) {
			out += TAB;
		} else if (c < 32) {
			out += "^" + String.fromCharCode(c + 64);
		} else if (c == 127) {
			out += "^?";
		} else {
			out += head.charAt(i);
		}
	}
	if (!cut && out.length <= cols) { return out; }
	return out.slice(0, cols - 1) + "…";
}

function sizeOf(units: int32): string {
	if (units < 1024) { return units == 1 ? "1 character" : `${units} characters`; }
	const tenths = Math.round((units as float64) * 10 / 1024) as int32;
	return `${tenths / 10}.${tenths % 10} KiB`;
}

function title(warning: Warning): string {
	return match (warning) {
		Warning.Large => "Warning: large paste",
		_ => "Warning: potentially unsafe paste",
	};
}

function body(warning: Warning): string {
	return match (warning) {
		Warning.MultiLine => "You are about to paste text that contains multiple lines. If you paste this text into your shell, it may result in the unexpected execution of commands. Do you wish to continue?",
		Warning.EndMarker => "This text contains the sequence that ends a bracketed paste, so what follows it could run as commands the program never expected to receive. Do you wish to continue?",
		_ => "You are about to paste text that is longer than 5 KiB. Do you wish to continue?",
	};
}

function previewOf(text: string, cols: int32, maxCode: int32): Vec<Line> {
	const all = text.split("
");
	const total = all.length as int32;
	let code: Vec<Line> = [];
	const shown = Math.min(total, maxCode);
	for (let i = 0; i < shown; i++) { code.push({ text: visible(all[i], cols), tone: Tone.Code }); }
	const more = total - shown;
	if (more > 0) { code.push({ text: more == 1 ? "… 1 more line" : `… ${more} more lines`, tone: Tone.Dim }); }
	return code;
}

function measure(text: string): string {
	const total = text.split("
").length as int32;
	const count = total == 1 ? "1 line" : `${total} lines`;
	return `${count}, ${sizeOf(text.length as int32)}`;
}

export function dialogOf(warning: Warning, text: string, cols: int32, maxCode: int32): Dialog {
	let top: Vec<Line> = [{ text: title(warning), tone: Tone.Title }];
	for (const row of wrap(body(warning), cols)) { top.push({ text: row, tone: Tone.Body }); }
	top.push({ text: measure(text), tone: Tone.Dim });
	return { top: top, code: previewOf(text, cols, maxCode) };
}

export function askDialogOf(text: string, cols: int32, maxCode: int32): Dialog {
	let top: Vec<Line> = [{ text: "Authorize clipboard access", tone: Tone.Title }];
	for (const row of wrap(ASK_BODY, cols)) { top.push({ text: row, tone: Tone.Body }); }
	top.push({ text: measure(text), tone: Tone.Dim });
	return { top: top, code: previewOf(text, cols, maxCode) };
}

function line(text: string, tone: Tone): Line {
	return { text: text, tone: tone };
}

test "a line break is a warning only when the program has not asked for bracketed paste" {
	assert warningFor("one line", false) == Warning.None;
	assert warningFor("a\nb", false) == Warning.MultiLine;
	assert warningFor("a\rb", false) == Warning.MultiLine;
	assert warningFor("a\nb", true) == Warning.None;
}

test "the end of a bracketed paste inside the text is a warning in either mode" {
	assert warningFor("evil\x1b[201~rm", true) == Warning.EndMarker;
	assert warningFor("evil\x1b[201~rm", false) == Warning.EndMarker;
	assert warningFor("evil\x1b[201~a\nb", false) == Warning.EndMarker;
	assert warningFor("fine \x1b[31m red", true) == Warning.None;
}

test "more than five KiB is a warning in either mode and exactly five is not" {
	let big = "";
	for (let i = 0; i < 5 * 1024; i++) { big += "x"; }
	assert warningFor(big, false) == Warning.None;
	assert warningFor(big + "x", false) == Warning.Large;
	assert warningFor(big + "x", true) == Warning.Large;
	assert warningFor(big + "\n", false) == Warning.MultiLine;
}

test "enter and the paste chords confirm, escape cancels and everything else is ignored" {
	assert replyTo("Enter", 0) == Reply.Confirm;
	assert replyTo("NumpadEnter", 0) == Reply.Confirm;
	assert replyTo("KeyV", CLIPBOARD_MODS) == Reply.Confirm;
	when (!macos) {
		assert replyTo("Insert", 1) == Reply.Confirm;
	}
	assert replyTo("Escape", 0) == Reply.Cancel;
	assert replyTo("Enter", 1) == Reply.Ignore;
	assert replyTo("Escape", 2) == Reply.Ignore;
	assert replyTo("KeyV", 0) == Reply.Ignore;
	assert replyTo("KeyC", CLIPBOARD_MODS) == Reply.Ignore;
	assert replyTo("ShiftLeft", 1) == Reply.Ignore;
}

test "words wrap at the column count and never split" {
	const rows = wrap("aaa bbb ccc dddd", 7);
	assert rows.length == 3;
	assert rows[0] == "aaa bbb";
	assert rows[1] == "ccc";
	assert rows[2] == "dddd";
	assert wrap("", 10).length == 0;
}

test "control characters show as caret notation and a long line ends in an ellipsis" {
	assert visible("a\tb", 20) == "a    b";
	assert visible("x\x1b[31my", 20) == "x^[[31my";
	assert visible("\x03\x7f", 20) == "^C^?";
	assert visible("abcdefghij", 10) == "abcdefghij";
	assert visible("abcdefghijk", 10) == "abcdefghi…";
	assert visible("\x1b\x1b\x1b\x1b\x1b", 6) == "^[^[^…";
}

test "the dialog states what it asks, how big the text is, and previews its first lines" {
	const d = dialogOf(Warning.MultiLine, "ls\ncd ..\nrm -rf x\nexit", 40, 3);
	assert d.top[0] == line("Warning: potentially unsafe paste", Tone.Title);
	assert d.top[d.top.length - 1] == line("4 lines, 22 characters", Tone.Dim);
	assert d.top.length >= 4;
	assert d.code.length == 4;
	assert d.code[0] == line("ls", Tone.Code);
	assert d.code[2] == line("rm -rf x", Tone.Code);
	assert d.code[3] == line("… 1 more line", Tone.Dim);
}

test "a preview that fits shows no more-lines row and a large text says its size" {
	const small = dialogOf(Warning.EndMarker, "one\ntwo", 40, 8);
	assert small.code.length == 2;
	let big = "";
	for (let i = 0; i < 6000; i++) { big += "y"; }
	const d = dialogOf(Warning.Large, big, 30, 8);
	assert d.top[0].text == "Warning: large paste";
	assert d.top[d.top.length - 1].text == "1 line, 5.9 KiB";
	assert d.code.length == 1;
	assert d.code[0].text.length == 30;
	const many = dialogOf(Warning.MultiLine, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj", 30, 8);
	assert many.code.length == 9;
	assert many.code[8].text == "… 2 more lines";
}

test "a clipboard read is denied by escape or enter and allowed only by ctrl enter" {
	assert replyToRead("Escape", 0) == Reply.Cancel;
	assert replyToRead("Enter", 0) == Reply.Cancel;
	assert replyToRead("NumpadEnter", 0) == Reply.Cancel;
	assert replyToRead("Enter", 2) == Reply.Confirm;
	assert replyToRead("Enter", 3) == Reply.Ignore;
	assert replyToRead("KeyV", CLIPBOARD_MODS) == Reply.Ignore;
	assert replyToRead("KeyY", 0) == Reply.Ignore;
}

test "the read dialog names the access, says how big the clipboard is and previews it" {
	const d = askDialogOf("secret\ntoken", 40, 8);
	assert d.top[0] == line("Authorize clipboard access", Tone.Title);
	assert d.top[d.top.length - 1] == line("2 lines, 12 characters", Tone.Dim);
	assert d.code.length == 2;
	assert d.code[1] == line("token", Tone.Code);
}
