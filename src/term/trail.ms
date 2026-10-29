import { CursorShape } from "../vt/vt";

export const BAR_FRACTION: float64 = 1.0 / 8;
export const TICK: float64 = 0.017;
export const ANTICIPATION: float64 = 0.2;
export const MAX_WINDUP: float64 = 2;
export const STOP_DISTANCE: float64 = 0.1;
export const MAX_TICKS_PER_FRAME = 30;
export const MINIMUM_VOLUME_FACTOR: float64 = 0.7;
export const VOLUME_REDUCTION: float64 = 0.3;
export const PARTICLE_OPACITY: float64 = 200.0 / 255;
export const PARTICLE_LIFETIME: float64 = 4.0;
export const PARTICLE_DENSITY: float64 = 7.0;
export const PARTICLE_SPEED: float64 = 10.0;
export const PARTICLE_CURL: float64 = 1.0;
export const PARTICLE_PUSH: float64 = 0.5;
export const PARTICLE_DRAG: float64 = 0.15;

const PCG_MULTIPLIER: uint64 = 6364136223846793005;
const PCG_STATE: uint64 = 9600629759793949339;
const PCG_INCREMENT: uint64 = 13005396917011789751;

export struct Point {
	x: float64;
	y: float64;
}

export struct Feel {
	stiffness: float64;
	trailingStiffness: float64;
	trailingExponent: float64;
	damping: float64;
	maxLength: float64;
}

export const JUMP: Feel = { stiffness: 0.3, trailingStiffness: 0.1, trailingExponent: 5, damping: 0.5, maxLength: 25 };
export const TYPING: Feel = { stiffness: 0.5, trailingStiffness: 0.5, trailingExponent: 1, damping: 0.9, maxLength: 1 };

interface Corner {
	standard: Point;
	relative: Point;
	previous: Point;
	current: Point;
	velocity: Point;
	target: Point;
	stiffness: float64;
}

export struct Particle {
	pos: Point;
	speed: Point;
	push: Point;
	rotation: float64;
	lifetime: float64;
}

export interface Trail {
	corners: Corner[];
	particles: Particle[];
	destination: Point;
	jumped: boolean;
	landed: boolean;
	feel: Feel;
	cell: Point;
	lag: float64;
	shape: Point;
	spawnedFrom: Point;
	remainder: float64;
	rng: uint64;
}

function point(x: float64, y: float64): Point {
	return { x: x, y: y };
}

function plus(this a: Point, b: Point): Point {
	return point(a.x + b.x, a.y + b.y);
}

function minus(this a: Point, b: Point): Point {
	return point(a.x - b.x, a.y - b.y);
}

function times(this p: Point, by: float64): Point {
	return point(p.x * by, p.y * by);
}

function dot(this a: Point, b: Point): float64 {
	return a.x * b.x + a.y * b.y;
}

function inCells(this p: Point, cell: Point): Point {
	return point(p.x / cell.x, p.y / cell.y);
}

function inPixels(this p: Point, cell: Point): Point {
	return point(p.x * cell.x, p.y * cell.y);
}

function length(this p: Point): float64 {
	return Math.hypot(p.x, p.y);
}

function normalized(this p: Point): Point {
	const l = p.length();
	return l == 0 ? point(0, 0) : point(p.x / l, p.y / l);
}

function rotated(this p: Point, by: float64): Point {
	const sin = Math.sin(by);
	const cos = Math.cos(by);
	return point(p.x * cos - p.y * sin, p.x * sin + p.y * cos);
}

function middle(this points: Point[]): Point {
	let sum = point(0, 0);
	for (const p of points) {
		sum = sum.plus(p);
	}
	return sum.times(1.0 / points.length);
}

function area(this points: Point[]): float64 {
	let twice = 0.0;
	for (let i = 0; i < points.length; i++) {
		const a = points[i];
		const b = points[(i + 1) % points.length];
		twice += a.x * b.y - b.x * a.y;
	}
	return twice / 2;
}

function relativeFor(this standard: Point, shape: CursorShape): Point {
	return match (shape) {
		CursorShape.Bar => point((standard.x + 0.5) * BAR_FRACTION - 0.5, standard.y),
		CursorShape.Underline => point(standard.x, -((-standard.y + 0.5) * BAR_FRACTION - 0.5)),
		_ => standard,
	};
}

function corner(x: float64, y: float64): Corner {
	return {
		standard: point(x, y),
		relative: point(x, y),
		previous: point(0, 0),
		current: point(0, 0),
		velocity: point(0, 0),
		target: point(0, 0),
		stiffness: 0,
	};
}

export function start(this typeof Trail): Trail {
	return {
		corners: [corner(-0.5, -0.5), corner(0.5, -0.5), corner(0.5, 0.5), corner(-0.5, 0.5)],
		particles: [],
		destination: point(0, 0),
		jumped: false,
		landed: false,
		feel: JUMP,
		cell: point(1, 1),
		lag: 0,
		shape: point(0, 0),
		spawnedFrom: point(0, 0),
		remainder: 0,
		rng: PCG_STATE,
	};
}

function next(this t: Trail): uint32 {
	const old = t.rng;
	t.rng = old * PCG_MULTIPLIER + PCG_INCREMENT;
	const shifted = (((old >> 18) ^ old) >> 27) as uint32;
	const rot = (old >> 59) as uint32;
	return (shifted >> rot) | (shifted << ((0 - rot) & 31));
}

function unit(this t: Trail): float64 {
	return (t.next() as float64) / 4294967296;
}

function direction(this t: Trail): Point {
	const x = t.unit();
	const y = t.unit();
	return point(x * 2 - 1, y * 2 - 1).normalized();
}

export function moveTo(this t: Trail, x: float64, y: float64): void {
	t.jumped = t.jumped || Math.abs(x - t.destination.x) > 0.01 || Math.abs(y - t.destination.y) > 0.01;
	t.destination = point(x, y);
}

function reshape(this t: Trail, shape: CursorShape): boolean {
	const probe = point(0.5, -0.5).relativeFor(shape);
	if (probe == t.shape) { return false; }
	t.shape = probe;
	for (const c of t.corners) {
		c.relative = c.standard.relativeFor(shape);
	}
	return true;
}

function currents(this t: Trail): Point[] {
	let points: Point[] = [];
	for (const c of t.corners) {
		points.push(c.current);
	}
	return points;
}

function drawn(this t: Trail): Point[] {
	const between = t.lag / TICK;
	let points: Point[] = [];
	for (const c of t.corners) {
		points.push(c.previous.plus(c.current.minus(c.previous).times(between)));
	}
	return points;
}

function targets(this t: Trail): Point[] {
	let points: Point[] = [];
	for (const c of t.corners) {
		points.push(c.target);
	}
	return points;
}

function velocities(this t: Trail): Point[] {
	let points: Point[] = [];
	for (const c of t.corners) {
		points.push(c.velocity);
	}
	return points;
}

function targetOf(this c: Corner, center: Point, cell: Point): Point {
	return center.plus(c.relative.inPixels(cell));
}

function retargeted(this t: Trail, center: Point): boolean {
	for (const c of t.corners) {
		if (c.targetOf(center, t.cell) != c.target) { return true; }
	}
	return false;
}

function place(this t: Trail, center: Point): void {
	for (const c of t.corners) {
		c.target = c.targetOf(center, t.cell);
		c.previous = c.target;
		c.current = c.target;
		c.velocity = point(0, 0);
	}
	t.lag = 0;
}

function aim(this t: Trail, center: Point): void {
	const settled = t.resting();
	const lead = t.corners[0];
	const jump = lead.targetOf(center, t.cell).minus(lead.target).inCells(t.cell);
	t.feel = Math.abs(jump.x) <= 2.001 && Math.abs(jump.y) <= 0.001 ? TYPING : JUMP;
	let distances: float64[] = [];
	let lo = Infinity;
	let hi = -Infinity;
	for (const c of t.corners) {
		c.target = c.targetOf(center, t.cell);
		const d = c.current.minus(center).inCells(t.cell).length();
		distances.push(d);
		if (d < lo) { lo = d; }
		if (d > hi) { hi = d; }
	}
	const feel = t.feel;
	for (let i = 0; i < t.corners.length; i++) {
		const c = t.corners[i];
		const x = hi == lo ? 0 : (distances[i] - lo) / (hi - lo);
		const s = feel.stiffness + (feel.trailingStiffness - feel.stiffness) * Math.pow(x, feel.trailingExponent);
		c.stiffness = Math.min(1, s);
		if (settled) { c.velocity = t.windup(c); }
	}
}

function windup(this t: Trail, c: Corner): Point {
	const back = c.current.minus(c.target).times(ANTICIPATION).inCells(t.cell);
	const cells = back.length();
	const capped = cells > MAX_WINDUP ? back.times(MAX_WINDUP / cells) : back;
	return capped.inPixels(t.cell);
}

function restLength(this t: Trail): float64 {
	let longest = 0.0;
	for (const a of t.corners) {
		for (const b of t.corners) {
			longest = Math.max(longest, a.relative.minus(b.relative).length());
		}
	}
	return longest;
}

function stretchTo(this t: Trail, limit: float64): void {
	let head = 0;
	let nearest = Infinity;
	for (let i = 0; i < t.corners.length; i++) {
		const d = t.corners[i].target.minus(t.corners[i].current).inCells(t.cell).length();
		if (d < nearest) {
			nearest = d;
			head = i;
		}
	}
	const from = t.corners[head].current;
	const axis = t.targets().middle().minus(t.currents().middle()).inCells(t.cell).normalized();
	let longest = 0.0;
	for (const c of t.corners) {
		longest = Math.max(longest, Math.abs(c.current.minus(from).inCells(t.cell).dot(axis)));
	}
	if (longest <= limit) { return; }
	const factor = limit / longest;
	for (let i = 0; i < t.corners.length; i++) {
		if (i == head) { continue; }
		const c = t.corners[i];
		const span = c.current.minus(from).inCells(t.cell);
		const along = span.dot(axis);
		const across = span.minus(axis.times(along));
		c.current = from.plus(axis.times(along * factor).plus(across).inPixels(t.cell));
	}
}

function tick(this t: Trail): boolean {
	const feel = t.feel;
	const keep = 1 - feel.damping;
	const correction = 1 / (1 + 2.5 * keep);
	for (const c of t.corners) {
		c.previous = c.current;
		c.velocity = c.velocity.plus(c.target.minus(c.current).times(c.stiffness * correction));
		c.current = c.current.plus(c.velocity);
		c.velocity = c.velocity.times(keep);
	}
	t.stretchTo(Math.max(feel.maxLength, t.restLength()));
	let far = 0.0;
	let fast = 0.0;
	for (const c of t.corners) {
		far = Math.max(far, c.target.minus(c.current).inCells(t.cell).length());
		fast = Math.max(fast, c.velocity.inCells(t.cell).length());
	}
	if (far > STOP_DISTANCE || fast > STOP_DISTANCE) { return true; }
	for (const c of t.corners) {
		c.previous = c.target;
		c.current = c.target;
		c.velocity = point(0, 0);
	}
	t.lag = 0;
	return false;
}

function pull(this t: Trail, dt: float64): boolean {
	if (t.resting()) { return false; }
	t.lag += dt;
	let ticks = 0;
	while (t.lag >= TICK) {
		if (ticks == MAX_TICKS_PER_FRAME) {
			t.lag = 0;
			break;
		}
		t.lag -= TICK;
		ticks += 1;
		if (!t.tick()) { return false; }
	}
	return true;
}

function spray(this t: Trail, dt: float64, immediate: boolean): boolean {
	const drag = Math.exp(Math.log(1 - PARTICLE_DRAG) * (dt / TICK));
	let i = 0;
	while (i < t.particles.length) {
		const p = t.particles[i];
		if (p.lifetime - dt <= 0) {
			t.particles[i] = t.particles[t.particles.length - 1];
			const _dead = t.particles.pop();
			continue;
		}
		t.particles[i] = {
			pos: p.pos.plus(p.speed.plus(p.push).times(dt)),
			speed: p.speed.rotated(dt * p.rotation),
			push: p.push.times(drag),
			rotation: p.rotation,
			lifetime: p.lifetime - dt,
		};
		i += 1;
	}
	const center = t.drawn().middle();
	if (center == t.spawnedFrom) { return t.particles.length > 0; }
	if (!immediate) {
		const from = t.spawnedFrom;
		const travel = center.minus(from);
		const wanted = (travel.length() / t.cell.y) * PARTICLE_DENSITY + t.remainder;
		const count = Math.floor(wanted) as int32;
		t.remainder = wanted - (count as float64);
		const flow = t.velocities().middle().times(PARTICLE_PUSH / TICK);
		for (let n = 0; n < count; n++) {
			const share = ((n + 1) as float64) / (count as float64);
			const base = t.direction();
			const along = t.unit();
			const spin = t.unit();
			t.particles.push({
				pos: from.plus(travel.times(along)).plus(point(0, t.cell.y * 0.5)),
				speed: point(base.x * 0.5 * 3 * PARTICLE_SPEED, (0.4 + Math.abs(base.y)) * 3 * PARTICLE_SPEED),
				push: flow,
				rotation: (spin - 0.5) * (Math.PI / 2) * PARTICLE_CURL,
				lifetime: share * PARTICLE_LIFETIME,
			});
		}
	}
	t.spawnedFrom = center;
	return t.particles.length > 0;
}

export function animate(this t: Trail, dt: float64, shape: CursorShape, w: float64, h: float64, immediate: boolean): boolean {
	if (t.reshape(shape)) { t.remainder = 0; }
	if (!t.landed && !t.jumped) { return false; }
	t.jumped = false;
	t.cell = point(w, h);
	const center = point(t.destination.x + w * 0.5, t.destination.y + h * 0.5);
	const snap = immediate || !t.landed;
	t.landed = true;
	if (snap) {
		t.place(center);
	} else if (t.retargeted(center)) {
		t.aim(center);
	}
	const moving = t.pull(dt);
	const dusty = t.spray(dt, snap);
	return moving || dusty;
}

export function resting(this t: Trail): boolean {
	for (const c of t.corners) {
		if (c.previous != c.target || c.current != c.target || c.velocity.x != 0 || c.velocity.y != 0) {
			return false;
		}
	}
	return true;
}

function thinned(this t: Trail, points: Point[]): Point[] {
	const cell = t.cell;
	const here = points.middle().inCells(cell);
	const there = t.targets().middle().inCells(cell);
	if (Math.abs(there.x - here.x) < 1.0 / 8 || Math.abs(there.y - here.y) < 1.0 / 8) { return points; }
	let rest: Point[] = [];
	let cells: Point[] = [];
	for (let i = 0; i < points.length; i++) {
		rest.push(t.corners[i].relative);
		cells.push(points[i].inCells(cell));
	}
	const volume = cells.area() / rest.area();
	if (volume <= 0) { return points; }
	const factor = Math.max(MINIMUM_VOLUME_FACTOR, Math.pow(1 / volume, VOLUME_REDUCTION / 2));
	let shrunk: Point[] = [];
	for (let i = 0; i < cells.length; i++) {
		const toTarget = t.corners[i].target.inCells(cell).minus(cells[i]);
		const normal = point(-toTarget.y, toTarget.x).normalized();
		const shift = cells[i].minus(here).dot(normal) * (1 - factor);
		shrunk.push(cells[i].minus(normal.times(shift)).inPixels(cell));
	}
	return shrunk;
}

export function shownCorners(this t: Trail): Point[] {
	const fx = t.destination.x - Math.trunc(t.destination.x);
	const fy = t.destination.y - Math.trunc(t.destination.y);
	let shown: Point[] = [];
	for (const c of t.thinned(t.drawn())) {
		shown.push(point(Math.round(c.x - fx) + fx, Math.round(c.y - fy) + fy));
	}
	return shown;
}

export function particleAlpha(this p: Particle): float64 {
	return (p.lifetime / PARTICLE_LIFETIME) * PARTICLE_OPACITY;
}

const FRAME: float64 = 1.0 / 60;

function settled(this t: Trail, shape: CursorShape, w: float64, h: float64): int32 {
	let frames = 0;
	while (t.animate(FRAME, shape, w, h, false)) { frames += 1; }
	return frames;
}

function placed(x: float64, y: float64): Trail {
	const t = Trail.start();
	t.moveTo(x, y);
	const _frames = t.settled(CursorShape.Block, 10, 20);
	return t;
}

function framesToRest(this t: Trail): int32 {
	let frames = 0;
	while (!t.resting() || frames == 0) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
		frames += 1;
	}
	return frames;
}

function near(a: float64, b: float64): boolean {
	return Math.abs(a - b) < 0.001;
}

test "the generator gives the reference PCG sequence from its fixed seed" {
	const t = Trail.start();
	assert t.next() == 355248013;
	assert t.next() == 3457946844;
	assert t.next() == 2661944520;
}

test "the first place the cursor is moved to is taken at once, with no trail and no dust" {
	const t = Trail.start();
	t.moveTo(130, 240);
	assert !t.animate(FRAME, CursorShape.Block, 10, 20, false);
	assert t.resting();
	assert t.shownCorners()[0] == point(130, 240);
	assert t.particles.length == 0;
}

test "the cursor rests with its corners on the cell it was moved to" {
	const t = placed(30, 40);
	const shown = t.shownCorners();
	assert shown[0] == point(30, 40);
	assert shown[2] == point(40, 60);
}

test "a jump from rest winds up away from its target before it travels" {
	const t = placed(30, 40);
	t.moveTo(130, 40);
	const _first = t.animate(FRAME, CursorShape.Block, 10, 20, false);
	const _second = t.animate(FRAME, CursorShape.Block, 10, 20, false);
	const d = t.drawn();
	assert d[0].x < 30;
	assert d[1].x < 40;
}

test "a long jump overshoots its cell, comes back and rests on it" {
	const t = placed(30, 40);
	t.moveTo(130, 40);
	let farthest = 0.0;
	let frames = 0;
	while (!t.resting() || frames == 0) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
		farthest = Math.max(farthest, t.drawn()[1].x);
		frames += 1;
	}
	assert farthest > 140;
	assert frames < 60;
	assert t.shownCorners()[1] == point(140, 40);
}

test "on a long jump the corners nearest the target pull hardest and the far ones trail behind" {
	const t = placed(30, 40);
	t.moveTo(130, 40);
	for (let f = 0; f < 8; f++) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
	}
	assert t.feel == JUMP;
	assert t.corners[1].stiffness > t.corners[0].stiffness;
	assert near(t.corners[1].stiffness, JUMP.stiffness);
	const d = t.drawn();
	assert d[1].x - d[0].x > 3 * 10;
}

test "a move of up to two cells along a row slides the cursor at its own size" {
	const t = placed(30, 40);
	t.moveTo(50, 40);
	let widest = 0.0;
	let frames = 0;
	while (!t.resting() || frames == 0) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
		const d = t.drawn();
		widest = Math.max(widest, d[2].minus(d[0]).inCells(t.cell).length());
		frames += 1;
	}
	assert t.feel == TYPING;
	assert widest <= Math.SQRT2 + 0.000001;
	assert t.shownCorners()[0] == point(50, 40);
}

test "sixty and a hundred and twenty frames a second trace the same motion" {
	const a = placed(30, 40);
	const b = Trail.start();
	b.moveTo(30, 40);
	const _placed = b.animate(FRAME / 2, CursorShape.Block, 10, 20, false);
	a.moveTo(130, 240);
	b.moveTo(130, 240);
	for (let f = 0; f < 60; f++) {
		const _a = a.animate(FRAME, CursorShape.Block, 10, 20, false);
		const _b = b.animate(FRAME / 2, CursorShape.Block, 10, 20, false);
		const _c = b.animate(FRAME / 2, CursorShape.Block, 10, 20, false);
		const da = a.drawn();
		const db = b.drawn();
		for (let i = 0; i < 4; i++) {
			assert da[i].minus(db[i]).length() < 0.000001;
		}
	}
}

test "a diagonal smear thins across its motion, by at most the minimum volume factor" {
	const t = placed(30, 40);
	t.moveTo(130, 240);
	let thinnest = 1.0;
	for (let f = 0; f < 30; f++) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
		const raw = t.drawn().area();
		if (raw > 0) { thinnest = Math.min(thinnest, t.thinned(t.drawn()).area() / raw); }
	}
	assert thinnest < 0.9;
	assert thinnest >= MINIMUM_VOLUME_FACTOR - 0.000001;
}

test "a bar keeps its corners in the left eighth of the cell" {
	const t = placed(30, 40);
	const _frames = t.settled(CursorShape.Bar, 10, 20);
	assert near(t.corners[1].current.x, 31.25);
	assert near(t.corners[2].current.y, 60);
}

function pushed(this t: Trail): Point {
	let sum = point(0, 0);
	for (const p of t.particles) {
		sum = sum.plus(p.push);
	}
	return sum;
}

test "dust leaves from under the row the cursor travels, falls, and is pushed the way it moves" {
	const right = placed(30, 40);
	right.moveTo(130, 40);
	const left = placed(130, 40);
	left.moveTo(30, 40);
	for (let f = 0; f < 8; f++) {
		const _r = right.animate(FRAME, CursorShape.Block, 10, 20, false);
		const _l = left.animate(FRAME, CursorShape.Block, 10, 20, false);
	}
	assert right.particles.length > 0 && left.particles.length > 0;
	assert right.pushed().x > 0;
	assert left.pushed().x < 0;
	for (const p of right.particles) {
		assert p.pos.y >= 60;
		assert p.speed.y > 0;
	}
}

test "dust fades out within its lifetime once the cursor rests" {
	const t = placed(30, 40);
	t.moveTo(30, 240);
	assert t.framesToRest() < 60;
	assert t.particles.length > 0;
	for (const p of t.particles) {
		assert p.lifetime <= PARTICLE_LIFETIME;
		assert particleAlpha(p) <= PARTICLE_OPACITY;
	}
	const frames = t.settled(CursorShape.Block, 10, 20);
	assert t.particles.length == 0;
	assert frames <= ((PARTICLE_LIFETIME / FRAME) as int32) + 1;
}

test "an immediate move snaps every corner and sprays nothing" {
	const t = placed(30, 40);
	t.moveTo(130, 240);
	assert !t.animate(FRAME, CursorShape.Block, 10, 20, true);
	assert t.particles.length == 0;
	assert t.shownCorners()[0] == point(130, 240);
}

function convex(this q: Point[]): boolean {
	let sign = 0.0;
	for (let i = 0; i < q.length; i++) {
		const a = q[i];
		const b = q[(i + 1) % q.length];
		const c = q[(i + 2) % q.length];
		const turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
		if (turn == 0) { continue; }
		if (sign != 0 && (turn > 0) != (sign > 0)) { return false; }
		sign = turn;
	}
	return true;
}

test "a jump past the longest smear stays convex and keeps its row's height while it stretches" {
	for (const to of [point(830, 40), point(130, 840), point(-270, -360)]) {
		const t = placed(30, 40);
		t.moveTo(to.x, to.y);
		let frames = 0;
		while (!t.resting() || frames == 0) {
			const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
			assert t.shownCorners().convex();
			frames += 1;
		}
	}
	const t = placed(30, 40);
	t.moveTo(830, 40);
	let frames = 0;
	while (!t.resting() || frames == 0) {
		const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
		const d = t.shownCorners();
		assert near(d[3].y - d[0].y, 20) && near(d[2].y - d[1].y, 20);
		frames += 1;
	}
}

test "a far jump winds up no farther than a near one would" {
	const near10 = placed(30, 40);
	near10.moveTo(130, 40);
	const far80 = placed(30, 40);
	far80.moveTo(830, 40);
	let nearBack = 0.0;
	let farBack = 0.0;
	for (let f = 0; f < 10; f++) {
		const _n = near10.animate(FRAME, CursorShape.Block, 10, 20, false);
		const _f = far80.animate(FRAME, CursorShape.Block, 10, 20, false);
		nearBack = Math.max(nearBack, 30 - near10.drawn()[0].x);
		farBack = Math.max(farBack, 30 - far80.drawn()[0].x);
	}
	assert nearBack > 0;
	assert farBack <= nearBack * 1.5;
}

