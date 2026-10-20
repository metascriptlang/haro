import { NeonEvent } from "../../../../../../neon/src/render/event";
import { KeyMod } from "../../../../keys/keys";
import { Action, BindAction, Keybind, bindFor, resolve } from "../../../../input/bindings";
import { ROWS_PER_NOTCH } from "../../../../input/wheel";
import {
	alternateScreen,
	jumpToPrompt,
	scrollBottom,
	scrollLines,
	scrollPages,
	scrollTop,
} from "../../../../vt/vt";
import { Term } from "./term";
import { Bridge, ControlError, Controls, holding, typed, vtOf } from "./controls";
import { answerHeld, copySelection, pasteFrom } from "./clipboard";

const SUPER_ONLY: BitSet<KeyMod> = (0 as BitSet<KeyMod>).incl(KeyMod.Super);
const KEYBOARD_ROWS: int32 = ROWS_PER_NOTCH as int32;

function runKeybind(
	this c: Controls,
	t: Term,
	bind: Keybind | null,
	host: Bridge,
): Result<boolean, ControlError> {
	if (bind === null) { return Result.ok(false); }
	if (bind.action == BindAction.CloseWindow) {
		host.close();
		return Result.ok(true);
	}
	if (!t.sendText(bind.text).ok) { return Result.err(ControlError.WriteFailed); }
	const _snapped = try c.typed(t);
	return Result.ok(true);
}

export function closeKey(this c: Controls, t: Term, host: Bridge): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt !== null) {
		const alt = vt.alternateScreen();
		if (!alt.ok) { return Result.err(ControlError.VtFailed); }
		const bind = bindFor(c.keybinds, "KeyW", SUPER_ONLY as uint16, alt.value);
		if (try c.runKeybind(t, bind, host)) { return Result.ok(true); }
	}
	host.close();
	return Result.ok(true);
}

export function keyDown(
	this c: Controls,
	t: Term,
	e: NeonEvent,
	host: Bridge,
): Result<boolean, ControlError> {
	if (c.holding()) { return c.answerHeld(t, e); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	if (!alt.ok) { return Result.err(ControlError.VtFailed); }
	if (try c.runKeybind(t, bindFor(c.keybinds, e.code, e.mods, alt.value), host)) {
		return Result.ok(true);
	}
	const action = resolve(e.code, e.mods, alt.value);
	match (action) {
		Action.None => { return Result.ok(false); },
		Action.Copy => { return c.copySelection(t, host); },
		Action.Paste => { c.pasteFrom(t, host); },
		Action.PageUp | Action.PageDown => {
			const pages: int32 = action == Action.PageUp ? -1 : 1;
			if (!vt.scrollPages(pages).ok) { return Result.err(ControlError.VtFailed); }
		},
		Action.PromptUp | Action.PromptDown => {
			const prompts: int32 = action == Action.PromptUp ? -1 : 1;
			if (!vt.jumpToPrompt(prompts).ok) { return Result.err(ControlError.VtFailed); }
		},
		Action.LineUp => { vt.scrollLines(-KEYBOARD_ROWS); },
		Action.LineDown => { vt.scrollLines(KEYBOARD_ROWS); },
		Action.Top => { vt.scrollTop(); },
		Action.Bottom => { vt.scrollBottom(); },
	}
	return Result.ok(true);
}
