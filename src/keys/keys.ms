export enum KeyAction {
	Release,
	Press,
	Repeat,
}

export enum KeyMod {
	Shift,
	Ctrl,
	Alt,
	Super,
	CapsLock,
	NumLock,
	ShiftRight,
	CtrlRight,
	AltRight,
	SuperRight,
}

export struct KeyEvent {
	action: KeyAction;
	key: string;
	mods: BitSet<KeyMod>;
	consumedMods: BitSet<KeyMod>;
	unshifted: uint32;
	text: string;
}

const ALT_GR: BitSet<KeyMod> = KeyMod.Ctrl | KeyMod.Alt | KeyMod.CtrlRight | KeyMod.AltRight;

export function withoutAltGr(this e: KeyEvent): KeyEvent {
	if (!e.consumedMods.has(KeyMod.Ctrl) || !e.consumedMods.has(KeyMod.Alt)) { return e; }
	return {
		...e,
		mods: e.mods.difference(ALT_GR),
		consumedMods: e.consumedMods.difference(ALT_GR),
	};
}

export function modsMask(mods: BitSet<KeyMod>): uint16 {
	return (mods as uint32) as uint16;
}

const DELETE: int32 = 0x7F;
const MAC_FUNCTION_KEY_LEAD: int32 = 0xEF;
const MAC_FUNCTION_KEY_SECOND_MIN: int32 = 0x9C;
const MAC_FUNCTION_KEY_SECOND_MAX: int32 = 0xA3;

export function textSafe(text: string): boolean {
	if (text == "") { return false; }
	const bytes: Readonly<Span<char>> = text;
	const n = text.byteLength as int32;
	for (let i = 0; i < n; i++) {
		const b = bytes[i] as int32;
		if (b < 0x20 || b == DELETE) { return false; }
		if (b == MAC_FUNCTION_KEY_LEAD && i + 1 < n) {
			const second = bytes[i + 1] as int32;
			if (second >= MAC_FUNCTION_KEY_SECOND_MIN && second <= MAC_FUNCTION_KEY_SECOND_MAX) {
				return false;
			}
		}
	}
	return true;
}

test "text a platform reports for a control key is not passed on as text" {
	assert !textSafe("");
	assert !textSafe("\r");
	assert !textSafe("\x03");
	assert textSafe("a");
	assert textSafe("ệ");
}

test "macOS private-use function key codes are not passed on as text" {
	assert !textSafe(String.fromCharCode(0xF700));
	assert !textSafe(String.fromCharCode(0xF8FF));
	assert textSafe(String.fromCharCode(0xF00F));
}

test "Ctrl+Alt the layout consumed for AltGr text is dropped, and a plain Ctrl+Alt is kept" {
	const none = 0 as BitSet<KeyMod>;
	const ctrlAlt = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt).incl(KeyMod.AltRight);
	const altGr: KeyEvent = {
		action: KeyAction.Press,
		key: "KeyQ",
		mods: ctrlAlt.incl(KeyMod.Shift),
		consumedMods: ctrlAlt,
		unshifted: 0x71,
		text: "@",
	};
	const typed = altGr.withoutAltGr();
	assert typed.mods == none.incl(KeyMod.Shift);
	assert typed.consumedMods == none;
	const chord: KeyEvent = { ...altGr, consumedMods: none, text: "" };
	assert chord.withoutAltGr().mods == chord.mods;
}

test "the modifier mask keeps libghostty-vt's bit order" {
	const none = 0 as BitSet<KeyMod>;
	assert modsMask(none) == 0;
	assert modsMask(none.incl(KeyMod.Shift)) == 0x01;
	assert modsMask(none.incl(KeyMod.Ctrl)) == 0x02;
	assert modsMask(none.incl(KeyMod.Alt)) == 0x04;
	assert modsMask(none.incl(KeyMod.NumLock)) == 0x20;
	assert modsMask(none.incl(KeyMod.ShiftRight)) == 0x40;
	assert modsMask(none.incl(KeyMod.AltRight)) == 0x100;
}
