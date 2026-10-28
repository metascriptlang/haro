import { KeyEvent, KeyAction, KeyMod } from "../keys/keys";
import { CommandDone } from "../vt/vt";
import {
	Interpreter,
	RaiserHostValue,
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
	unboxBool,
} from "../../../../.metascript/src/embed/index";

export interface Hooks {
	interp: Interpreter;
	onKey: Routine;
	onPrompt: Routine;
	onCommandDone: Routine;
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

export function answerKey(this h: Hooks, k: KeyEvent): Result<KeyAnswer, string> {
	const got = callRoutine(h.interp, h.onKey, [pressOf(k)]);
	if (!got.ok) { return Result.err(`onKey in config.ms failed: ${got.error}`); }
	const send = got.value.field("send");
	return Result.ok({
		handled: unboxBool(got.value.field("handled").root),
		send: send.root.kind == RaiserValueKind.String ? send.text() : "",
	});
}

export function prompted(this h: Hooks): Result<void, string> {
	const got = callRoutine(h.interp, h.onPrompt, []);
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

export function commandDone(this h: Hooks, d: CommandDone): Result<void, string> {
	const got = callRoutine(h.interp, h.onCommandDone, [doneOf(d)]);
	return got.ok ? Result.ok(null) : Result.err(`onCommandDone in config.ms failed: ${got.error}`);
}
