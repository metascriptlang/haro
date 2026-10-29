import { Vec2, vec2 } from "../../../void/src/void2d/types";

export struct Cell {
	left: float32;
	top: float32;
	right: float32;
	bottom: float32;
}

function cut(this polygon: Vec2[], nx: float32, ny: float32, limit: float32): Vec2[] {
	let kept: Vec2[] = [];
	for (let i = 0; i < polygon.length; i++) {
		const a = polygon[i];
		const b = polygon[(i + 1) % polygon.length];
		const da = nx * a.x + ny * a.y - limit;
		const db = nx * b.x + ny * b.y - limit;
		if (da <= 0) { kept.push(a); }
		if ((da < 0 && db > 0) || (da > 0 && db < 0)) {
			const t = da / (da - db);
			kept.push(vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t));
		}
	}
	return kept;
}

function area(this polygon: Vec2[]): float32 {
	let twice: float32 = 0;
	for (let i = 0; i < polygon.length; i++) {
		const a = polygon[i];
		const b = polygon[(i + 1) % polygon.length];
		twice += a.x * b.y - b.x * a.y;
	}
	return Math.abs(twice / 2) as float32;
}

export function outside(this quad: Vec2[], cell: Cell): Vec2[][] {
	const across = quad.cut(-1, 0, -cell.left).cut(1, 0, cell.right);
	const pieces = [
		quad.cut(1, 0, cell.left),
		quad.cut(-1, 0, -cell.right),
		across.cut(0, 1, cell.top),
		across.cut(0, -1, -cell.bottom),
	];
	let shown: Vec2[][] = [];
	for (const piece of pieces) {
		if (piece.length >= 3 && piece.area() >= 0.5) { shown.push(piece); }
	}
	return shown;
}

function rectangle(left: float32, top: float32, right: float32, bottom: float32): Vec2[] {
	return [vec2(left, top), vec2(right, top), vec2(right, bottom), vec2(left, bottom)];
}

const LIT: Cell = { left: 0, top: 0, right: 10, bottom: 20 };

test "a quad that covers exactly the lit cell has nothing outside it" {
	assert rectangle(0, 0, 10, 20).outside(LIT).length == 0;
}

test "a quad that only touches the lit cell is shown whole" {
	const pieces = rectangle(10, 0, 20, 20).outside(LIT);
	assert pieces.length == 1;
	assert pieces[0].area() == 200;
}

test "a quad that overlaps the lit cell keeps only the part beyond it" {
	const pieces = rectangle(5, 0, 15, 20).outside(LIT);
	assert pieces.length == 1;
	for (const p of pieces[0]) {
		assert p.x >= 10;
	}
	assert pieces[0].area() == 100;
}
