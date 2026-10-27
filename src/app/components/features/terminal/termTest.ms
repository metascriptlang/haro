import { KeyMod } from "../../../../keys/keys";
import { MouseAction, MouseGeometry, MouseInput } from "../../../../vt/vt";
import { View, fitRows, open, paint, text } from "../../../frame";
import { Term } from "./term";
import { Sink, onFresh, onTerm } from "./terminalRig";

test "a frame under synchronized output is not applied until the hold ends" {
	assert onFresh("abc\x1b[?2026h", (t: Term, sink: Sink): void => {
		const held = t.pumpFrame();
		assert held.ok;
		if (held.ok) {
			assert held.value.held;
			assert held.value.cursor === null;
			assert held.value.rows === null;
		}
		const s = t.session;
		assert s !== null;
		if (s !== null) { s.vt.writeText("\x1b[?2026l"); }
		const released = t.pumpFrame();
		assert released.ok;
		if (released.ok) {
			assert !released.value.held;
			assert released.value.cursor !== null;
			const rows = released.value.rows;
			assert rows !== null;
			if (rows !== null) {
				const view = View.open();
				view.fitRows(t.shown.length as int32);
				view.paint(rows);
				assert view.text(0) == "abc";
			}
		}
	}).ok;
}

test "a frame carries what the program asked of the host: a clipboard write, bells, a title, a notification" {
	const asked = "\x1b]52;c;aGk=\x07\x07\x07\x1b]2;build done\x07\x1b]9;tests passed\x07";
	assert onFresh(asked, (t: Term, sink: Sink): void => {
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.copied == "hi";
			assert frame.value.bells == 2;
			assert frame.value.title == "build done";
			const notification = frame.value.notification;
			assert notification !== null;
			if (notification !== null) { assert notification.body == "tests passed"; }
			assert !frame.value.asked;
		}
		const next = t.pumpFrame();
		assert next.ok;
		if (next.ok) {
			assert next.value.copied === null;
			assert next.value.bells == 0;
			assert next.value.title === null;
			assert next.value.notification === null;
		}
	}).ok;
}

test "a clipboard read waits in the frame and its answer goes out through the reply queue" {
	assert onFresh("\x1b]52;c;?\x07", (t: Term, sink: Sink): void => {
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) { assert frame.value.asked; }
		assert sink.sent == "";
		const s = t.session;
		assert s !== null;
		if (s !== null) { assert s.vt.answerClipboard("x", true).ok; }
		const sent = t.sendReplies();
		assert sent.ok;
		assert sink.sent == "\x1b]52;c;eA==\x07";
	}).ok;
}

test "text past ASCII reaches the program as the same text" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		assert t.sendText("hé").ok;
		assert sink.sent == "hé";
	}).ok;
}

test "focus reports go out only while the program asked for them" {
	assert onTerm("ready", (a: Term, off: Sink): void => {
		assert a.sendFocus(true).ok;
		assert off.sent == "";
	}).ok;
	assert onTerm("\x1b[?1004h", (b: Term, on: Sink): void => {
		assert b.sendFocus(true).ok;
		assert b.sendFocus(false).ok;
		assert on.sent == "\x1b[I\x1b[O";
	}).ok;
}

test "a mouse report is the program's encoding of the pointer, nothing while it asked for none" {
	const geometry: MouseGeometry = {
		cellWidth: 8,
		cellHeight: 16,
		width: 160,
		height: 80,
		padLeft: 0,
		padTop: 0,
		padRight: 0,
		padBottom: 0,
	};
	const none = 0 as BitSet<KeyMod>;
	const press: MouseInput = { action: MouseAction.Press, button: 1, mods: none, x: 17, y: 17 };
	const release: MouseInput = { ...press, action: MouseAction.Release };
	assert onTerm("ready", (a: Term, quiet: Sink): void => {
		assert a.sendMouse(press, geometry, true).ok;
		assert quiet.sent == "";
	}).ok;
	assert onTerm("\x1b[?1000h\x1b[?1006h", (t: Term, sink: Sink): void => {
		assert t.sendMouse(press, geometry, true).ok;
		assert t.sendMouse(release, geometry, false).ok;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
	}).ok;
}
