import { PtyError } from "./transport";
import { Replay, ofText, toPty } from "./replay";
import { drainText } from "./ptyRig";

test "a replay hands back its bytes in order, whatever the read size" {
	const replay = Replay.ofText("hello, replay");
	assert replay.bytes.length == 13;
	for (const chunk of [4096, 5, 1]) {
		const out = replay.toPty().drainText(chunk);
		assert out.ok, out.error;
		if (out.ok) { assert out.value == "hello, replay"; }
	}
}

test "text split inside a character across reads drains back whole" {
	const text = "hé € 😀!";
	for (const chunk of [1, 3]) {
		const out = Replay.ofText(text).toPty().drainText(chunk);
		assert out.ok, out.error;
		if (out.ok) { assert out.value == text; }
	}
}

test "a replay is ready until its last byte, then ends like a child that exited" {
	const pty = Replay.ofText("ab").toPty();
	let buf: Vec<uint8> = new Array(8);
	assert pty.exitCode() === null;
	const ready = pty.wait(0);
	assert ready.ok;
	if (ready.ok) { assert ready.value; }
	const first = pty.read(buf);
	assert first.ok;
	if (first.ok) { assert first.value == 2; }
	assert pty.exitCode() === 0;
	const ended = pty.read(buf);
	assert !ended.ok;
	if (!ended.ok) { assert ended.error == PtyError.Closed; }
	const readyAtEnd = pty.wait(0);
	assert readyAtEnd.ok;
	if (readyAtEnd.ok) { assert readyAtEnd.value; }
}

test "a replay accepts writes and resizes and changes nothing" {
	const pty = Replay.ofText("xyz").toPty();
	let buf: Vec<uint8> = new Array(8);
	buf[0] = "q".code as uint8;
	assert pty.write(buf[0..1]).ok;
	assert pty.resize(100, 30, 8, 16).ok;
	const out = pty.drainText(8);
	assert out.ok, out.error;
	if (out.ok) { assert out.value == "xyz"; }
}

test "a closed replay refuses every call" {
	const pty = Replay.ofText("xyz").toPty();
	let buf: Vec<uint8> = new Array(8);
	pty.close();
	assert !pty.wait(0).ok;
	assert !pty.read(buf).ok;
	assert !pty.write(buf[0..1]).ok;
	assert !pty.resize(100, 30, 8, 16).ok;
}

test "a replay can be played again from its start" {
	const replay = Replay.ofText("again");
	for (const _play of [1, 2]) {
		const out = replay.toPty().drainText(8);
		assert out.ok, out.error;
		if (out.ok) { assert out.value == "again"; }
	}
}
