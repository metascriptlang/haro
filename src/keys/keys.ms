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

export const NO_MODS = 0 as BitSet<KeyMod>;

export function modSet(mod: KeyMod): BitSet<KeyMod> {
	return NO_MODS.incl(mod);
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

export enum OptionAsAlt {
	Neither,
	Left,
	Right,
	Both,
}

function navigationOf(numpadKey: string): string {
	return match (numpadKey) {
		"Numpad0" => "NumpadInsert",
		"Numpad1" => "NumpadEnd",
		"Numpad2" => "NumpadDown",
		"Numpad3" => "NumpadPageDown",
		"Numpad4" => "NumpadLeft",
		"Numpad5" => "NumpadBegin",
		"Numpad6" => "NumpadRight",
		"Numpad7" => "NumpadHome",
		"Numpad8" => "NumpadUp",
		"Numpad9" => "NumpadPageUp",
		"NumpadDecimal" => "NumpadDelete",
		_ => numpadKey,
	};
}

export function withNumLockApplied(this e: KeyEvent): KeyEvent {
	if (e.mods.has(KeyMod.NumLock)) { return e; }
	const key = navigationOf(e.key);
	if (key == e.key) { return e; }
	return { ...e, key: key, unshifted: 0, text: "" };
}

export function heldAfter(held: KeyEvent | null, e: KeyEvent): KeyEvent | null {
	let kept: KeyEvent = { ...e, text: "" };
	if (e.action == KeyAction.Release) {
		if (held === null) { return null; }
		if (held.key == e.key) { kept = { ...kept, key: "" }; }
	}
	if (kept.key == "" && kept.mods.isEmpty()) { return null; }
	return kept;
}

struct ModifierKeys {
	mod: KeyMod;
	side: KeyMod;
	right: string;
	left: string;
}

const MODIFIER_KEYS: Vec<ModifierKeys> = [
	{ mod: KeyMod.Shift, side: KeyMod.ShiftRight, right: "ShiftRight", left: "ShiftLeft" },
	{ mod: KeyMod.Ctrl, side: KeyMod.CtrlRight, right: "ControlRight", left: "ControlLeft" },
	{ mod: KeyMod.Alt, side: KeyMod.AltRight, right: "AltRight", left: "AltLeft" },
	{ mod: KeyMod.Super, side: KeyMod.SuperRight, right: "MetaRight", left: "MetaLeft" },
];

export function modifierKey(code: string): boolean {
	if (code == "CapsLock" || code == "Fn") { return true; }
	for (const m of MODIFIER_KEYS) {
		if (code == m.left || code == m.right) { return true; }
	}
	return false;
}

export function releasesOf(this held: KeyEvent): Vec<KeyEvent> {
	let release: KeyEvent = { ...held, action: KeyAction.Release };
	let out: Vec<KeyEvent> = [];
	if (release.key != "") { out.push(release); }
	for (const m of MODIFIER_KEYS) {
		if (!release.mods.has(m.mod)) { continue; }
		release = { ...release, mods: release.mods.excl(m.mod).excl(m.side) };
		for (const key of [m.right, m.left]) {
			if (key != held.key) { out.push({ ...release, key: key, unshifted: 0 }); }
		}
	}
	return out;
}

export function modsMask(mods: BitSet<KeyMod>): uint16 {
	return (mods as uint32) as uint16;
}

const MODS_LIMIT: int32 = 1 << 10;

export function modsOf(mask: number): BitSet<KeyMod> {
	if (!(mask >= 0 && mask < MODS_LIMIT) || Math.floor(mask) != mask) {
		throw new Error(`modifier mask ${mask} is not a set of the ${MODS_LIMIT} KeyMod bits`);
	}
	return (mask as uint16) as BitSet<KeyMod>;
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
	const ctrlAlt = NO_MODS.incl(KeyMod.Ctrl).incl(KeyMod.Alt).incl(KeyMod.AltRight);
	const altGr: KeyEvent = {
		action: KeyAction.Press,
		key: "KeyQ",
		mods: ctrlAlt.incl(KeyMod.Shift),
		consumedMods: ctrlAlt,
		unshifted: 0x71,
		text: "@",
	};
	const typed = altGr.withoutAltGr();
	assert typed.mods == NO_MODS.incl(KeyMod.Shift);
	assert typed.consumedMods == NO_MODS;
	const chord: KeyEvent = { ...altGr, consumedMods: NO_MODS, text: "" };
	assert chord.withoutAltGr().mods == chord.mods;
}

test "a keypad digit with NumLock off is the navigation key printed under it" {
	const eight: KeyEvent = {
		action: KeyAction.Press,
		key: "Numpad8",
		mods: NO_MODS,
		consumedMods: NO_MODS,
		unshifted: 0x38,
		text: "",
	};
	assert eight.withNumLockApplied().key == "NumpadUp";
	assert eight.withNumLockApplied().unshifted == 0;
	const decimal: KeyEvent = { ...eight, key: "NumpadDecimal" };
	assert decimal.withNumLockApplied().key == "NumpadDelete";
	const locked: KeyEvent = { ...eight, mods: NO_MODS.incl(KeyMod.NumLock), text: "8" };
	assert locked.withNumLockApplied().key == "Numpad8";
	assert locked.withNumLockApplied().text == "8";
	const plus: KeyEvent = { ...eight, key: "NumpadAdd", text: "+" };
	assert plus.withNumLockApplied().text == "+";
}

test "the modifier mask keeps libghostty-vt's bit order" {
	assert modsMask(NO_MODS) == 0;
	assert modsMask(NO_MODS.incl(KeyMod.Shift)) == 0x01;
	assert modsMask(NO_MODS.incl(KeyMod.Ctrl)) == 0x02;
	assert modsMask(NO_MODS.incl(KeyMod.Alt)) == 0x04;
	assert modsMask(NO_MODS.incl(KeyMod.NumLock)) == 0x20;
	assert modsMask(NO_MODS.incl(KeyMod.ShiftRight)) == 0x40;
	assert modsMask(NO_MODS.incl(KeyMod.AltRight)) == 0x100;
	const wide = NO_MODS.incl(KeyMod.Ctrl).incl(KeyMod.AltRight);
	assert modsOf(modsMask(wide)) == wide;
}

test "a modifier mask outside the KeyMod bits is refused" {
	for (const bad of [-1, 1024, 65537, 1.5]) {
		let refused = false;
		try { modsOf(bad); } catch (e) { refused = true; }
		assert refused;
	}
	assert modsOf(1023).has(KeyMod.SuperRight);
}

function event(action: KeyAction, key: string, mods: BitSet<KeyMod>): KeyEvent {
	return { action: action, key: key, mods: mods, consumedMods: NO_MODS, unshifted: 0, text: "" };
}

test "the key still held is the last one pressed, until its release leaves only the modifiers held with it" {
	const empty = NO_MODS;
	const ctrl = empty.incl(KeyMod.Ctrl);
	const a = event(KeyAction.Press, "KeyA", ctrl);
	const held = heldAfter(null, a);
	assert held !== null && held.key == "KeyA";
	const left = heldAfter(held, event(KeyAction.Release, "KeyA", ctrl));
	assert left !== null && left.key == "" && left.mods == ctrl;
	assert heldAfter(held, event(KeyAction.Release, "KeyA", empty)) === null;
	assert heldAfter(null, event(KeyAction.Release, "KeyA", ctrl)) === null;
}

test "a focus loss releases the held key, then each held modifier on both sides" {
	const ctrlShift = KeyMod.Shift | KeyMod.Ctrl;
	const sent = releasesOf(event(KeyAction.Press, "KeyA", ctrlShift))
		.map((e: KeyEvent): string => `${e.key}:${modsMask(e.mods)}`).join(" ");
	assert sent == "KeyA:3 ShiftRight:2 ShiftLeft:2 ControlRight:0 ControlLeft:0";
	const shift = ctrlShift.excl(KeyMod.Ctrl);
	const own = releasesOf(event(KeyAction.Press, "ShiftLeft", shift)).map((e: KeyEvent): string => e.key).join(" ");
	assert own == "ShiftLeft ShiftRight";
	const plain = releasesOf(event(KeyAction.Press, "KeyA", NO_MODS));
	assert plain.length == 1 && plain[0].action == KeyAction.Release;
}
