import { NeonEvent } from "../../../../../../neon/src/render/event";
import { KeyMod, modsMask } from "../../../../keys/keys";
import { Action, BindAction, Keybind, bindFor, resolve } from "../../../../input/bindings";
import { ROWS_PER_NOTCH } from "../../../../input/wheel";
import { Reply, replyToClose } from "../../../../input/paste";
import {
	PromptJump,
	alternateScreen,
	jumpToPrompt,
	scrollBottom,
	scrollLines,
	scrollPages,
	scrollTop,
} from "../../../../vt/vt";
import { Term, TermError, busy, keyEventOf } from "./term";
import { Controls, holding, typed, vtOf } from "./controls";
import { answerHeld, copySelection, pasteFrom } from "./clipboard";

const SUPER_ONLY: BitSet<KeyMod> = (0 as BitSet<KeyMod>).incl(KeyMod.Super);
const KEYBOARD_ROWS: int32 = ROWS_PER_NOTCH as int32;

function runKeybind(
	this c: Controls,
	t: Term,
	bind: Keybind | null,
): Result<boolean, TermError> {
	if (bind === null) { return Result.ok(false); }
	if (bind.action == BindAction.CloseWindow) {
		c.closeWindow(t);
		return Result.ok(true);
	}
	const _sent = try t.sendText(bind.text);
	const _snapped = try c.typed(t);
	return Result.ok(true);
}

export function closeKey(this c: Controls, t: Term): Result<boolean, TermError> {
	const vt = vtOf(t);
	if (vt !== null) {
		const alt = vt.alternateScreen();
		if (!alt.ok) { return Result.err(TermError.VtFailed); }
		const bind = bindFor(c.keybinds, "KeyW", SUPER_ONLY as uint16, alt.value);
		if (try c.runKeybind(t, bind)) { return Result.ok(true); }
	}
	c.closeWindow(t);
	return Result.ok(true);
}

function closeWindow(this c: Controls, t: Term): void {
	if (t.busy()) {
		c.closing = true;
		return;
	}
	c.asks.close = true;
}

export function answerClose(this c: Controls, reply: Reply): void {
	match (reply) {
		Reply.Confirm => {
			c.closing = false;
			c.asks.close = true;
		},
		Reply.Cancel => { c.closing = false; },
		Reply.Ignore => {},
	}
}

export function keyDown(
	this c: Controls,
	t: Term,
	e: NeonEvent,
): Result<boolean, TermError> {
	const handled = try c.controlKey(t, e);
	c.consumedKey = handled ? e.code : "";
	return Result.ok(handled);
}

export function keyUp(this c: Controls, e: NeonEvent): boolean {
	return c.holding() || e.code == c.consumedKey;
}

function controlKey(
	this c: Controls,
	t: Term,
	e: NeonEvent,
): Result<boolean, TermError> {
	if (c.closing) {
		c.answerClose(replyToClose(e.code, e.mods));
		return Result.ok(true);
	}
	if (c.holding()) { return c.answerHeld(t, e); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	if (!alt.ok) { return Result.err(TermError.VtFailed); }
	const mods = modsMask(keyEventOf(e).mods) as number;
	if (try c.runKeybind(t, bindFor(c.keybinds, e.code, mods, alt.value))) {
		return Result.ok(true);
	}
	const action = resolve(e.code, mods, alt.value);
	match (action) {
		Action.None => { return Result.ok(false); },
		Action.Copy => { return c.copySelection(t); },
		Action.Paste => { c.pasteFrom(); },
		Action.PageUp | Action.PageDown => {
			const pages: int32 = action == Action.PageUp ? -1 : 1;
			if (!vt.scrollPages(pages).ok) { return Result.err(TermError.VtFailed); }
		},
		Action.PromptUp | Action.PromptDown => {
			const toward = action == Action.PromptUp ? PromptJump.Previous : PromptJump.Next;
			if (!vt.jumpToPrompt(toward).ok) { return Result.err(TermError.VtFailed); }
		},
		Action.LineUp => { vt.scrollLines(-KEYBOARD_ROWS); },
		Action.LineDown => { vt.scrollLines(KEYBOARD_ROWS); },
		Action.Top => { vt.scrollTop(); },
		Action.Bottom => { vt.scrollBottom(); },
	}
	return Result.ok(true);
}
