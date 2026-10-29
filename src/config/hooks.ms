import { KeyEvent, KeyAction, KeyMod } from "../keys/keys";
import { CommandDone, Rgb } from "../vt/vt";
import { RowNote, RowTint } from "../grid/lines";
import { rgbOf } from "./config";
import {
	Interpreter,
	RaiserHostValue,
	RaiserValue,
	RaiserValueKind,
	Routine,
	boxBool,
	boxFloat,
	boxInt,
	boxVoid,
	callRoutine,
	hostObject,
	hostString,
	hostValue,
	implementRoutine,
	unboxBool,
	unboxString,
	unboxValue,
} from "../../../../.metascript/src/embed/index";

export interface Hooks {
	interp: Interpreter;
	onKey: Routine;
	onPrompt: Routine;
	onCommandDone: Routine;
}

export interface HookPane {
	send: (text: string) => void;
	notify: (title: string, body: string) => void;
	decorate: (from: int32, to: int32, tint: RowTint) => int32;
	undecorate: (id: int32) => void;
	annotate: (at: int32, note: RowNote) => int32;
	unannotate: (id: int32) => void;
}

interface Running {
	pane: HookPane | null;
}

const running: Running = { pane: null };

function onPane(name: string, act: (pane: HookPane) => RaiserValue): RaiserValue {
	const pane = running.pane;
	if (pane === null) {
		throw new Error(
			`config.ms called ${name} outside a hook, ` +
				`and ${name} acts only on the pane a hook runs for`,
		);
	}
	return act(pane);
}

struct Asked {
	from: int32;
	to: int32;
	tint: RowTint;
}

function anchorField(d: RaiserHostValue, name: string): int32 | null {
	const v = d.field(name).root;
	return v.kind == RaiserValueKind.Int ? v.intVal as int32 : null;
}

function colourField(
	d: RaiserHostValue,
	routine: string,
	name: string,
): Result<Rgb | null, string> {
	const v = d.field(name);
	if (v.root.kind == RaiserValueKind.Nil) { return Result.ok(null); }
	const key = `${routine}'s ${name}`;
	if (v.root.kind != RaiserValueKind.String) {
		return Result.err(`${key} must be a #rrggbb string`);
	}
	const colour: Rgb | null = try rgbOf(v.text(), key);
	return Result.ok(colour);
}

function askedOf(d: RaiserHostValue): Result<Asked, string> {
	const from = anchorField(d, "from");
	const to = anchorField(d, "to");
	if (from === null || to === null) {
		return Result.err(
			"decorate needs from and to anchors, taken from onPrompt or onCommandDone",
		);
	}
	const bg = try colourField(d, "decorate", "background");
	const fg = try colourField(d, "decorate", "foreground");
	return Result.ok({ from: from, to: to, tint: { fg: fg, bg: bg } });
}

function isControl(unit: int32): boolean {
	return unit < 0x20 || (unit >= 0x7F && unit < 0xA0);
}

function noteText(d: RaiserHostValue): Result<string, string> {
	const v = d.field("text");
	if (v.root.kind != RaiserValueKind.String) {
		return Result.err("annotate needs a text string");
	}
	const text = v.text();
	for (let i = 0; i < text.length; i++) {
		if (isControl(text.charCodeAt(i) as int32)) {
			return Result.err(`annotate's text ${JSON.stringify(text)} holds a control character`);
		}
	}
	return Result.ok(text);
}

struct Noted {
	at: int32;
	note: RowNote;
}

function notedOf(d: RaiserHostValue): Result<Noted, string> {
	const at = anchorField(d, "at");
	if (at === null) {
		return Result.err("annotate needs an at anchor, taken from onPrompt or onCommandDone");
	}
	const text = try noteText(d);
	const fg = try colourField(d, "annotate", "foreground");
	const bg = try colourField(d, "annotate", "background");
	return Result.ok({ at: at, note: { text: text, fg: fg, bg: bg } });
}

function decorated(pane: HookPane, d: RaiserHostValue): RaiserValue {
	const asked = askedOf(d);
	if (!asked.ok) { throw new Error(asked.error); }
	return boxInt(pane.decorate(asked.value.from, asked.value.to, asked.value.tint));
}

function annotated(pane: HookPane, d: RaiserHostValue): RaiserValue {
	const noted = notedOf(d);
	if (!noted.ok) { throw new Error(noted.error); }
	return boxInt(pane.annotate(noted.value.at, noted.value.note));
}

function idOf(arg: RaiserValue): int32 | null {
	return arg.kind == RaiserValueKind.Int ? arg.intVal as int32 : null;
}

export function implementRoutines(): void {
	implementRoutine("haro.send", (args: RaiserValue[]): RaiserValue => {
		const text = unboxString(args[0]);
		return onPane("send", (pane: HookPane): RaiserValue => {
			pane.send(text);
			return boxVoid();
		});
	});
	implementRoutine("haro.notify", (args: RaiserValue[]): RaiserValue => {
		const title = unboxString(args[0]);
		const body = unboxString(args[1]);
		return onPane("notify", (pane: HookPane): RaiserValue => {
			pane.notify(title, body);
			return boxVoid();
		});
	});
	implementRoutine("haro.decorate", (args: RaiserValue[]): RaiserValue => {
		const d = unboxValue(args[0]);
		return onPane("decorate", (pane: HookPane): RaiserValue => decorated(pane, d));
	});
	implementRoutine("haro.undecorate", (args: RaiserValue[]): RaiserValue => {
		const id = idOf(args[0]);
		return onPane("undecorate", (pane: HookPane): RaiserValue => {
			if (id !== null) { pane.undecorate(id); }
			return boxVoid();
		});
	});
	implementRoutine("haro.annotate", (args: RaiserValue[]): RaiserValue => {
		const d = unboxValue(args[0]);
		return onPane("annotate", (pane: HookPane): RaiserValue => annotated(pane, d));
	});
	implementRoutine("haro.unannotate", (args: RaiserValue[]): RaiserValue => {
		const id = idOf(args[0]);
		return onPane("unannotate", (pane: HookPane): RaiserValue => {
			if (id !== null) { pane.unannotate(id); }
			return boxVoid();
		});
	});
}

function runFor(
	this h: Hooks,
	pane: HookPane,
	routine: Routine,
	args: RaiserHostValue[],
): Result<RaiserHostValue, string> {
	const outer = running.pane;
	running.pane = pane;
	const got = callRoutine(h.interp, routine, args);
	running.pane = outer;
	return got;
}

export struct KeyAnswer {
	handled: boolean;
	send: string;
}

export const UNHANDLED: KeyAnswer = { handled: false, send: "" };

const PRESS_FIELDS = ["code", "text", "shift", "ctrl", "alt", "super", "repeat"];

function flag(on: boolean): RaiserHostValue {
	return hostValue(boxBool(on));
}

function pressOf(k: KeyEvent): RaiserHostValue {
	return hostObject(PRESS_FIELDS, [
		hostString(k.key),
		hostString(k.text),
		flag(k.mods.has(KeyMod.Shift)),
		flag(k.mods.has(KeyMod.Ctrl)),
		flag(k.mods.has(KeyMod.Alt)),
		flag(k.mods.has(KeyMod.Super)),
		flag(k.action == KeyAction.Repeat),
	]);
}

export function answerKey(this h: Hooks, pane: HookPane, k: KeyEvent): Result<KeyAnswer, string> {
	const got = h.runFor(pane, h.onKey, [pressOf(k)]);
	if (!got.ok) { return Result.err(`onKey in config.ms failed: ${got.error}`); }
	const send = got.value.field("send");
	return Result.ok({
		handled: unboxBool(got.value.field("handled").root),
		send: send.root.kind == RaiserValueKind.String ? send.text() : "",
	});
}

function anchor(id: int32 | null): RaiserHostValue {
	return hostValue(id === null ? boxVoid() : boxInt(id));
}

export function prompted(this h: Hooks, pane: HookPane, at: int32): Result<void, string> {
	const got = h.runFor(pane, h.onPrompt, [hostObject(["at"], [anchor(at)])]);
	return got.ok ? Result.ok(null) : Result.err(`onPrompt in config.ms failed: ${got.error}`);
}

const DONE_FIELDS = ["exitCode", "command", "durationMs", "prompt", "output", "end"];

function doneOf(d: CommandDone): RaiserHostValue {
	const exitCode = d.exitCode;
	const durationMs = d.durationMs;
	return hostObject(DONE_FIELDS, [
		hostValue(exitCode === null ? boxVoid() : boxInt(exitCode)),
		hostString(d.command),
		hostValue(durationMs === null ? boxVoid() : boxFloat(durationMs)),
		anchor(d.prompt),
		anchor(d.output),
		anchor(d.end),
	]);
}

export function commandDone(this h: Hooks, pane: HookPane, d: CommandDone): Result<void, string> {
	const got = h.runFor(pane, h.onCommandDone, [doneOf(d)]);
	return got.ok ? Result.ok(null) : Result.err(`onCommandDone in config.ms failed: ${got.error}`);
}
