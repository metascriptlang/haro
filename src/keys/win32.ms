import { KeyAction, KeyMod } from "./keys";

// A key as win32-input-mode carries it, one KEY_EVENT_RECORD (microsoft/terminal spec #4999).
export struct Win32Key {
	action: KeyAction;
	vk: uint16;
	scancode: int32;
	char: uint16;
	mods: BitSet<KeyMod>;
}

const RIGHT_ALT_PRESSED: uint32 = 0x01;
const LEFT_ALT_PRESSED: uint32 = 0x02;
const RIGHT_CTRL_PRESSED: uint32 = 0x04;
const LEFT_CTRL_PRESSED: uint32 = 0x08;
const SHIFT_PRESSED: uint32 = 0x10;
const NUMLOCK_ON: uint32 = 0x20;
const CAPSLOCK_ON: uint32 = 0x80;
const ENHANCED_KEY: uint32 = 0x100;
const EXTENDED_PREFIX: int32 = 0xE000;

export function controlState(mods: BitSet<KeyMod>, scancode: int32): uint32 {
	let state: uint32 = 0;
	if (mods.has(KeyMod.Shift)) { state |= SHIFT_PRESSED; }
	if (mods.has(KeyMod.Ctrl)) { state |= mods.has(KeyMod.CtrlRight) ? RIGHT_CTRL_PRESSED : LEFT_CTRL_PRESSED; }
	if (mods.has(KeyMod.Alt)) { state |= mods.has(KeyMod.AltRight) ? RIGHT_ALT_PRESSED : LEFT_ALT_PRESSED; }
	if (mods.has(KeyMod.NumLock)) { state |= NUMLOCK_ON; }
	if (mods.has(KeyMod.CapsLock)) { state |= CAPSLOCK_ON; }
	if ((scancode & 0xFF00) == EXTENDED_PREFIX) { state |= ENHANCED_KEY; }
	return state;
}

export function win32Input(k: Win32Key): string {
	const down = k.action == KeyAction.Release ? 0 : 1;
	return `\x1b[${k.vk};${k.scancode & 0xFF};${k.char};${down};${controlState(k.mods, k.scancode)};1_`;
}

const none = 0 as BitSet<KeyMod>;

test "a Ctrl chord carries its control character and the left Ctrl" {
	const k: Win32Key = { action: KeyAction.Press, vk: 0x41, scancode: 0x1E, char: 0x01, mods: none.incl(KeyMod.Ctrl) };
	assert win32Input(k) == "\x1b[65;30;1;1;8;1_";
}

test "a release is the same record with the key up" {
	const k: Win32Key = { action: KeyAction.Release, vk: 0x0D, scancode: 0x1C, char: 0x0D, mods: none.incl(KeyMod.Shift) };
	assert win32Input(k) == "\x1b[13;28;13;0;16;1_";
}

test "a repeat is sent as another key down" {
	const k: Win32Key = { action: KeyAction.Repeat, vk: 0x20, scancode: 0x39, char: 0x20, mods: none };
	assert win32Input(k) == "\x1b[32;57;32;1;0;1_";
}

test "an extended key sends its scan code without the prefix and sets the enhanced flag" {
	const k: Win32Key = {
		action: KeyAction.Press, vk: 0x25, scancode: 0xE04B, char: 0,
		mods: none.incl(KeyMod.Ctrl).incl(KeyMod.CtrlRight),
	};
	assert win32Input(k) == "\x1b[37;75;0;1;260;1_";
}

test "AltGr arrives as the left Ctrl with the right Alt, as Windows reports it" {
	const altGr = none.incl(KeyMod.Ctrl).incl(KeyMod.Alt).incl(KeyMod.AltRight);
	const k: Win32Key = { action: KeyAction.Press, vk: 0x51, scancode: 0x10, char: 0x40, mods: altGr };
	assert win32Input(k) == "\x1b[81;16;64;1;9;1_";
}

test "the lock keys are reported as on" {
	assert controlState(none.incl(KeyMod.NumLock).incl(KeyMod.CapsLock), 0x1E) == 0xA0;
}
