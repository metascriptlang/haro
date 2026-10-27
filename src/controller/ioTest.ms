import { Io, frame, key, open, text } from "./io";
import { Term } from "./term";
import { NO_MODS } from "../keys/keys";
import { MouseButton } from "./mouseButton";
import { Sink, hitAt, key as keyOf, lines, offsetOf, onFresh, onTerm } from "./terminalRig";

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
