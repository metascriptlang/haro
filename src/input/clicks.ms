import { Unit } from "../select/select";

const REPEAT_MS: float64 = 500;
const MAX_CLICKS: int32 = 3;

export interface Clicks {
	count: int32;
	x: float64;
	y: float64;
	time: float64;
}

export function open(this typeof Clicks): Clicks {
	return { count: 0, x: 0, y: 0, time: 0 };
}

export function register(this c: Clicks, x: float64, y: float64, time: float64, reach: float64): int32 {
	const dx = x - c.x;
	const dy = y - c.y;
	const near = c.count > 0 && time - c.time <= REPEAT_MS && dx * dx + dy * dy <= reach * reach;
	c.count = near ? (c.count % MAX_CLICKS) + 1 : 1;
	c.x = x;
	c.y = y;
	c.time = time;
	return c.count;
}

export function unitOf(count: int32): Unit {
	return match (count) {
		2 => Unit.Word,
		3 => Unit.Line,
		_ => Unit.Cell,
	};
}

test "clicks in the same place within the interval count up to three, then start over" {
	const c = Clicks.open();
	assert c.register(10, 10, 0, 8) == 1;
	assert c.register(10, 10, 200, 8) == 2;
	assert c.register(11, 9, 400, 8) == 3;
	assert c.register(10, 10, 600, 8) == 1;
	assert c.register(10, 10, 700, 8) == 2;
}

test "a slow click starts a new count" {
	const c = Clicks.open();
	assert c.register(10, 10, 0, 8) == 1;
	assert c.register(10, 10, 501, 8) == 1;
	assert c.register(10, 10, 1001, 8) == 2;
}

test "a click farther than a cell from the last one starts a new count" {
	const c = Clicks.open();
	assert c.register(10, 10, 0, 8) == 1;
	assert c.register(10, 19, 100, 8) == 1;
	assert c.register(10, 40, 200, 8) == 1;
	assert c.register(10, 42, 300, 8) == 2;
}

test "the interval runs from the previous click, not from the first" {
	const c = Clicks.open();
	assert c.register(0, 0, 0, 8) == 1;
	assert c.register(0, 0, 450, 8) == 2;
	assert c.register(0, 0, 900, 8) == 3;
}

test "one click selects by cell, two by word, three by line" {
	assert unitOf(1) == Unit.Cell;
	assert unitOf(2) == Unit.Word;
	assert unitOf(3) == Unit.Line;
}
