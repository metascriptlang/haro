@include("./modes.h");
@compile("./modes.c");

import { Vt } from "../vt/vt";

extern function inputMouseModes(terminal: Ptr<void>): int32;

const MOUSE_TRACKING: int32 = 1;
const ALT_SCROLL: int32 = 2;

export enum ModesError {
	ReadFailed,
}

export struct MouseModes {
	tracking: boolean;
	altScroll: boolean;
}

export function mouseModes(this vt: Vt): Result<MouseModes, ModesError> {
	const bits = inputMouseModes(vt.terminal);
	if (bits < 0) { return Result.err(ModesError.ReadFailed); }
	return Result.ok({ tracking: (bits & MOUSE_TRACKING) != 0, altScroll: (bits & ALT_SCROLL) != 0 });
}

function modesAfter(bytes: string): Result<MouseModes, ModesError> {
	const created = Vt.create(10, 3);
	if (!created.ok) { return Result.err(ModesError.ReadFailed); }
	const vt = created.value;
	vt.writeText(bytes);
	const read = vt.mouseModes();
	vt.free();
	return read;
}

function on(bytes: string, tracking: boolean): boolean {
	const read = modesAfter(bytes);
	if (!read.ok) { return false; }
	return tracking ? read.value.tracking : read.value.altScroll;
}

test "a fresh terminal reports no mouse and has alternate scroll on" {
	assert modesAfter("").ok;
	assert !on("", true);
	assert on("", false);
}

test "every tracking mode counts as the app reporting the mouse" {
	assert on("\x1b[?9h", true);
	assert on("\x1b[?1000h", true);
	assert on("\x1b[?1002h", true);
	assert on("\x1b[?1003h", true);
	assert !on("\x1b[?1000h\x1b[?1000l", true);
}

test "an app that turns alternate scroll off is seen" {
	assert !on("\x1b[?1007l", false);
	assert on("\x1b[?1007l\x1b[?1007h", false);
}

test "a mouse format alone is not tracking" {
	assert !on("\x1b[?1006h", true);
}
