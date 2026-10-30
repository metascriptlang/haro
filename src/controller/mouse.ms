import { KeyMod } from "../keys/keys";
import { autoscrollOf, claimsMouse, opensLinks } from "../input/pointer";
import { linkUnder } from "../screen/linksGrid";
import { WheelRoute, route } from "../input/wheel";
import { openable, refusalText } from "../term/link";
import { MouseAction, MouseInput, Vt } from "../vt/vt";
import { MouseButton } from "./mouseButton";
import { Term, TermError, tapKey, vtFailed } from "./term";
import { Controls, Hit, holding, vtOf } from "./controls";
import { copySelection, pasteFrom } from "./clipboard";

function reportMouse(
	t: Term,
	action: MouseAction,
	button: MouseButton,
	h: Hit,
): Result<boolean, TermError> {
	const input: MouseInput = {
		action: action,
		button: button,
		mods: h.mods,
		x: (h.x * h.scale + h.cell.padLeft) as float32,
		y: (h.y * h.scale + h.cell.padTop) as float32,
	};
	return t.sendMouse(input, h.cell);
}

function openLink(this c: Controls, uri: string): void {
	const verdict = openable(uri);
	if (verdict.ok) {
		c.asks.opens.push(uri);
	} else {
		console.log(`haro: link refused, ${refusalText(verdict.error)}: ${uri}`);
	}
}

export enum PressPlan {
	Link,
	Report,
	Select,
	CopyOrPaste,
	Ignore,
}

export function planPress(
	button: MouseButton,
	mods: BitSet<KeyMod>,
	tracking: boolean,
	overLink: boolean,
): PressPlan {
	if (button == MouseButton.Left && opensLinks(mods) && overLink) { return PressPlan.Link; }
	if (claimsMouse(tracking, mods.has(KeyMod.Shift))) { return PressPlan.Report; }
	return match (button) {
		MouseButton.Left => PressPlan.Select,
		MouseButton.Right => PressPlan.CopyOrPaste,
		MouseButton.None | MouseButton.Middle |
		MouseButton.WheelUp | MouseButton.WheelDown => PressPlan.Ignore,
	};
}

export function pointerDown(
	this c: Controls,
	t: Term,
	button: MouseButton,
	h: Hit,
	time: float64,
): Result<boolean, TermError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	const modes = try vt.modes();
	let uri: string | null = null;
	if (button == MouseButton.Left && opensLinks(h.mods)) {
		const link = try vt.linkUnder(h.at.col, h.at.row);
		if (link !== null) { uri = link.uri; }
	}
	match (planPress(button, h.mods, modes.mouseTracking, uri !== null)) {
		PressPlan.Link => {
			if (uri !== null) { c.openLink(uri); }
			return Result.ok(true);
		},
		PressPlan.Report => {
			try c.pointer.clear(vt);
			c.button = button;
			return reportMouse(t, MouseAction.Press, button, h);
		},
		PressPlan.Select => {
			const reach = (h.cell.cellWidth as float64) / h.scale;
			try c.pointer.press(vt, h.at, h.x, h.y, time, reach);
			return Result.ok(true);
		},
		PressPlan.CopyOrPaste => {
			const copied = try c.copySelection(t);
			if (!copied) { c.pasteFrom(); }
			return Result.ok(copied);
		},
		PressPlan.Ignore => {
			return Result.ok(false);
		},
	}
}

export function pointerMove(
	this c: Controls,
	t: Term,
	h: Hit,
	pressed: boolean,
): Result<boolean, TermError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	const modes = try vt.modes();
	if (claimsMouse(modes.mouseTracking, h.mods.has(KeyMod.Shift))) {
		const left = c.pointer.showHover(null);
		if (!pressed) { c.button = MouseButton.None; }
		try reportMouse(t, MouseAction.Motion, c.button, h);
		return Result.ok(left);
	}
	if (!c.pointer.dragging) {
		c.autoscroll = 0;
		const over = opensLinks(h.mods) ? try vt.linkUnder(h.at.col, h.at.row) : null;
		return Result.ok(c.pointer.showHover(over));
	}
	if (!pressed) {
		c.endDrag();
		return Result.ok(false);
	}
	c.autoscroll = autoscrollOf(h.y * h.scale, h.cell.height);
	return Result.ok(try c.pointer.drag(vt, h.at));
}

export function pointerUp(
	this c: Controls,
	t: Term,
	button: MouseButton,
	h: Hit,
): Result<boolean, TermError> {
	const reported = c.button != MouseButton.None;
	c.endDrag();
	if (!reported || c.holding()) { return Result.ok(false); }
	c.button = MouseButton.None;
	return reportMouse(t, MouseAction.Release, button, h);
}

export function endDrag(this c: Controls): void {
	c.pointer.release();
	c.autoscroll = 0;
}

export function autoscrollTick(this c: Controls, t: Term): Result<boolean, TermError> {
	const vt = t.vtOf();
	if (vt === null || !c.pointer.dragging || c.autoscroll == 0) {
		c.autoscroll = 0;
		return Result.ok(false);
	}
	vt.scrollLines(c.autoscroll);
	try c.pointer.drag(vt, c.pointer.last);
	return Result.ok(true);
}

export function roll(
	this c: Controls,
	t: Term,
	notches: float64,
	h: Hit,
): Result<boolean, TermError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = t.vtOf();
	if (vt === null) { return Result.ok(false); }
	const alt = try vt.alternateScreen();
	const modes = try vt.modes();
	const rows = c.wheel.rows(notches);
	if (rows == 0) { return Result.ok(false); }
	const shift = h.mods.has(KeyMod.Shift);
	const claimed = claimsMouse(modes.mouseTracking, shift);
	const where = route(alt, claimed, modes.altScroll && !shift);
	const presses = rows < 0 ? -rows : rows;
	match (where) {
		WheelRoute.Report => {
			const shown = c.pointer.selected();
			try c.pointer.clear(vt);
			const button = rows < 0 ? MouseButton.WheelUp : MouseButton.WheelDown;
			for (let i = 0; i < presses; i++) {
				try reportMouse(t, MouseAction.Press, button, h);
			}
			return Result.ok(shown);
		},
		WheelRoute.Arrows => {
			const shown = c.pointer.selected();
			try c.pointer.clear(vt);
			const code = rows < 0 ? "ArrowUp" : "ArrowDown";
			for (let i = 0; i < presses; i++) {
				try t.tapKey(code);
			}
			return Result.ok(shown);
		},
		WheelRoute.Viewport => {
			vt.scrollLines(rows);
			if (c.pointer.dragging) {
				try c.pointer.drag(vt, c.pointer.last);
			}
			return Result.ok(true);
		},
	}
}

export function syncSelection(this c: Controls, vt: Vt): Result<boolean, TermError> {
	const shown = c.pointer.selected();
	const kept = try c.pointer.sync(vt);
	return Result.ok(shown && !kept);
}
