import {
	KeyAction,
	KeyEvent,
	KeyMod,
	OptionAsAlt,
	keyEvent,
} from "../keys/keys";
import {
	Keys,
	PasteError,
	Vt,
	encode,
	freeKeys,
	openKeys,
	pasteBytes,
	writeText,
} from "./vt";
import { ascii, withVt } from "./vtRig";

function press(key: string, text: string, unshifted: uint32, mods: BitSet<KeyMod>): KeyEvent {
	return { ...keyEvent(KeyAction.Press, key, mods), unshifted: unshifted, text: text };
}

function encoded(this k: Keys, vt: Vt, e: KeyEvent): string {
	let buf: Vec<uint8> = new Array(64);
	const r = k.encode(vt, e, buf);
	if (!r.ok) { return ""; }
	return ascii(buf[0..r.value]);
}

function withKeys(body: (k: Keys, vt: Vt) => void): boolean {
	const opened = Keys.openKeys();
	if (!opened.ok) { return false; }
	const k = opened.value;
	const made = withVt(20, 4, (vt: Vt): void => { body(k, vt); });
	k.freeKeys();
	return made;
}

test "AltGr text reaches the program as the text once the consumed Ctrl+Alt is dropped" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt);
		const brace: KeyEvent = { ...press("Digit7", "{", 0x37, ctrlAlt), consumedMods: ctrlAlt };
		assert k.encoded(vt, brace.withoutAltGr()) == "{";
		const polish: KeyEvent = { ...brace, key: "KeyA", unshifted: 0x61, text: "ą" };
		assert k.encoded(vt, polish.withoutAltGr()) == "Ä\u0085";
	});
}

test "enter encodes as a carriage return" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert k.encoded(vt, press("Enter", "\r", 0x0D, none)) == "\r";
	});
}

test "ctrl+c encodes as ETX even when the platform reports the byte as text" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const ctrl = (0 as BitSet<KeyMod>).incl(KeyMod.Ctrl);
		assert k.encoded(vt, press("KeyC", "\x03", 0x63, ctrl)) == "\x03";
	});
}

test "arrow up follows the cursor key mode the vt is in" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert k.encoded(vt, press("ArrowUp", "", 0, none)) == "\x1b[A";
		vt.writeText("\x1b[?1h");
		assert k.encoded(vt, press("ArrowUp", "", 0, none)) == "\x1bOA";
	});
}

test "alt prefixes the escape, except macOS Option, whose text the system composes" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const alt = (0 as BitSet<KeyMod>).incl(KeyMod.Alt);
		when (macos) {
			assert k.encoded(vt, press("KeyX", "x", 0x78, alt)) == "x";
		} else {
			assert k.encoded(vt, press("KeyX", "x", 0x78, alt)) == "\x1bx";
		}
	});
}

test "macOS Option sends the escape before the key text the window kept when it acts as Alt" {
	assert withKeys((given: Keys, vt: Vt): void => {
		let k = given;
		const shift = (0 as BitSet<KeyMod>).incl(KeyMod.Shift);
		const left = shift.incl(KeyMod.Alt);
		const asAlt: KeyEvent = { ...press("KeyB", "B", 0x62, left), consumedMods: shift };
		const composed: KeyEvent = { ...press("KeyB", "ı", 0x62, left), consumedMods: left };
		when (macos) {
			k.optionAsAlt = OptionAsAlt.Left;
			assert k.encoded(vt, asAlt) == "\x1bB";
			k.optionAsAlt = OptionAsAlt.Neither;
			assert k.encoded(vt, composed) == "\u00c4\u00b1";
		} else {
			assert k.encoded(vt, asAlt) == "\x1bB";
			assert k.encoded(vt, composed) == "\u00c4\u00b1";
		}
	});
}

test "a consumed alt lets the text through unprefixed" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const alt = none.incl(KeyMod.Alt);
		const e: KeyEvent = { ...press("BracketLeft", "{", 0x5B, alt), consumedMods: alt };
		assert k.encoded(vt, e) == "{";
	});
}

test "ctrl with printable text encodes as fixterms csi u" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt);
		const e: KeyEvent = { ...press("BracketLeft", "{", 0x5B, ctrlAlt), consumedMods: ctrlAlt };
		assert k.encoded(vt, e) == "\x1b[123;7u";
	});
}

test "a committed grapheme arrives as its utf-8 bytes" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		let buf: Vec<uint8> = new Array(64);
		const r = k.encode(vt, press("Unidentified", "ệ", 0, none), buf);
		assert r.ok;
		if (r.ok) {
			assert r.value == 3;
			assert buf[0] == 0xE1;
			assert buf[1] == 0xBB;
			assert buf[2] == 0x87;
		}
	});
}

function pasted(this vt: Vt, text: string, allowUnsafe: boolean): string {
	const bytes = vt.pasteBytes(text, allowUnsafe);
	if (bytes.ok) { return ascii(bytes.value); }
	return bytes.error == PasteError.Unsafe ? "<unsafe>" : "<failed>";
}

test "an unbracketed paste turns newlines into carriage returns and refuses them unconfirmed" {
	assert withVt(10, 4, (vt: Vt): void => {
		assert vt.pasted("hello", false) == "hello";
		assert vt.pasted("a\nb", false) == "<unsafe>";
		assert vt.pasted("a\nb", true) == "a\rb";
	});
}

test "a bracketed paste is framed and only its end marker is unsafe" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("\x1b[?2004h");
		assert vt.pasted("a\nb", false) == "\x1b[200~a\nb\x1b[201~";
		assert vt.pasted("x\x1b[31my", false) == "\x1b[200~x [31my\x1b[201~";
		assert vt.pasted("evil\x1b[201~rm", false) == "<unsafe>";
		vt.writeText("\x1b[?2004l");
		assert vt.pasted("plain", false) == "plain";
	});
}

test "a key's text typed from the heap encodes as that text" {
	assert withKeys((k: Keys, vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		for (const c of ["a", "l", "j", "ệ"]) {
			const typed = press("Unidentified", `x${c}`.substring(1), 0, none);
			assert k.encoded(vt, typed) == ascii(c.asBytes());
		}
	});
}
