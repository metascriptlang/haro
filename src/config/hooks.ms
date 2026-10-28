import { KeyEvent, KeyAction, KeyMod } from "../keys/keys";
import { CommandDone } from "../vt/vt";
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
}

interface Running {
	pane: HookPane | null;
	outside: string;
}

const running: Running = { pane: null, outside: "" };

// A call outside a hook is reported after evaluation, not raised at the call: compiler card 2026-10-28-embed-a-host-routine-cannot-raise-an-error-into-the-script.
function onPane(name: string, act: (pane: HookPane) => void): RaiserValue {
	const pane = running.pane;
	if (pane !== null) {
		act(pane);
	} else if (running.outside == "") {
		running.outside = name;
	}
	return boxVoid();
}

export function implementRoutines(): void {
	running.outside = "";
	implementRoutine("haro.send", (args: RaiserValue[]): RaiserValue => {
		const text = unboxString(args[0]);
		return onPane("send", (pane: HookPane): void => { pane.send(text); });
	});
	implementRoutine("haro.notify", (args: RaiserValue[]): RaiserValue => {
		const title = unboxString(args[0]);
		const body = unboxString(args[1]);
		return onPane("notify", (pane: HookPane): void => { pane.notify(title, body); });
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

export function prompted(this h: Hooks, pane: HookPane): Result<void, string> {
	const got = h.runFor(pane, h.onPrompt, []);
	return got.ok ? Result.ok(null) : Result.err(`onPrompt in config.ms failed: ${got.error}`);
}

const DONE_FIELDS = ["exitCode", "command", "durationMs"];

function doneOf(d: CommandDone): RaiserHostValue {
	const exitCode = d.exitCode;
	const durationMs = d.durationMs;
	return hostObject(DONE_FIELDS, [
		hostValue(exitCode === null ? boxVoid() : boxInt(exitCode)),
		hostString(d.command),
		hostValue(durationMs === null ? boxVoid() : boxFloat(durationMs)),
	]);
}

export function commandDone(this h: Hooks, pane: HookPane, d: CommandDone): Result<void, string> {
	const got = h.runFor(pane, h.onCommandDone, [doneOf(d)]);
	return got.ok ? Result.ok(null) : Result.err(`onCommandDone in config.ms failed: ${got.error}`);
}
