import { neonEvent } from "../../../../../../neon/src/render/event";
import { KeyMod } from "../../../../keys/keys";
import { Block } from "../../../../select/select";
import { autoscrollOf, claimsMouse } from "../../../../input/pointer";
import { WheelRoute, reportButton, route } from "../../../../input/wheel";
import { openable } from "../../../../term/link";
import { MouseAction, MouseInput } from "../../../../vt/vt";
import { Term, TermError } from "./term";
import { Bridge, ControlError, Controls, Hit, holding, vtOf } from "./controls";
import { copySelection, pasteFrom } from "./clipboard";

const LEFT: int32 = 1;
const RIGHT: int32 = 2;

function reportMouse(
	this c: Controls,
	t: Term,
	action: MouseAction,
	button: int32,
	h: Hit,
	anyPressed: boolean,
): Result<boolean, ControlError> {
	const input: MouseInput = {
		action: action,
		button: button,
		mods: h.mods,
		x: (h.x * h.scale) as float32,
		y: (h.y * h.scale) as float32,
	};
	const sent = t.sendMouse(input, h.cell, anyPressed);
	if (!sent.ok) {
		return Result.err(match (sent.error) {
			TermError.WriteFailed => ControlError.WriteFailed,
			_ => ControlError.MouseFailed,
		});
	}
	return Result.ok(sent.value > 0);
}

function openLink(host: Bridge, uri: string): void {
	if (openable(uri)) {
		host.open(uri);
	} else {
		console.log(`haro: link refused, only http and https open: ${uri}`);
	}
}

export function pointerDown(
	this c: Controls,
	t: Term,
	host: Bridge,
	button: int32,
	h: Hit,
	time: float64,
): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	if (button == LEFT && h.mods.has(KeyMod.Ctrl)) {
		const link = vt.linkAt(h.at.col, h.at.row);
		if (!link.ok) { return Result.err(ControlError.VtFailed); }
		const uri = link.value;
		if (uri !== null) {
			openLink(host, uri);
			return Result.ok(true);
		}
	}
	if (claimsMouse(modes.value.mouseTracking, h.mods.has(KeyMod.Shift))) {
		c.pointer.clear(vt);
		c.button = button;
		return c.reportMouse(t, MouseAction.Press, button, h, true);
	}
	if (button == LEFT) {
		const reach = (h.cell.cellWidth as float64) / h.scale;
		const pressed = c.pointer.press(vt, h.at, h.x, h.y, time, reach);
		if (!pressed.ok) { return Result.err(ControlError.VtFailed); }
		return Result.ok(true);
	}
	if (button == RIGHT) {
		const copied = try c.copySelection(t, host);
		if (!copied) { c.pasteFrom(t, host); }
		return Result.ok(copied);
	}
	return Result.ok(false);
}

export function pointerMove(
	this c: Controls,
	t: Term,
	h: Hit,
	pressed: boolean,
): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	if (claimsMouse(modes.value.mouseTracking, h.mods.has(KeyMod.Shift))) {
		if (!pressed) { c.button = 0; }
		const _reported = try c.reportMouse(t, MouseAction.Motion, c.button, h, c.button != 0);
		return Result.ok(false);
	}
	if (!c.pointer.dragging) {
		c.autoscroll = 0;
		return Result.ok(false);
	}
	if (!pressed) {
		c.pointer.release();
		c.autoscroll = 0;
		return Result.ok(false);
	}
	c.autoscroll = autoscrollOf(h.y * h.scale, h.cell.height);
	const dragged = c.pointer.drag(vt, h.at);
	if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(dragged.value);
}

export function pointerUp(
	this c: Controls,
	t: Term,
	button: int32,
	h: Hit,
): Result<boolean, ControlError> {
	const reported = c.button != 0;
	c.pointer.release();
	c.autoscroll = 0;
	if (!reported || c.holding()) { return Result.ok(false); }
	c.button = 0;
	return c.reportMouse(t, MouseAction.Release, button, h, false);
}

export function autoscrollTick(this c: Controls, t: Term): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null || !c.pointer.dragging || c.autoscroll == 0) {
		c.autoscroll = 0;
		return Result.ok(false);
	}
	vt.scrollLines(c.autoscroll);
	const dragged = c.pointer.drag(vt, c.pointer.last);
	if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(true);
}

export function roll(
	this c: Controls,
	t: Term,
	notches: float64,
	h: Hit,
): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	const modes = vt.modes();
	if (!alt.ok || !modes.ok) { return Result.err(ControlError.VtFailed); }
	const rows = c.wheel.rows(notches);
	if (rows == 0) { return Result.ok(false); }
	const shift = h.mods.has(KeyMod.Shift);
	const claimed = claimsMouse(modes.value.mouseTracking, shift);
	const where = route(alt.value, claimed, modes.value.altScroll && !shift);
	const presses = rows < 0 ? -rows : rows;
	match (where) {
		WheelRoute.Report => {
			const shown = c.pointer.selected();
			c.pointer.clear(vt);
			const button = reportButton(rows < 0);
			for (let i = 0; i < presses; i++) {
				const _reported = try c.reportMouse(t, MouseAction.Press, button, h, false);
			}
			return Result.ok(shown);
		},
		WheelRoute.Arrows => {
			const shown = c.pointer.selected();
			c.pointer.clear(vt);
			const key = neonEvent("keydown");
			key.code = rows < 0 ? "ArrowUp" : "ArrowDown";
			for (let i = 0; i < presses; i++) {
				if (!t.sendKey(key).ok) { return Result.err(ControlError.KeyFailed); }
			}
			return Result.ok(shown);
		},
		WheelRoute.Viewport => {
			vt.scrollLines(rows);
			if (c.pointer.dragging) {
				const dragged = c.pointer.drag(vt, c.pointer.last);
				if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
			}
			return Result.ok(true);
		},
	}
}

export function shades(this c: Controls, t: Term): Result<Vec<Block>, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok([]); }
	if (!c.pointer.sync(vt).ok) { return Result.err(ControlError.VtFailed); }
	const drawn = c.pointer.blocks(vt, t.rows, t.cols);
	if (!drawn.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(drawn.value);
}
