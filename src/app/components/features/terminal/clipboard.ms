import { KeyEvent, modsMask } from "../../../../keys/keys";
import { Reply, replyTo, replyToRead, warningFor, Warning } from "../../../../input/paste";
import { clear, copyText } from "../../../../input/pointer";
import { answerClipboard, modes } from "../../../../vt/vt";
import { PasteCheck, Term, TermError } from "./term";
import { ClipRead, Controls, askRead, typed, vtOf } from "./controls";

export enum Pasted {
	Sent,
	Empty,
	Held,
}

export function normalized(text: string, bracketed: boolean): string {
	const lf = text.split("\r\n").join("\n").split("\r").join("\n");
	return bracketed ? lf : lf.trimEnd();
}

function send(
	this c: Controls,
	t: Term,
	text: string,
	check: PasteCheck,
): Result<boolean, TermError> {
	const _sent = try t.sendPaste(text, check);
	return c.typed(t);
}

export function paste(this c: Controls, t: Term, text: string): Result<Pasted, TermError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(Pasted.Empty); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(TermError.VtFailed); }
	const bracketed = modes.value.bracketedPaste;
	const clean = normalized(text, bracketed);
	if (clean == "" && !bracketed) { return Result.ok(Pasted.Empty); }
	const warning = warningFor(clean, bracketed);
	if (warning != Warning.None) {
		c.held = { text: clean, warning: warning };
		return Result.ok(Pasted.Held);
	}
	const _sent = try c.send(t, clean, PasteCheck.Checked);
	return Result.ok(Pasted.Sent);
}

function answerRead(
	this c: Controls,
	t: Term,
	text: string,
	allow: boolean,
): Result<boolean, TermError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	if (!vt.answerClipboard(text, allow).ok) { return Result.err(TermError.VtFailed); }
	const _replied = try t.sendReplies();
	return Result.ok(true);
}

export function clipboardAsked(this c: Controls): void {
	c.askRead(ClipRead.Answer);
}

export function clipboardText(this c: Controls, t: Term, text: string): Result<boolean, TermError> {
	if (c.waiting.length == 0) { return Result.err(TermError.ClipboardUnasked); }
	match (c.waiting.shift()) {
		ClipRead.Paste => {
			const _pasted = try c.paste(t, text);
			return Result.ok(true);
		},
		ClipRead.Answer => {
			if (text == "") { return c.answerRead(t, "", true); }
			c.reading = text;
			return Result.ok(true);
		},
	}
}

export function confirm(this c: Controls, t: Term): Result<boolean, TermError> {
	const held = c.held;
	if (held !== null) {
		c.held = null;
		const _sent = try c.send(t, held.text, PasteCheck.Confirmed);
		return Result.ok(true);
	}
	const reading = c.reading;
	if (reading === null) { return Result.ok(false); }
	c.reading = null;
	return c.answerRead(t, reading, true);
}

export function cancel(this c: Controls, t: Term): Result<boolean, TermError> {
	if (c.held !== null) {
		c.held = null;
		return Result.ok(true);
	}
	if (c.reading === null) { return Result.ok(false); }
	c.reading = null;
	return c.answerRead(t, "", false);
}

export function answerHeld(this c: Controls, t: Term, e: KeyEvent): Result<boolean, TermError> {
	const mods = modsMask(e.mods);
	const reply = c.held !== null ? replyTo(e.key, mods) : replyToRead(e.key, mods);
	match (reply) {
		Reply.Confirm => { const _sent = try c.confirm(t); },
		Reply.Cancel => { const _dropped = try c.cancel(t); },
		Reply.Ignore => {},
	}
	return Result.ok(true);
}

export function pasteFrom(this c: Controls): void {
	c.askRead(ClipRead.Paste);
}

export function copySelection(this c: Controls, t: Term): Result<boolean, TermError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const text = c.pointer.copyText(vt);
	if (!text.ok) { return Result.err(TermError.VtFailed); }
	const got = text.value;
	if (got === null) { return Result.ok(false); }
	c.asks.copy = got;
	c.pointer.clear(vt);
	return Result.ok(true);
}
