import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { KeyMod } from "../../../../keys/keys";
import { MouseAction, MouseGeometry, MouseInput } from "../../../../vt/vt";
import { Term, openTerm } from "./term";

export interface Sink {
	sent: string;
}

export function recorder(text: string, sink: Sink): Pty {
	const base = Replay.ofText(text).toPty();
	return {
		wait: base.wait,
		read: base.read,
		write: (data: Readonly<Span<uint8>>): Result<int32, PtyError> => {
			sink.sent += data.asString();
			return Result.ok(data.length as int32);
		},
		resize: base.resize,
		exitCode: base.exitCode,
		close: base.close,
	};
}

function fitted(text: string, cols: int32, rows: int32, sink: Sink): Term | null {
	const opened = openTerm((c: int32, r: int32): Result<Pty, PtyError> => {
		return Result.ok(recorder(text, sink));
	});
	if (!opened.ok) { return null; }
	const t = opened.value;
	if (!t.fit(cols, rows).ok) { return null; }
	return t;
}

export function termOf(text: string, cols: int32, rows: int32, sink: Sink): Term | null {
	const t = fitted(text, cols, rows, sink);
	if (t === null || !t.pumpFrame().ok) { return null; }
	return t;
}

function termFresh(text: string, sink: Sink): Term | null {
	return fitted(text, 20, 5, sink);
}

function rowText(t: Term, y: int32): string {
	return t.grid.at(y).line.text.trimEnd();
}

test "a frame under synchronized output is not applied until the hold ends" {
	const sink: Sink = { sent: "" };
	const t = termFresh("abc\x1b[?2026h", sink);
	assert t !== null;
	if (t !== null) {
		const held = t.pumpFrame();
		assert held.ok;
		if (held.ok) {
			assert held.value.held;
			assert held.value.cursor === null;
		}
		assert rowText(t, 0) == "";
		const s = t.session;
		assert s !== null;
		if (s !== null) { s.vt.writeText("\x1b[?2026l"); }
		const released = t.pumpFrame();
		assert released.ok;
		if (released.ok) {
			assert !released.value.held;
			assert released.value.cursor !== null;
		}
		assert rowText(t, 0) == "abc";
		t.shutdown();
	}
}

test "a frame carries what the program asked of the host: a clipboard write, bells, a title" {
	const sink: Sink = { sent: "" };
	const t = termFresh("\x1b]52;c;aGk=\x07\x07\x07\x1b]2;build done\x07", sink);
	assert t !== null;
	if (t !== null) {
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.copied == "hi";
			assert frame.value.bells == 2;
			assert frame.value.title == "build done";
			assert !frame.value.asked;
		}
		const next = t.pumpFrame();
		assert next.ok;
		if (next.ok) {
			assert next.value.copied === null;
			assert next.value.bells == 0;
			assert next.value.title === null;
		}
		t.shutdown();
	}
}

test "a clipboard read waits in the frame and its answer goes out through the reply queue" {
	const sink: Sink = { sent: "" };
	const t = termFresh("\x1b]52;c;?\x07", sink);
	assert t !== null;
	if (t !== null) {
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
		t.shutdown();
	}
}

test "text past ASCII reaches the program as the same text" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		assert t.sendText("hé").ok;
		assert sink.sent == "hé";
		t.shutdown();
	}
}

test "focus reports go out only while the program asked for them" {
	const off: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, off);
	assert a !== null;
	if (a !== null) {
		assert a.sendFocus(true).ok;
		assert off.sent == "";
		a.shutdown();
	}
	const on: Sink = { sent: "" };
	const b = termOf("\x1b[?1004h", 20, 5, on);
	assert b !== null;
	if (b !== null) {
		assert b.sendFocus(true).ok;
		assert b.sendFocus(false).ok;
		assert on.sent == "\x1b[I\x1b[O";
		b.shutdown();
	}
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
	const quiet: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, quiet);
	assert a !== null;
	if (a !== null) {
		assert a.sendMouse(press, geometry, true).ok;
		assert quiet.sent == "";
		a.shutdown();
	}
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b[?1000h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		assert t.sendMouse(press, geometry, true).ok;
		assert t.sendMouse(release, geometry, false).ok;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
		t.shutdown();
	}
}
