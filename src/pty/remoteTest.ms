import { RemotePty, Seed, asPty, empty, feed, seededVt, takeTyped } from "./remote";
import { Pty } from "./transport";
import { Session, pump, sendReplies, send } from "../session/session";
import { nativeSnapshot, snapshot } from "../vt/snapshot";
import { Vt, answerClipboard, create, free, lines, size, update, writeText } from "../vt/vt";
import { ascii } from "../vt/vtRig";

const COLS: int32 = 30;
const ROWS: int32 = 5;
const DEVICE_QUERIES = "\x1b[c\x1b[>c\x1b[6n\x1b[5n\x1b]11;?\x07";

function text(this vt: Vt): string {
	if (!vt.update().ok) { return "<update failed>"; }
	const got = vt.lines();
	return got.ok ? got.value.join("\n") : "<lines failed>";
}

function ready(pty: Pty): boolean {
	const got = pty.wait(0);
	return got.ok && got.value;
}

function fed(r: RemotePty, seq: uint64, s: string): boolean {
	let bytes: Vec<uint8> = [];
	for (const b of s.asBytes()) { bytes.push(b); }
	return r.feed(seq, bytes);
}

test "output is read in seq order across chunk edges, and a seq at or below the last one is refused" {
	const r = RemotePty.empty();
	const pty = r.asPty();
	assert !ready(pty);
	assert fed(r, 1, "abcdef");
	assert fed(r, 3, "gh");
	assert !fed(r, 2, "late");
	assert !fed(r, 3, "again");
	assert ready(pty);
	let buf: Vec<uint8> = new Array(4);
	let read = "";
	while (ready(pty)) {
		const got = pty.read(buf);
		assert got.ok;
		if (got.ok) { read += ascii(buf[0..got.value]); }
	}
	assert read == "abcdefgh";
}

test "a remote pane's writes are kept for the window to send, and its foreground counts as busy" {
	const r = RemotePty.empty();
	const pty = r.asPty();
	assert pty.write("ls\r".asBytes()).ok;
	assert pty.write("x".asBytes()).ok;
	assert ascii(r.takeTyped()) == "ls\rx";
	assert r.takeTyped().length == 0;
	assert pty.busy();
	assert pty.exitCode() === null;
	pty.close();
	assert !pty.write("y".asBytes()).ok;
}

function sessionOver(pty: Pty): Session | null {
	const started = Session.start(pty, COLS, ROWS);
	return started.ok ? started.value : null;
}

test "the window's VT answers no device query of a remote pane, while a local pty gets every answer" {
	for (const remote of [true, false]) {
		const r = RemotePty.empty();
		const pty: Pty = { ...r.asPty(), takesReplies: !remote };
		const s = sessionOver(pty);
		assert s !== null;
		if (s !== null) {
			assert fed(r, 1, `before${DEVICE_QUERIES}after`);
			let buf: Vec<uint8> = new Array(64);
			while (ready(s.pty)) { assert s.pump(buf).ok; }
			const answered = ascii(r.takeTyped());
			if (remote) {
				assert answered == "";
			} else {
				assert answered.length > 0;
			}
			assert s.vt.text().startsWith("beforeafter");
			s.close();
		}
	}
}

test "a remote pane still sends the clipboard answer the user gave, which the server's VT never sends" {
	const r = RemotePty.empty();
	const s = sessionOver(r.asPty());
	assert s !== null;
	if (s !== null) {
		assert fed(r, 1, "\x1b]52;c;?\x07");
		let buf: Vec<uint8> = new Array(64);
		while (ready(s.pty)) { assert s.pump(buf).ok; }
		assert r.takeTyped().length == 0;
		assert s.vt.answerClipboard("hi", true).ok;
		assert s.sendReplies().ok;
		assert ascii(r.takeTyped()) == "\x1b]52;c;aGk=\x07";
		assert s.send("typed".asBytes()).ok;
		assert ascii(r.takeTyped()) == "typed";
		s.close();
	}
}

function serverVt(): Vt | null {
	const made = Vt.create(COLS, ROWS);
	if (!made.ok) { return null; }
	made.value.writeText("first line\r\n\x1b[1;32mgreen\x1b[0m second\r\n$ ");
	return made.value;
}

test "a native or VT-bytes screen, or none, seeds a VT that shows the server's text" {
	const server = serverVt();
	assert server !== null;
	if (server !== null) {
		const want = server.text();
		assert want.startsWith("first line\ngreen second\n$");
		const native = server.nativeSnapshot();
		const bytes = server.snapshot();
		assert native.ok && bytes.ok;
		if (native.ok && bytes.ok) {
			const seeds: Seed[] = [
				{ native: true, cols: COLS, rows: ROWS, bytes: native.value },
				{ native: false, cols: COLS, rows: ROWS, bytes: bytes.value },
			];
			for (const seed of seeds) {
				const vt = seed.seededVt();
				assert vt.ok;
				if (vt.ok) {
					assert vt.value.text() == want;
					vt.value.free();
				}
			}
		}
		const none: Seed = { native: true, cols: COLS, rows: ROWS, bytes: [] };
		const blank = none.seededVt();
		assert blank.ok;
		if (blank.ok) {
			assert blank.value.text().trim() == "";
			blank.value.free();
		}
		const junk: Seed = { native: true, cols: COLS, rows: ROWS, bytes: [1, 2, 3] };
		const garbled = junk.seededVt();
		assert !garbled.ok;
		server.free();
	}
}

test "a seeded session starts on the server's screen and resizes it to the window's grid" {
	const server = serverVt();
	assert server !== null;
	if (server !== null) {
		const native = server.nativeSnapshot();
		assert native.ok;
		if (native.ok) {
			const r = RemotePty.empty();
			const seed: Seed = { native: true, cols: COLS, rows: ROWS, bytes: native.value };
			const started = Session.start(r.asPty(), COLS + 10, ROWS + 2, 0, 0, seed);
			assert started.ok;
			if (started.ok) {
				const s = started.value;
				assert s.vt.text().startsWith("first line\ngreen second\n$");
				const size = s.vt.size();
				assert size.ok && size.value[0] == COLS + 10 && size.value[1] == ROWS + 2;
				s.close();
			}
		}
		server.free();
	}
}
