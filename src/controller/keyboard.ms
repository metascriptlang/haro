import { KeyEvent, KeyMod } from "../keys/keys";
import { Action, Keybind, bindFor, resolve } from "../input/bindings";
import { clear } from "../input/pointer";
import { ROWS_PER_NOTCH } from "../input/wheel";
import { Reply, replyToClose } from "../input/paste";
import {
	PromptJump,
	alternateScreen,
	jumpToPrompt,
	scrollBottom,
	scrollLines,
	scrollPages,
	scrollTop,
} from "../vt/vt";
import { Term, TermError, busy, clearScreen, cooked, vtFailed } from "./term";
import { Controls, holding, selectAll, typed, vtOf } from "./controls";
import { answerHeld, copySelection, pasteFrom } from "./clipboard";

const SUPER_ONLY: BitSet<KeyMod> = (0 as BitSet<KeyMod>).incl(KeyMod.Super);
const KEYBOARD_ROWS: int32 = ROWS_PER_NOTCH as int32;

function runKeybind(
	this c: Controls,
	t: Term,
	bind: Keybind | null,
): Result<boolean, TermError> {
	if (bind === null) { return Result.ok(false); }
	return c.act(t, bind.action, bind.text);
}

export function act(
	this c: Controls,
	t: Term,
	action: Action,
	text: string = "",
): Result<boolean, TermError> {
	if (action == Action.CloseWindow) {
		c.closeWindow(t);
		return Result.ok(true);
	}
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	match (action) {
		Action.SendText => {
			try t.sendText(text);
			try c.typed(t);
		},
		Action.CloseWindow => { c.closeWindow(t); },
		Action.Copy => { return c.copySelection(t); },
		Action.Paste => { c.pasteFrom(); },
		Action.SelectAll => { try c.selectAll(vt); },
		Action.IncreaseFontSize |
		Action.DecreaseFontSize |
		Action.ResetFontSize |
		Action.OpenConfig |
		Action.ReloadConfig => {
			c.asks.actions.push(action);
		},
		Action.ClearScrollback => {
			if (!(try t.clearScreen())) { return Result.ok(false); }
			try c.pointer.clear(vt);
		},
		Action.PageUp => { try vt.scrollPages(-1); },
		Action.PageDown => { try vt.scrollPages(1); },
		Action.PromptUp => { try vt.jumpToPrompt(PromptJump.Previous); },
		Action.PromptDown => { try vt.jumpToPrompt(PromptJump.Next); },
		Action.LineUp => { vt.scrollLines(-KEYBOARD_ROWS); },
		Action.LineDown => { vt.scrollLines(KEYBOARD_ROWS); },
		Action.Top => { vt.scrollTop(); },
		Action.Bottom => { vt.scrollBottom(); },
	}
	return Result.ok(true);
}

export function closeKey(this c: Controls, t: Term): Result<boolean, TermError> {
	const vt = t.vtOf();
	if (vt !== null) {
		const alt = try vt.alternateScreen();
		const bind = bindFor(c.keybinds, "KeyW", SUPER_ONLY, alt);
		if (try c.runKeybind(t, bind)) { return Result.ok(true); }
	}
	c.closeWindow(t);
	return Result.ok(true);
}

export function closeWindow(this c: Controls, t: Term): void {
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
	e: KeyEvent,
): Result<boolean, TermError> {
	const handled = try c.controlKey(t, e);
	c.consumedKey = handled ? e.key : "";
	return Result.ok(handled);
}

export function keyUp(this c: Controls, e: KeyEvent): boolean {
	return c.holding() || e.key == c.consumedKey;
}

function controlKey(
	this c: Controls,
	t: Term,
	e: KeyEvent,
): Result<boolean, TermError> {
	if (c.closing) {
		c.answerClose(replyToClose(e.key, e.mods));
		return Result.ok(true);
	}
	if (c.holding()) { return c.answerHeld(t, e); }
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	const alt = try vt.alternateScreen();
	const mods = e.cooked().mods;
	if (try c.runKeybind(t, bindFor(c.keybinds, e.key, mods, alt))) {
		return Result.ok(true);
	}
	const action = resolve(e.key, mods, alt);
	if (action === null) { return Result.ok(false); }
	return c.act(t, action);
}
