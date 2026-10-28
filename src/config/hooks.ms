import { KeyEvent, KeyAction, KeyMod } from "../keys/keys";
import { CommandDone, Rgb } from "../vt/vt";
import { RowTint } from "../grid/lines";
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
}

interface Running {
	pane: HookPane | null;
	outside: string;
	refused: string;
}

const running: Running = { pane: null, outside: "", refused: "" };

// A call outside a hook is reported after evaluation, not raised at the call: compiler card 2026-10-28-embed-a-host-routine-cannot-raise-an-error-into-the-script.
function onPane(
	name: string,
	outside: RaiserValue,
	act: (pane: HookPane) => RaiserValue,
): RaiserValue {
	const pane = running.pane;
	if (pane !== null) { return act(pane); }
	if (running.outside == "") { running.outside = name; }
	return outside;
}

const NO_DECORATION = -1;

struct Asked {
	from: int32;
	to: int32;
	tint: RowTint;
}

function anchorField(d: RaiserHostValue, name: string): int32 | null {
	const v = d.field(name).root;
	return v.kind == RaiserValueKind.Int ? v.intVal as int32 : null;
}

function colourField(d: RaiserHostValue, name: string): Result<Rgb | null, string> {
	const v = d.field(name);
	if (v.root.kind == RaiserValueKind.Nil) { return Result.ok(null); }
	const key = `decorate's ${name}`;
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
	const bg = try colourField(d, "background");
	const fg = try colourField(d, "foreground");
	return Result.ok({ from: from, to: to, tint: { fg: fg, bg: bg } });
}

function decorated(pane: HookPane, d: RaiserHostValue): RaiserValue {
	const asked = askedOf(d);
	if (!asked.ok) {
		if (running.refused == "") { running.refused = asked.error; }
		return boxInt(NO_DECORATION);
	}
	return boxInt(pane.decorate(asked.value.from, asked.value.to, asked.value.tint));
}

export function implementRoutines(): void {
	running.outside = "";
	implementRoutine("haro.send", (args: RaiserValue[]): RaiserValue => {
		const text = unboxString(args[0]);
		return onPane("send", boxVoid(), (pane: HookPane): RaiserValue => {
			pane.send(text);
			return boxVoid();
		});
	});
	implementRoutine("haro.notify", (args: RaiserValue[]): RaiserValue => {
		const title = unboxString(args[0]);
		const body = unboxString(args[1]);
		return onPane("notify", boxVoid(), (pane: HookPane): RaiserValue => {
			pane.notify(title, body);
			return boxVoid();
		});
	});
	implementRoutine("haro.decorate", (args: RaiserValue[]): RaiserValue => {
		const d = unboxValue(args[0]);
		const refused = boxInt(NO_DECORATION);
		return onPane("decorate", refused, (pane: HookPane): RaiserValue => decorated(pane, d));
	});
	implementRoutine("haro.undecorate", (args: RaiserValue[]): RaiserValue => {
		const id = args[0].kind == RaiserValueKind.Int ? args[0].intVal as int32 : NO_DECORATION;
		return onPane("undecorate", boxVoid(), (pane: HookPane): RaiserValue => {
			pane.undecorate(id);
			return boxVoid();
		});
	});
}

export function calledOutsideHooks(): Result<void, string> {
	const name = running.outside;
	running.outside = "";
	if (name == "") { return Result.ok(null); }
	return Result.err(
		`config.ms called ${name} outside a hook, and ${name} acts only on the pane a hook runs for`,
	);
}

function runFor(
	this h: Hooks,
	pane: HookPane,
	routine: Routine,
	args: RaiserHostValue[],
): Result<RaiserHostValue, string> {
	const outer = running.pane;
	running.pane = pane;
	running.refused = "";
	const got = callRoutine(h.interp, routine, args);
	running.pane = outer;
	const refused = running.refused;
	running.refused = "";
	if (got.ok && refused != "") { return Result.err(refused); }
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
