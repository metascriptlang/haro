import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Reply, replyTo, replyToRead, warningFor, Warning } from "../../../../input/paste";
import { clear, copyText } from "../../../../input/pointer";
import { answerClipboard, modes } from "../../../../vt/vt";
import { Term, TermError } from "./term";
import { Bridge, Controls, typed, vtOf } from "./controls";

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
	allowUnsafe: boolean,
): Result<boolean, TermError> {
	const _sent = try t.sendPaste(text, allowUnsafe);
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
	const _sent = try c.send(t, clean, false);
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

export function clipboardAsked(this c: Controls, t: Term, host: Bridge): void {
	host.read((text: string): void => {
		if (text == "") {
			const answered = c.answerRead(t, "", true);
			if (!answered.ok) {
				console.log(`haro: clipboard answer failed: ${answered.error.toString()}`);
			}
			return;
		}
		c.reading = text;
	});
}

export function confirm(this c: Controls, t: Term): Result<boolean, TermError> {
	const held = c.held;
	if (held !== null) {
		c.held = null;
		const _sent = try c.send(t, held.text, true);
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

export function answerHeld(this c: Controls, t: Term, e: NeonEvent): Result<boolean, TermError> {
	const reply = c.held !== null ? replyTo(e.code, e.mods) : replyToRead(e.code, e.mods);
	match (reply) {
		Reply.Confirm => { const _sent = try c.confirm(t); },
		Reply.Cancel => { const _dropped = try c.cancel(t); },
		Reply.Ignore => {},
	}
	return Result.ok(true);
}

export function pasteFrom(this c: Controls, t: Term, host: Bridge): void {
	host.read((text: string): void => {
		const sent = c.paste(t, text);
		if (!sent.ok) { console.log(`haro: paste failed: ${sent.error.toString()}`); }
	});
}

export function copySelection(
	this c: Controls,
	t: Term,
	host: Bridge,
): Result<boolean, TermError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const text = c.pointer.copyText(vt);
	if (!text.ok) { return Result.err(TermError.VtFailed); }
	const got = text.value;
	if (got === null) { return Result.ok(false); }
	host.write(got);
	c.pointer.clear(vt);
	return Result.ok(true);
}
