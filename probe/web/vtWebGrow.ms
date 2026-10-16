// Page growth: 5000 lines of output make the terminal allocate many pages through the embedder's
// allocator. Exit 0 = the last line is on screen, the scrollback grew, a key still encodes and
// everything frees.
import { Vt, Keys } from "../../src/vt/vt";
import { KeyAction, KeyEvent, KeyMod } from "../../src/keys/keys";

function check(): int32 {
	const created = Vt.create(80, 24);
	if (!created.ok) { return 10; }
	const vt = created.value;
	for (let i = 0; i < 5000; i++) { vt.writeText(`line ${i}\r\n`); }
	if (!vt.update().ok) { return 11; }
	const lines = vt.lines();
	if (!lines.ok) { return 12; }
	if (lines.value.length != 24) { return 13; }
	if (lines.value[22] != "line 4999") { return 14; }
	const offset = vt.scrollOffset();
	if (!offset.ok) { return 15; }
	if (offset.value < 4000) { return 16; }
	const opened = Keys.openKeys();
	if (!opened.ok) { return 20; }
	const keys = opened.value;
	const event: KeyEvent = {
		action: KeyAction.Press,
		key: "Enter",
		mods: 0 as BitSet<KeyMod>,
		consumedMods: 0 as BitSet<KeyMod>,
		unshifted: 0x0D,
		text: "\r",
	};
	let buf: Vec<uint8> = new Array(64);
	const written = keys.encode(vt, event, buf);
	if (!written.ok) { return 21; }
	if (written.value != 1 || buf[0] != 0x0D) { return 22; }
	keys.freeKeys();
	vt.free();
	return 0;
}

process.exit(check());
