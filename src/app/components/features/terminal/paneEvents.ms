import { NeonEvent } from "../../../../../../neon/src/render/event";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { Spot, spotAt } from "../../../../input/pointer";
import { KeyMod } from "../../../../keys/keys";
import { noteKey, stats } from "../../../stats";
import { focusCursor } from "../../content/cursor";
import { Hit, holding, typed } from "./controls";
import { cancel, confirm } from "./clipboard";
import { keyDown } from "./keyboard";
import { autoscrollTick, pointerDown, pointerMove, pointerUp, roll } from "./mouse";
import {
	PaneModel,
	bridge,
	failed,
	paintSelection,
	refresh,
	scheduleRefresh,
} from "./paneModel";
import { sendFocus, sendKey, sendText } from "./term";

const AUTOSCROLL_MS = 15;

export function focusChanged(this m: PaneModel, gained: boolean): void {
	m.cursor.focusCursor(gained);
	const sent = m.term.sendFocus(gained);
	if (!sent.ok) { m.failed("focus", sent.error.toString()); }
}

function afterInput(this m: PaneModel): void {
	stats.noteKey(performance.now());
	const moved = m.controls.typed(m.term);
	if (!moved.ok) {
		m.failed("typed", moved.error.toString());
		return;
	}
	if (moved.value) { m.scheduleRefresh(); }
}

export function keyed(this m: PaneModel, e: NeonEvent): void {
	const handled = m.controls.keyDown(m.term, e, m.bridge());
	if (!handled.ok) {
		m.failed("key", handled.error.toString());
		return;
	}
	if (handled.value) {
		m.scheduleRefresh();
		return;
	}
	const sent = m.term.sendKey(e);
	if (!sent.ok) {
		m.failed("key", sent.error.toString());
		return;
	}
	if (sent.value > 0) { m.afterInput(); }
}

export function keyReleased(this m: PaneModel, e: NeonEvent): void {
	if (m.controls.keyUp(e)) { return; }
	const sent = m.term.sendKey(e);
	if (!sent.ok) { m.failed("key", sent.error.toString()); }
}

export function committed(this m: PaneModel, e: NeonEvent): void {
	m.preedit.setText("");
	if (m.controls.holding()) { return; }
	const sent = m.term.sendText(e.text);
	if (!sent.ok) {
		m.failed("text", sent.error.toString());
		return;
	}
	if (sent.value > 0) { m.afterInput(); }
}

function spot(this m: PaneModel, e: NeonEvent): Spot {
	const cellWidth = m.metrics.cellWidth();
	const rowHeight = m.metrics.rowHeight();
	return spotAt(e.locationX, e.locationY, cellWidth, rowHeight, m.term.cols, m.term.rows);
}

function hit(this m: PaneModel, e: NeonEvent): Hit {
	return {
		at: m.spot(e),
		x: e.locationX,
		y: e.locationY,
		scale: PixelRatio.get(),
		mods: (e.mods as uint16) as BitSet<KeyMod>,
		cell: m.mouseGeometry,
	};
}

export function pressed(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	const button = e.button as int32;
	const handled = m.controls.pointerDown(m.term, m.bridge(), button, m.hit(e), performance.now());
	if (!handled.ok) {
		m.failed("press", handled.error.toString());
		return;
	}
	m.paintSelection();
}

function autoscroll(this m: PaneModel): void {
	if (m.scrollTimer >= 0 || m.controls.autoscroll == 0) { return; }
	m.scrollTimer = setTimeout((): void => {
		m.scrollTimer = -1;
		const ticked = m.controls.autoscrollTick(m.term);
		if (!ticked.ok) {
			m.failed("autoscroll", ticked.error.toString());
			return;
		}
		if (!ticked.value) { return; }
		m.scheduleRefresh();
		m.autoscroll();
	}, AUTOSCROLL_MS);
}

export function dragged(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	const handled = m.controls.pointerMove(m.term, m.hit(e), e.pressed);
	if (!handled.ok) {
		m.failed("move", handled.error.toString());
		return;
	}
	if (handled.value) { m.paintSelection(); }
	m.autoscroll();
}

export function released(this m: PaneModel, e: NeonEvent): void {
	if (m.metrics.cellWidth() <= 0) { return; }
	const handled = m.controls.pointerUp(m.term, e.button as int32, m.hit(e));
	if (!handled.ok) { m.failed("release", handled.error.toString()); }
}

export function wheeled(this m: PaneModel, e: NeonEvent): void {
	const handled = m.controls.roll(m.term, e.deltaY, m.hit(e));
	if (!handled.ok) {
		m.failed("wheel", handled.error.toString());
		return;
	}
	if (handled.value) { m.scheduleRefresh(); }
}

export function confirmPaste(this m: PaneModel): void {
	const sent = m.controls.confirm(m.term);
	if (!sent.ok) { m.failed("paste", sent.error.toString()); }
	m.refresh();
}

export function cancelPaste(this m: PaneModel): void {
	const dropped = m.controls.cancel(m.term);
	if (!dropped.ok) { m.failed("clipboard", dropped.error.toString()); }
	m.refresh();
}
