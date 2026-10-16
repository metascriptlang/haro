export enum WheelRoute {
	Report,
	Arrows,
	Viewport,
}

export struct WheelState {
	alternate: boolean;
	mouseTracking: boolean;
	altScroll: boolean;
}

export struct WheelStep {
	lines: int32;
	pending: float64;
}

export const DISCRETE_ROWS_PER_NOTCH: float64 = 3.0;

export function routeOf(state: WheelState): WheelRoute {
	if (state.mouseTracking) { return WheelRoute.Report; }
	if (state.alternate && state.altScroll) { return WheelRoute.Arrows; }
	return WheelRoute.Viewport;
}

export function wheelStep(pending: float64, notches: float64, rowsPerNotch: float64): WheelStep {
	const total = pending + notches * rowsPerNotch;
	const whole = total as int32;
	return { lines: whole, pending: total - (whole as float64) };
}

export function arrowKey(up: boolean, cursorKeys: boolean): string {
	if (cursorKeys) { return up ? "\x1bOA" : "\x1bOB"; }
	return up ? "\x1b[A" : "\x1b[B";
}

export function reportButton(up: boolean): int32 {
	return up ? 4 : 5;
}

test "mouse tracking wins, then the alternate screen with alternate scroll, else the viewport" {
	assert routeOf({ alternate: true, mouseTracking: true, altScroll: true }) == WheelRoute.Report;
	assert routeOf({ alternate: false, mouseTracking: true, altScroll: true }) == WheelRoute.Report;
	assert routeOf({ alternate: true, mouseTracking: false, altScroll: true }) == WheelRoute.Arrows;
	assert routeOf({ alternate: true, mouseTracking: false, altScroll: false }) == WheelRoute.Viewport;
	assert routeOf({ alternate: false, mouseTracking: false, altScroll: true }) == WheelRoute.Viewport;
}

test "one notch scrolls three rows" {
	const step = wheelStep(0.0, 1.0, DISCRETE_ROWS_PER_NOTCH);
	assert step.lines == 3;
	assert step.pending == 0.0;
	const down = wheelStep(0.0, -2.0, DISCRETE_ROWS_PER_NOTCH);
	assert down.lines == -6;
}

test "a fractional notch waits until it adds up to a row and keeps what is left over" {
	const first = wheelStep(0.0, 0.25, 3.0);
	assert first.lines == 0;
	assert first.pending == 0.75;
	const second = wheelStep(first.pending, 0.5, 3.0);
	assert second.lines == 2;
	assert second.pending == 0.25;
	const back = wheelStep(0.75, -0.25, 3.0);
	assert back.lines == 0;
	assert back.pending == 0.0;
}

test "the arrow keys follow the cursor key mode" {
	assert arrowKey(true, false) == "\x1b[A";
	assert arrowKey(false, false) == "\x1b[B";
	assert arrowKey(true, true) == "\x1bOA";
	assert arrowKey(false, true) == "\x1bOB";
}

test "the wheel reports as buttons four and five" {
	assert reportButton(true) == 4;
	assert reportButton(false) == 5;
}
