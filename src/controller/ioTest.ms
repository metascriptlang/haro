import { Io, frame, key, open, text } from "./io";
import { Term } from "./term";
import { Sink, key as keyOf, onFresh } from "./terminalRig";

test "a frame carries the time of the first input that reached the shell since the last frame, once" {
	assert onFresh("", (t: Term, sink: Sink): void => {
		const io = Io.open(t);
		io.text("", 3);
		io.key({ ...keyOf("KeyA", 0), unshifted: 0x61, text: "a" }, 5);
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
