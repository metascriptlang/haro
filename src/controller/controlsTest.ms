import { MouseButton } from "./mouseButton";
import { selected } from "../input/pointer";
import { Term } from "./term";
import { Controls, holding, refit, typed } from "./controls";
import { Pasted, cancel, clipboardAsked, confirm, normalized, paste } from "./clipboard";
import { keyDown } from "./keyboard";
import { pointerDown, roll } from "./mouse";
import { Warning } from "../input/paste";
import { CLIPBOARD_MODS, CTRL, SHIFT } from "../input/bindings";
import {
	Sink,
	at,
	atBottomOf,
	boardOf,
	settle,
	settled,
	drag,
	handled,
	hitAt,
	key,
	lines,
	onTerm,
} from "./terminalRig";

test "line endings of a paste become newlines and an unbracketed paste loses trailing whitespace" {
	assert normalized("a\r\nb\rc\n", false) == "a\nb\nc";
	assert normalized("echo hi\r\n  ", false) == "echo hi";
	assert normalized("echo hi\r\n  ", true) == "echo hi\n  ";
	assert normalized("  keep leading", false) == "  keep leading";
	assert normalized("\r\n", false) == "";
}

test "the buttons confirm and cancel through the same paths as the keys" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("a\nb");
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		const _dropped = c.cancel(t);
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.confirm(t));
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert handled(c.confirm(t));
		assert sink.sent == "a\rb";
	}).ok;
}

test "bracketed paste keeps line breaks, and an end marker or a large text still asks" {
	assert onTerm("\x1b[?2004h", (a: Term, framed: Sink): void => {
		const c = Controls.open();
		const offer = boardOf("one\r\ntwo\r\n");
		assert handled(settled(offer, c, a, c.keyDown(a, key("KeyV", CLIPBOARD_MODS))));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~";
		assert !c.holding();
		const marker = c.paste(a, "evil\x1b[201~rm");
		assert marker.ok;
		if (marker.ok) { assert marker.value == Pasted.Held; }
		const held = c.held;
		assert held !== null;
		if (held !== null) { assert held.warning == Warning.EndMarker; }
		assert handled(settled(boardOf(""), c, a, c.keyDown(a, key("Enter", 0))));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~\x1b[200~evil [201~rm\x1b[201~";
		let big = "";
		for (let i = 0; i < 6000; i++) { big += "z"; }
		const large = c.paste(a, big);
		assert large.ok;
		if (large.ok) { assert large.value == Pasted.Held; }
	}).ok;
}

test "an empty clipboard pastes nothing, or an empty frame when the program asked for brackets" {
	assert onTerm("ready", (a: Term, plain: Sink): void => {
		const c = Controls.open();
		const pasted = c.paste(a, "  \r\n");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Empty; }
		assert plain.sent == "";
	}).ok;
	assert onTerm("\x1b[?2004h", (b: Term, framed: Sink): void => {
		const c = Controls.open();
		const pasted = c.paste(b, "");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Sent; }
		assert framed.sent == "\x1b[200~\x1b[201~";
	}).ok;
}

test "typing or pasting snaps the viewport to the bottom and drops the selection once" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("x");
		assert !handled(c.typed(t));
		assert handled(settled(clip, c, t, c.keyDown(t, key("PageUp", CTRL | SHIFT))));
		assert drag(c, t, clip, at(0, 0), at(3, 0));
		assert c.pointer.selected();
		assert handled(c.typed(t));
		assert atBottomOf(t);
		assert !c.pointer.selected();
		assert !handled(c.typed(t));
		assert handled(settled(clip, c, t, c.keyDown(t, key("Home", CTRL | SHIFT))));
		assert handled(settled(clip, c, t, c.keyDown(t, key("KeyV", CLIPBOARD_MODS))));
		assert atBottomOf(t);
		assert sink.sent == "x";
	}).ok;
}

test "a clipboard read waits for an answer: escape or enter deny it, ctrl enter allows it" {
	assert onTerm("\x1b]52;c;?\x1b\\", (a: Term, deny: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("secret");
		c.clipboardAsked();
		assert clip.settle(c, a).ok;
		assert c.holding();
		assert c.reading == "secret";
		assert deny.sent == "";
		assert handled(settled(clip, c, a, c.keyDown(a, key("KeyY", 0))));
		assert c.holding();
		assert handled(settled(clip, c, a, c.keyDown(a, key("Enter", 0))));
		assert !c.holding();
		assert deny.sent == "\x1b]52;c;\x1b\\";
	}).ok;
	assert onTerm("\x1b]52;c;?\x1b\\", (b: Term, allow: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("secret");
		c.clipboardAsked();
		assert clip.settle(c, b).ok;
		assert handled(settled(clip, c, b, c.keyDown(b, key("Enter", CTRL))));
		assert allow.sent == "\x1b]52;c;c2VjcmV0\x1b\\";
	}).ok;
}

test "an empty clipboard is answered at once and a read does not ask while the pointer is inert" {
	assert onTerm("\x1b]52;c;?\x1b\\", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		c.clipboardAsked();
		assert boardOf("").settle(c, t).ok;
		assert !c.holding();
		assert sink.sent == "\x1b]52;c;\x1b\\";
		c.reading = "x";
		const clip = boardOf("");
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert !handled(settled(clip, c, t, c.pointerDown(t, MouseButton.Left, hitAt(0, 0), 0)));
	}).ok;
}

test "a width change drops the selection, a height change keeps it" {
	assert onTerm("0123456789abcde", (t: Term, sink: Sink): void => {
		const c = Controls.open();
		const clip = boardOf("x");
		assert drag(c, t, clip, at(0, 1), at(2, 1));
		assert c.refit(t, 10, 4).ok;
		assert c.pointer.selected();
		assert c.refit(t, 20, 4).ok;
		assert !c.pointer.selected();
	}, 10, 3).ok;
}
