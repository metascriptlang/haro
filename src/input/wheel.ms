export enum WheelRoute {
	Viewport,
	Arrows,
	Report,
}

export const ROWS_PER_NOTCH: float64 = 3;

export interface Wheel {
	pending: float64;
}

export function open(this typeof Wheel): Wheel {
	return { pending: 0 };
}

export function route(altScreen: boolean, tracking: boolean, altScroll: boolean): WheelRoute {
	if (tracking) { return WheelRoute.Report; }
	if (altScreen && altScroll) { return WheelRoute.Arrows; }
	return WheelRoute.Viewport;
}

export function rows(this w: Wheel, notches: float64): int32 {
	const total = w.pending - notches * ROWS_PER_NOTCH;
	const whole = total < 0 ? Math.ceil(total) : Math.floor(total);
	w.pending = total - whole;
	return whole as int32;
}

export function reportButton(up: boolean): int32 {
	return up ? 4 : 5;
}

test "an app that reports the mouse gets the wheel, whatever the screen" {
	assert route(false, true, true) == WheelRoute.Report;
	assert route(true, true, true) == WheelRoute.Report;
	assert route(true, true, false) == WheelRoute.Report;
}

test "the alternate screen turns the wheel into arrow keys only while alternate scroll is on" {
	assert route(true, false, true) == WheelRoute.Arrows;
	assert route(true, false, false) == WheelRoute.Viewport;
}

test "the primary screen scrolls the viewport" {
	assert route(false, false, true) == WheelRoute.Viewport;
	assert route(false, false, false) == WheelRoute.Viewport;
}

test "a notch away from the user scrolls the viewport up three rows" {
	const w = Wheel.open();
	assert w.rows(1) == -3;
	assert w.rows(-1) == 3;
	assert w.rows(2) == -6;
}

test "fractional notches accumulate until they make a whole row" {
	const w = Wheel.open();
	assert w.rows(0.25) == 0;
	assert w.rows(0.25) == -1;
	assert w.rows(0.25) == -1;
	assert w.rows(0.25) == -1;
	assert w.pending == 0;
}

test "scrolling the other way spends what is pending before moving" {
	const w = Wheel.open();
	assert w.rows(0.5) == -1;
	assert w.rows(-0.5) == 1;
	assert w.pending > -0.0001 && w.pending < 0.0001;
}

test "the wheel reports as buttons four and five" {
	assert reportButton(true) == 4;
	assert reportButton(false) == 5;
}
