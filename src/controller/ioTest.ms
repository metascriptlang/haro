import { Io, frame, key, keyReleased, move, open, text } from "./io";
import { Term } from "./term";
import { KeyAction, NO_MODS, keyEvent, modSet } from "../keys/keys";
import { OPEN_MOD } from "../input/pointer";
import { MouseButton } from "./mouseButton";
import { Sink, hitAt, hitWith, key as keyOf, lines, offsetOf, onFresh, onTerm } from "./terminalRig";

test "a frame carries the time of the first input that reached the shell since the last frame, once" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		io.text("", 3);
		io.key({ ...keyOf("KeyA", NO_MODS), unshifted: 0x61, text: "a" }, 5);
		io.text("b", 6);
		assert sink.sent == "ab";
		assert io.frame().keyAt == 5;
		assert io.frame().keyAt == -1;
	}).ok;
}

test "a frame carries the launch marks the terminal took when it started, once" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		const first = io.frame().marks;
		assert first.length == 2;
		assert first[0].name == "layout";
		assert first[1].name == "spawned";
		assert io.frame().marks.length == 0;
	}).ok;
}

test "a frame after a drain shows the output the shell wrote" {
	assert onFresh("hello", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		io.fit(20, 3, 0, 0);
		io.drain();
		const f = io.frame().frame;
		assert f !== null;
		if (f !== null) {
			const rows = f.rows;
			assert rows !== null;
			if (rows !== null) { assert rows.rows[0].line.text.startsWith("hello"); }
		}
	}).ok;
}

test "dragging above the grid asks for autoscroll, each tick scrolls up one line, and a release ends it" {
	assert onTerm(lines(30), (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		const bottom = offsetOf(t);
		io.press(MouseButton.Left, hitAt(3, 2), 0);
		io.move({ ...hitAt(3, 0), y: -12 }, true);
		assert io.frame().autoscroll;
		io.autoscroll();
		io.autoscroll();
		assert offsetOf(t) == bottom - 2;
		io.release(MouseButton.Left, { ...hitAt(3, 0), y: -12 });
		assert !io.frame().autoscroll;
		io.autoscroll();
		assert offsetOf(t) == bottom - 2;
	}).ok;
}

test "relight returns the cursor's row in the given ink, and nothing before its first frame" {
	assert onFresh("hello", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		assert io.relight(null).rows.length == 0;
		io.fit(20, 3, 0, 0);
		const _first = io.frame();
		const rows = io.relight({ fg: null, bg: { r: 9, g: 9, b: 9 } });
		assert rows.rows.length == 1;
		assert rows.rows[0].line.text.startsWith("hello");
	}).ok;
}

when (macos) {
	const OPEN_KEY = "MetaLeft";
} else {
	const OPEN_KEY = "ControlLeft";
}

test "pressing and releasing the open modifier over a link shows and drops its hover without the pointer moving" {
	assert onTerm("see https://b.io. ok", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		io.move(hitWith(8, 0, NO_MODS), false);
		assert !io.frame().hoverChanged;
		io.key(keyEvent(KeyAction.Press, OPEN_KEY, modSet(OPEN_MOD)), 0);
		const shown = io.frame();
		assert shown.hoverChanged;
		const link = shown.hover;
		assert link !== null;
		if (link !== null) { assert link.uri == "https://b.io"; }
		assert !io.frame().hoverChanged;
		io.keyReleased(keyEvent(KeyAction.Release, OPEN_KEY, NO_MODS));
		const gone = io.frame();
		assert gone.hoverChanged;
		assert gone.hover === null;
		assert sink.sent == "";
	}, 40, 5).ok;
}
