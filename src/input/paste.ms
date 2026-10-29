import { KeyMod, NO_MODS, modSet } from "../keys/keys";
import { Action, CLIPBOARD_MODS, chordOf, resolve } from "./bindings";

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

export struct Held {
	text: string;
	warning: Warning;
}

const LARGE_UNITS: int32 = 5 * 1024;
const END_MARKER = "\x1b[201~";
const TAB = "    ";
const CLOSE_TITLE = "A program is still running";
const CLOSE_BODY = "Close the window and end it?";
const ASK_BODY = "A program is attempting to read from the clipboard. " +
	"The current clipboard contents are shown below.";

export function warningFor(text: string, bracketed: boolean): Warning {
	if (text.includes(END_MARKER)) { return Warning.EndMarker; }
	const multiLine = text.includes("\n") || text.includes("\r");
	if (!bracketed && multiLine) { return Warning.MultiLine; }
	if (text.length > LARGE_UNITS) { return Warning.Large; }
	return Warning.None;
}

const CTRL_ONLY = modSet(KeyMod.Ctrl);

export function replyToClose(code: string, mods: BitSet<KeyMod>): Reply {
	const held = chordOf(mods);
	return match (code) {
		"Escape" when held == NO_MODS => Reply.Cancel,
		"Enter" | "NumpadEnter" when held == NO_MODS => Reply.Confirm,
		_ => Reply.Ignore,
	};
}

export function replyTo(code: string, mods: BitSet<KeyMod>): Reply {
	if (resolve(code, mods, false) == Action.Paste) { return Reply.Confirm; }
	return replyToClose(code, mods);
}

export function replyToRead(code: string, mods: BitSet<KeyMod>): Reply {
	const held = chordOf(mods);
	return match (code) {
		"Escape" | "Enter" | "NumpadEnter" when held == NO_MODS => Reply.Cancel,
		"Enter" | "NumpadEnter" when held == CTRL_ONLY => Reply.Confirm,
		_ => Reply.Ignore,
	};
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

function pairAt(text: string, at: int32): boolean {
	if (at < 0 || at + 1 >= text.length) { return false; }
	const high = text.charCodeAt(at);
	const low = text.charCodeAt(at + 1);
	return high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF;
}

function cutAt(text: string, units: int32): int32 {
	return pairAt(text, units - 1) ? units - 1 : units;
}

export function visible(line: string, cols: int32): string {
	const cut = line.length > cols;
	const head = cut ? line.slice(0, cutAt(line, cols)) : line;
	let out = "";
	for (let i = 0; i < head.length; i++) {
		if (pairAt(head, i)) {
			out += head.slice(i, i + 2);
			i++;
			continue;
		}
		const c = head.charCodeAt(i);
		out += match (c) {
			"\t".code => TAB,
			"\x7f".code => "^?",
			_ when c < 32 => "^" + String.fromCharCode(c + 64),
			_ => head.charAt(i),
		};
	}
	if (!cut && out.length <= cols) { return out; }
	return out.slice(0, cutAt(out, cols - 1)) + "…";
}

function sizeOf(units: int32): string {
	if (units < 1024) { return units == 1 ? "1 character" : `${units} characters`; }
	const tenths = Math.round((units as float64) * 10 / 1024) as int32;
	return `${tenths / 10}.${tenths % 10} KiB`;
}

function title(warning: Warning): string {
	return warning == Warning.Large ? "Warning: large paste" : "Warning: potentially unsafe paste";
}

function body(warning: Warning): string {
	if (warning == Warning.None) { throw new Error("a paste with Warning.None has no dialog body"); }
	return match (warning) {
		Warning.MultiLine => "You are about to paste text that contains multiple lines. " +
			"If you paste this text into your shell, it may result in the unexpected execution " +
			"of commands. Do you wish to continue?",
		Warning.EndMarker => "This text contains the sequence that ends a bracketed paste, " +
			"so what follows it could run as commands the program never expected to receive. " +
			"Do you wish to continue?",
		Warning.Large => "You are about to paste text that is longer than 5 KiB. Do you wish to continue?",
		Warning.None => "",
	};
}

function lineCount(text: string): int32 {
	let total: int32 = 1;
	for (let at = text.indexOf("\n"); at >= 0; at = text.indexOf("\n", at + 1)) { total += 1; }
	return total;
}

function previewOf(text: string, total: int32, cols: int32, maxCode: int32): Vec<Line> {
	let code: Vec<Line> = [];
	const shown = Math.min(total, maxCode);
	let from = 0;
	for (let i = 0; i < shown; i++) {
		const at = text.indexOf("\n", from);
		const end = at < 0 ? text.length : at;
		code.push({ text: visible(text.slice(from, end), cols), tone: Tone.Code });
		from = end + 1;
	}
	const more = total - shown;
	if (more > 0) {
		const rest = more == 1 ? "… 1 more line" : `… ${more} more lines`;
		code.push({ text: rest, tone: Tone.Dim });
	}
	return code;
}

function measure(text: string, total: int32): string {
	const count = total == 1 ? "1 line" : `${total} lines`;
	return `${count}, ${sizeOf(text.length as int32)}`;
}

function dialogWith(
	heading: string,
	message: string,
	text: string,
	cols: int32,
	maxCode: int32,
): Dialog {
	let top: Vec<Line> = [{ text: heading, tone: Tone.Title }];
	for (const row of wrap(message, cols)) { top.push({ text: row, tone: Tone.Body }); }
	const total = lineCount(text);
	top.push({ text: measure(text, total), tone: Tone.Dim });
	return { top: top, code: previewOf(text, total, cols, maxCode) };
}

export function dialogOf(warning: Warning, text: string, cols: int32, maxCode: int32): Dialog {
	return dialogWith(title(warning), body(warning), text, cols, maxCode);
}

export function askDialogOf(text: string, cols: int32, maxCode: int32): Dialog {
	return dialogWith("Authorize clipboard access", ASK_BODY, text, cols, maxCode);
}

export function closeDialogOf(cols: int32): Dialog {
	let top: Vec<Line> = [{ text: CLOSE_TITLE, tone: Tone.Title }];
	for (const row of wrap(CLOSE_BODY, cols)) { top.push({ text: row, tone: Tone.Body }); }
	return { top: top, code: [] };
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

const CTRL = modSet(KeyMod.Ctrl);
const SHIFT = modSet(KeyMod.Shift);

test "enter and the paste chords confirm, escape cancels and everything else is ignored" {
	assert replyTo("Enter", NO_MODS) == Reply.Confirm;
	assert replyTo("NumpadEnter", NO_MODS) == Reply.Confirm;
	assert replyTo("KeyV", CLIPBOARD_MODS) == Reply.Confirm;
	when (!macos) {
		assert replyTo("Insert", SHIFT) == Reply.Confirm;
	}
	assert replyTo("Escape", NO_MODS) == Reply.Cancel;
	assert replyTo("Enter", SHIFT) == Reply.Ignore;
	assert replyTo("Escape", CTRL) == Reply.Ignore;
	assert replyTo("KeyV", NO_MODS) == Reply.Ignore;
	assert replyTo("KeyC", CLIPBOARD_MODS) == Reply.Ignore;
	assert replyTo("ShiftLeft", SHIFT) == Reply.Ignore;
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

test "a line cut to the columns never splits a surrogate pair" {
	const pair = "\u{1F600}";
	assert pair.length == 2;
	assert visible("ab" + pair + "cdef", 3) == "ab…";
	assert visible("abcd" + pair + "ef", 5) == "abcd…";
	assert visible(pair + pair + pair, 3) == pair + "…";
	assert visible("a" + pair, 5) == "a" + pair;
}

test "a dialog for a paste with no warning is refused" {
	let refused = false;
	try { dialogOf(Warning.None, "x", 40, 4); } catch (e) { refused = true; }
	assert refused;
}

test "the dialog states what it asks, how big the text is, and previews its first lines" {
	const d = dialogOf(Warning.MultiLine, "ls\ncd ..\nrm -rf x\nexit", 40, 3);
	assert d.top[0] == ({ text: "Warning: potentially unsafe paste", tone: Tone.Title } as Line);
	assert d.top[d.top.length - 1] == ({ text: "4 lines, 22 characters", tone: Tone.Dim } as Line);
	assert d.top.length >= 4;
	assert d.code.length == 4;
	assert d.code[0] == ({ text: "ls", tone: Tone.Code } as Line);
	assert d.code[2] == ({ text: "rm -rf x", tone: Tone.Code } as Line);
	assert d.code[3] == ({ text: "… 1 more line", tone: Tone.Dim } as Line);
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

test "a trailing line break previews and counts a last empty line" {
	const d = dialogOf(Warning.MultiLine, "a\nb\n", 40, 8);
	assert d.top[d.top.length - 1] == ({ text: "3 lines, 4 characters", tone: Tone.Dim } as Line);
	assert d.code.length == 3;
	assert d.code[1] == ({ text: "b", tone: Tone.Code } as Line);
	assert d.code[2] == ({ text: "", tone: Tone.Code } as Line);
}

test "a clipboard read is denied by escape or enter and allowed only by ctrl enter" {
	assert replyToRead("Escape", NO_MODS) == Reply.Cancel;
	assert replyToRead("Enter", NO_MODS) == Reply.Cancel;
	assert replyToRead("NumpadEnter", NO_MODS) == Reply.Cancel;
	assert replyToRead("Enter", CTRL) == Reply.Confirm;
	assert replyToRead("Enter", CTRL | SHIFT) == Reply.Ignore;
	assert replyToRead("KeyV", CLIPBOARD_MODS) == Reply.Ignore;
	assert replyToRead("KeyY", NO_MODS) == Reply.Ignore;
}

test "a close is confirmed by enter alone and cancelled by escape alone" {
	assert replyToClose("Enter", NO_MODS) == Reply.Confirm;
	assert replyToClose("NumpadEnter", NO_MODS) == Reply.Confirm;
	assert replyToClose("Escape", NO_MODS) == Reply.Cancel;
	assert replyToClose("KeyV", CLIPBOARD_MODS) == Reply.Ignore;
	assert replyToClose("Enter", SHIFT) == Reply.Ignore;
	assert replyToClose("KeyW", NO_MODS) == Reply.Ignore;
}

test "the close dialog says a program runs and asks to end it, with nothing to preview" {
	const d = closeDialogOf(40);
	assert d.top.length == 2;
	assert d.top[0] == ({ text: "A program is still running", tone: Tone.Title } as Line);
	assert d.top[1] == ({ text: "Close the window and end it?", tone: Tone.Body } as Line);
	assert d.code.length == 0;
}

test "the read dialog names the access, says how big the clipboard is and previews it" {
	const d = askDialogOf("secret\ntoken", 40, 8);
	assert d.top[0] == ({ text: "Authorize clipboard access", tone: Tone.Title } as Line);
	assert d.top[d.top.length - 1] == ({ text: "2 lines, 12 characters", tone: Tone.Dim } as Line);
	assert d.code.length == 2;
	assert d.code[1] == ({ text: "token", tone: Tone.Code } as Line);
}
