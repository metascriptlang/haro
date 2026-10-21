import { selected } from "../../../../input/pointer";
import { shutdown } from "./term";
import { Controls, holding, refit, typed } from "./controls";
import { Pasted, cancel, clipboardAsked, confirm, normalized, paste } from "./clipboard";
import { keyDown } from "./keyboard";
import { pointerDown, roll } from "./mouse";
import { Warning } from "../../../../input/paste";
import { CLIPBOARD_MODS, CTRL, SHIFT } from "../../../../input/bindings";
import {
	Sink,
	at,
	atBottomOf,
	boardOf,
	clipOf,
	drag,
	handled,
	hitAt,
	key,
	lines,
	termOf,
} from "./terminalRig";

test "line endings of a paste become newlines and an unbracketed paste loses trailing whitespace" {
	assert normalized("a\r\nb\rc\n", false) == "a\nb\nc";
	assert normalized("echo hi\r\n  ", false) == "echo hi";
	assert normalized("echo hi\r\n  ", true) == "echo hi\n  ";
	assert normalized("  keep leading", false) == "  keep leading";
	assert normalized("\r\n", false) == "";
}

test "the buttons confirm and cancel through the same paths as the keys" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("a\nb"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		const _dropped = c.cancel(t);
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.confirm(t));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.confirm(t));
		assert sink.sent == "a\rb";
		t.shutdown();
	}
}

test "bracketed paste keeps line breaks, and an end marker or a large text still asks" {
	const framed: Sink = { sent: "" };
	const a = termOf("\x1b[?2004h", 20, 5, framed);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const offer = clipOf(boardOf("one\r\ntwo\r\n"));
		assert handled(c.keyDown(a, key("KeyV", CLIPBOARD_MODS), offer));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~";
		assert !c.holding();
		const marker = c.paste(a, "evil\x1b[201~rm");
		assert marker.ok;
		if (marker.ok) { assert marker.value == Pasted.Held; }
		const held = c.held;
		assert held !== null;
		if (held !== null) { assert held.warning == Warning.EndMarker; }
		assert handled(c.keyDown(a, key("Enter", 0), clipOf(boardOf(""))));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~\x1b[200~evil [201~rm\x1b[201~";
		let big = "";
		for (let i = 0; i < 6000; i++) { big += "z"; }
		const large = c.paste(a, big);
		assert large.ok;
		if (large.ok) { assert large.value == Pasted.Held; }
		a.shutdown();
	}
}

test "an empty clipboard pastes nothing, or an empty frame when the program asked for brackets" {
	const plain: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, plain);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const pasted = c.paste(a, "  \r\n");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Empty; }
		assert plain.sent == "";
		a.shutdown();
	}
	const framed: Sink = { sent: "" };
	const b = termOf("\x1b[?2004h", 20, 5, framed);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const pasted = c.paste(b, "");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Sent; }
		assert framed.sent == "\x1b[200~\x1b[201~";
		b.shutdown();
	}
}

test "typing or pasting snaps the viewport to the bottom and drops the selection once" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		assert !handled(c.typed(t));
		assert handled(c.keyDown(t, key("PageUp", CTRL | SHIFT), clip));
		assert drag(c, t, clip, at(0, 0), at(3, 0));
		assert c.pointer.selected();
		assert handled(c.typed(t));
		assert atBottomOf(t);
		assert !c.pointer.selected();
		assert !handled(c.typed(t));
		assert handled(c.keyDown(t, key("Home", CTRL | SHIFT), clip));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert atBottomOf(t);
		assert sink.sent == "x";
		t.shutdown();
	}
}

test "a clipboard read waits for an answer: escape or enter deny it, ctrl enter allows it" {
	const deny: Sink = { sent: "" };
	const a = termOf("\x1b]52;c;?\x1b\\", 20, 5, deny);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("secret"));
		c.clipboardAsked(a, clip);
		assert c.holding();
		assert c.reading == "secret";
		assert deny.sent == "";
		assert handled(c.keyDown(a, key("KeyY", 0), clip));
		assert c.holding();
		assert handled(c.keyDown(a, key("Enter", 0), clip));
		assert !c.holding();
		assert deny.sent == "\x1b]52;c;\x1b\\";
		a.shutdown();
	}
	const allow: Sink = { sent: "" };
	const b = termOf("\x1b]52;c;?\x1b\\", 20, 5, allow);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("secret"));
		c.clipboardAsked(b, clip);
		assert handled(c.keyDown(b, key("Enter", CTRL), clip));
		assert allow.sent == "\x1b]52;c;c2VjcmV0\x1b\\";
		b.shutdown();
	}
}

test "an empty clipboard is answered at once and a read does not ask while the pointer is inert" {
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b]52;c;?\x1b\\", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		c.clipboardAsked(t, clipOf(boardOf("")));
		assert !c.holding();
		assert sink.sent == "\x1b]52;c;\x1b\\";
		c.reading = "x";
		const clip = clipOf(boardOf(""));
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert !handled(c.pointerDown(t, clip, 1, hitAt(0, 0), 0));
		t.shutdown();
	}
}

test "a width change drops the selection, a height change keeps it" {
	const sink: Sink = { sent: "" };
	const t = termOf("0123456789abcde", 10, 3, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		assert drag(c, t, clip, at(0, 1), at(2, 1));
		assert c.refit(t, 10, 4).ok;
		assert c.pointer.selected();
		assert c.refit(t, 20, 4).ok;
		assert !c.pointer.selected();
		t.shutdown();
	}
}
