import { NativePty } from "../src/pty/pty";
import { Keys, Vt } from "../src/vt/vt";
import { KeyAction, KeyEvent, KeyMod } from "../src/keys/keys";
import { argv, exit } from "std/process";
import { writeFile } from "std/fs";

struct Case {
	name: string;
	key: string;
	mods: BitSet<KeyMod>;
	unshifted: uint32;
	text: string;
}

const none = 0 as BitSet<KeyMod>;
const shift = none.incl(KeyMod.Shift);
const ctrl = none.incl(KeyMod.Ctrl);
const alt = none.incl(KeyMod.Alt);

const cases: Case[] = [
	{ name: "a", key: "KeyA", mods: none, unshifted: 0x61, text: "a" },
	{ name: "Ctrl+A", key: "KeyA", mods: ctrl, unshifted: 0x61, text: "" },
	{ name: "Ctrl+C", key: "KeyC", mods: ctrl, unshifted: 0x63, text: "" },
	{ name: "Ctrl+Space", key: "Space", mods: ctrl, unshifted: 0x20, text: "" },
	{ name: "Shift+Enter", key: "Enter", mods: shift, unshifted: 0, text: "" },
	{ name: "Ctrl+Enter", key: "Enter", mods: ctrl, unshifted: 0, text: "" },
	{ name: "Ctrl+Backspace", key: "Backspace", mods: ctrl, unshifted: 0, text: "" },
	{ name: "Alt+Backspace", key: "Backspace", mods: alt, unshifted: 0, text: "" },
	{ name: "Shift+Tab", key: "Tab", mods: shift, unshifted: 0, text: "" },
	{ name: "Ctrl+Tab", key: "Tab", mods: ctrl, unshifted: 0, text: "" },
	{ name: "Alt+F", key: "KeyF", mods: alt, unshifted: 0x66, text: "" },
	{ name: "Ctrl+Alt+A", key: "KeyA", mods: ctrl.incl(KeyMod.Alt), unshifted: 0x61, text: "" },
	{ name: "Ctrl+Shift+A", key: "KeyA", mods: ctrl.incl(KeyMod.Shift), unshifted: 0x61, text: "" },
	{ name: "Ctrl+/", key: "Slash", mods: ctrl, unshifted: 0x2F, text: "" },
	{ name: "Ctrl+.", key: "Period", mods: ctrl, unshifted: 0x2E, text: "" },
	{ name: "Ctrl+Left", key: "ArrowLeft", mods: ctrl, unshifted: 0, text: "" },
	{ name: "Shift+Home", key: "Home", mods: shift, unshifted: 0, text: "" },
	{ name: "F5", key: "F5", mods: none, unshifted: 0, text: "" },
	{ name: "Shift+F5", key: "F5", mods: shift, unshifted: 0, text: "" },
	{ name: "Ctrl+F5", key: "F5", mods: ctrl, unshifted: 0, text: "" },
	{ name: "Escape", key: "Escape", mods: none, unshifted: 0, text: "" },
	{ name: "F12", key: "F12", mods: none, unshifted: 0, text: "" },
];

function drain(pty: NativePty, recorded: uint8[], buf: Span<uint8>, ms: int32): void {
	while (true) {
		const ready = pty.wait(ms);
		if (!ready.ok || !ready.value) { return; }
		const r = pty.read(buf);
		if (!r.ok || r.value <= 0) { return; }
		for (let i = 0; i < r.value; i++) { recorded.push(buf[i]); }
	}
}

function main(): int32 {
	if (argv.length < 3) {
		console.log("usage: keysPty <out> <command line...>");
		return 2;
	}
	let command = argv[2];
	for (let i = 3; i < argv.length; i++) { command += " " + argv[i]; }
	const vt = Vt.create(80, 24);
	const keys = Keys.openKeys();
	const opened = NativePty.open(command, 80, 24);
	if (!vt.ok || !keys.ok || !opened.ok) {
		console.log("keysPty: the terminal, the encoder or the command did not start");
		return 1;
	}
	const pty = opened.value;
	let buf: Vec<uint8> = new Array(4096);
	let out: Vec<uint8> = new Array(64);
	const recorded: uint8[] = [];
	drain(pty, recorded, buf, 3000);
	for (const c of cases) {
		const e: KeyEvent = {
			action: KeyAction.Press,
			key: c.key,
			mods: c.mods,
			consumedMods: none,
			unshifted: c.unshifted,
			text: c.text,
		};
		const n = keys.value.encode(vt.value, e, out);
		if (!n.ok) {
			console.log(`keysPty: ${c.name} did not encode`);
			return 1;
		}
		let sent = "";
		for (let i = 0; i < n.value; i++) { sent += `${out[i]} `; }
		for (const b of `\nSENT ${c.name} | ${sent}\n`) { recorded.push(b as uint8); }
		const w = pty.write(out.slice(0, n.value));
		if (!w.ok) { return 1; }
		drain(pty, recorded, buf, 400);
	}
	drain(pty, recorded, buf, 2000);
	pty.close();
	if (!writeFile(argv[1], recorded.asString()).ok) { return 1; }
	console.log(`keysPty: ${cases.length} keys through ${command}`);
	return 0;
}

exit(main());
