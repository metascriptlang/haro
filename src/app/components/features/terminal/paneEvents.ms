import { DOM_DELTA_PIXEL, NeonEvent } from "../../../../../../neon/src/render/event";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { Spot, spotAt } from "../../../../input/pointer";
import { notchesOf } from "../../../../input/wheel";
import { KeyAction, KeyEvent, modifierKey, modsOf } from "../../../../keys/keys";
import { focusCursor } from "../../content/cursor";
import { buttonOf } from "../../../../controller/mouseButton";
import { Hit } from "../../../../controller/controls";
import { PaneModel, hookPane, notify, refresh, scheduleRefresh } from "./paneModel";

export function keyOf(e: NeonEvent): KeyEvent {
	return {
		action: e.type == "keyup" ? KeyAction.Release : e.repeat ? KeyAction.Repeat : KeyAction.Press,
		key: e.code,
		mods: modsOf(e.mods),
		consumedMods: modsOf(e.consumedMods),
		unshifted: e.unshifted as uint32,
		text: e.text,
	};
}

export function focusChanged(this m: PaneModel, gained: boolean): void {
	m.cursor.focusCursor(gained);
	m.io.focus(gained);
	m.scheduleRefresh();
}

export function keyed(this m: PaneModel, e: NeonEvent): void {
	const ended = m.ended;
	if (ended !== null) {
		if (!modifierKey(e.code)) { m.desktop.exited(ended.code); }
		return;
	}
	const k = keyOf(e);
	const answer = m.keyHook.answer(m.hookPane(), k);
	if (!answer.ok) {
		m.notify(answer.error);
	} else if (answer.value.handled) {
		if (answer.value.send != "") { m.io.text(answer.value.send, m.timing.clock()); }
		m.scheduleRefresh();
		return;
	}
	m.io.key(k, m.timing.clock());
	m.scheduleRefresh();
}

export function keyReleased(this m: PaneModel, e: NeonEvent): void {
	m.io.keyReleased(keyOf(e));
	m.scheduleRefresh();
}

export function committed(this m: PaneModel, e: NeonEvent): void {
	m.preedit.setText("");
	m.io.text(e.text, m.timing.clock());
	m.scheduleRefresh();
}

function gridX(this m: PaneModel, e: NeonEvent): float64 {
	return e.locationX - m.padding();
}

function gridY(this m: PaneModel, e: NeonEvent): float64 {
	return e.locationY - m.padding();
}

function spot(this m: PaneModel, e: NeonEvent): Spot {
	const cellWidth = m.metrics.cellWidth();
	const rowHeight = m.metrics.rowHeight();
	return spotAt(m.gridX(e), m.gridY(e), cellWidth, rowHeight, m.cols, m.rows);
}

function hit(this m: PaneModel, e: NeonEvent): Hit {
	return {
		at: m.spot(e),
		x: m.gridX(e),
		y: m.gridY(e),
		scale: PixelRatio.get(),
		mods: modsOf(e.mods),
		cell: m.mouseGeometry,
	};
}

export function pressed(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	m.io.press(buttonOf(e.button), m.hit(e), m.timing.clock());
	m.scheduleRefresh();
}

export function dragged(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	m.io.move(m.hit(e), e.pressed);
	m.scheduleRefresh();
}

export function released(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	m.io.release(buttonOf(e.button), m.hit(e));
	m.scheduleRefresh();
}

export function wheeled(this m: PaneModel, e: NeonEvent): void {
	const rowHeight = m.metrics.rowHeight();
	if (rowHeight <= 0) { return; }
	m.io.wheel(notchesOf(e.deltaY, e.deltaMode == DOM_DELTA_PIXEL, rowHeight), m.hit(e));
	m.scheduleRefresh();
}

export function confirmDialog(this m: PaneModel): void {
	m.io.confirmDialog();
	m.refresh();
}

export function cancelDialog(this m: PaneModel): void {
	m.io.cancelDialog();
	m.refresh();
}
