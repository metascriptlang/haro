import { CursorShape } from "../vt/vt";

export const ANIMATION_LENGTH: float64 = 0.15;
export const SHORT_ANIMATION_LENGTH: float64 = 0.04;
export const TRAIL_SIZE: float64 = 1.0;
export const BAR_FRACTION: float64 = 1.0 / 8;
export const PARTICLE_OPACITY: float64 = 200.0 / 255;
export const PARTICLE_LIFETIME: float64 = 4.0;
export const PARTICLE_DENSITY: float64 = 7.0;
export const PARTICLE_SPEED: float64 = 10.0;
export const PARTICLE_CURL: float64 = 1.0;
export const PARTICLE_PUSH: float64 = 0.5;
export const PARTICLE_DRAG: float64 = 0.15;
const DRAG_TICK: float64 = 0.017;

const PCG_MULTIPLIER: uint64 = 6364136223846793005;
const PCG_STATE: uint64 = 9600629759793949339;
const PCG_INCREMENT: uint64 = 13005396917011789751;

export struct Point {
	x: float64;
	y: float64;
}

struct Spring {
	position: float64;
	velocity: float64;
}

const AT_REST: Spring = { position: 0, velocity: 0 };

interface Corner {
	standard: Point;
	relative: Point;
	current: Point;
	previous: Point;
	x: Spring;
	y: Spring;
	length: float64;
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

function length(this p: Point): float64 {
	return Math.hypot(p.x, p.y);
}

function normalized(this p: Point): Point {
	const l = p.length();
	return point(p.x / l, p.y / l);
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

function lerp(from: float64, to: float64, t: float64): float64 {
	return from + (to - from) * t;
}

function settle(this s: Spring, dt: float64, span: float64): Spring {
	if (span <= dt) { return AT_REST; }
	if (s.position == 0) { return s; }
	const omega = 4 / span;
	const a = s.position;
	const b = s.position * omega + s.velocity;
	const c = Math.exp(-omega * dt);
	const position = (a + b * dt) * c;
	if (Math.abs(position) < 0.01) { return AT_REST; }
	return { position: position, velocity: c * (-a * omega - b * dt * omega + b) };
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
		current: point(0, 0),
		previous: point(-1000, -1000),
		x: AT_REST,
		y: AT_REST,
		length: 0,
	};
}

function target(this c: Corner, center: Point, w: float64, h: float64): Point {
	return point(center.x + c.relative.x * w, center.y + c.relative.y * h);
}

function alignment(this c: Corner, center: Point, w: float64, h: float64): float64 {
	const to = c.target(center, w, h);
	const travel = point(to.x - c.previous.x, to.y - c.previous.y).normalized();
	const facing = c.relative.normalized();
	return travel.x * facing.x + travel.y * facing.y;
}

function jump(this c: Corner, center: Point, w: float64, h: float64, aligned: float64): void {
	const to = c.target(center, w, h);
	const jx = (to.x - c.previous.x) / w;
	const jy = (to.y - c.previous.y) / h;
	if (Math.abs(jx) <= 2.001 && Math.abs(jy) <= 0.001) {
		c.length = Math.min(ANIMATION_LENGTH, SHORT_ANIMATION_LENGTH);
		return;
	}
	const leading = ANIMATION_LENGTH * Math.min(1, Math.max(0, 1 - TRAIL_SIZE));
	c.length = lerp(ANIMATION_LENGTH, leading, aligned);
}

function follow(this c: Corner, center: Point, w: float64, h: float64, dt: float64, immediate: boolean): boolean {
	const to = c.target(center, w, h);
	if (to != c.previous) {
		c.x = { position: to.x - c.current.x, velocity: c.x.velocity };
		c.y = { position: to.y - c.current.y, velocity: c.y.velocity };
		c.previous = to;
	}
	if (immediate) {
		c.x = AT_REST;
		c.y = AT_REST;
		c.current = to;
		return false;
	}
	c.x = c.x.settle(dt, c.length);
	c.y = c.y.settle(dt, c.length);
	c.current = point(to.x - c.x.position, to.y - c.y.position);
	return c.x.position != 0 || c.y.position != 0;
}

export function start(this typeof Trail): Trail {
	return {
		corners: [corner(-0.5, -0.5), corner(0.5, -0.5), corner(0.5, 0.5), corner(-0.5, 0.5)],
		particles: [],
		destination: point(0, 0),
		jumped: false,
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

function velocity(this c: Corner): Point {
	return point(-c.x.velocity, -c.y.velocity);
}

function flow(this t: Trail): Point {
	let points: Point[] = [];
	for (const c of t.corners) {
		points.push(c.velocity());
	}
	return points.middle();
}

function spray(this t: Trail, h: float64, dt: float64, immediate: boolean): boolean {
	const drag = Math.exp(Math.log(1 - PARTICLE_DRAG) * (dt / DRAG_TICK));
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
	const center = t.currents().middle();
	if (center == t.spawnedFrom) { return t.particles.length > 0; }
	if (!immediate) {
		const from = t.spawnedFrom;
		const travel = center.minus(from);
		const wanted = (travel.length() / h) * PARTICLE_DENSITY + t.remainder;
		const count = Math.floor(wanted) as int32;
		t.remainder = wanted - (count as float64);
		const push = t.flow().times(PARTICLE_PUSH);
		for (let n = 0; n < count; n++) {
			const share = ((n + 1) as float64) / (count as float64);
			const base = t.direction();
			const along = t.unit();
			const spin = t.unit();
			t.particles.push({
				pos: from.plus(travel.times(along)).plus(point(0, h * 0.5)),
				speed: point(base.x * 0.5 * 3 * PARTICLE_SPEED, (0.4 + Math.abs(base.y)) * 3 * PARTICLE_SPEED),
				push: push,
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
	const center = point(t.destination.x + w * 0.5, t.destination.y + h * 0.5);
	let animating = false;
	if (center.x != 0 || center.y != 0) {
		if (t.jumped) {
			const aligned: float64[] = [];
			let lo = Infinity;
			let hi = -Infinity;
			for (const c of t.corners) {
				const a = c.alignment(center, w, h);
				aligned.push(a);
				if (a < lo) { lo = a; }
				if (a > hi) { hi = a; }
			}
			for (let i = 0; i < t.corners.length; i++) {
				const a = (aligned[i] - lo) / (hi - lo);
				t.corners[i].jump(center, w, h, Number.isFinite(a) ? Math.min(1, Math.max(0, a)) : 1);
			}
		}
		for (const c of t.corners) {
			if (c.follow(center, w, h, dt, immediate)) { animating = true; }
		}
		if (t.spray(h, dt, immediate)) { animating = true; }
	}
	t.jumped = false;
	return animating;
}

export function resting(this t: Trail): boolean {
	for (const c of t.corners) {
		if (c.x.position != 0 || c.y.position != 0) { return false; }
	}
	return true;
}

export function shownCorners(this t: Trail): Point[] {
	const fx = t.destination.x - Math.trunc(t.destination.x);
	const fy = t.destination.y - Math.trunc(t.destination.y);
	let shown: Point[] = [];
	for (const c of t.currents()) {
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

function near(a: float64, b: float64): boolean {
	return Math.abs(a - b) < 0.001;
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

test "the generator gives the reference PCG sequence from its fixed seed" {
	const t = Trail.start();
	assert t.next() == 355248013;
	assert t.next() == 3457946844;
	assert t.next() == 2661944520;
}

test "a critically damped spring closes on its target without overshooting and rests at zero" {
	let s: Spring = { position: 100, velocity: 0 };
	let steps = 0;
	while (s.position != 0) {
		s = s.settle(FRAME, ANIMATION_LENGTH);
		assert s.position >= 0;
		steps += 1;
	}
	assert s == AT_REST;
	assert steps < 60;
}

test "a spring whose animation is shorter than the frame snaps to its target" {
	const wound: Spring = { position: 100, velocity: 5 };
	assert wound.settle(FRAME, FRAME) == AT_REST;
}

test "the cursor rests with its corners on the cell it was moved to" {
	const t = placed(30, 40);
	const shown = t.shownCorners();
	assert shown[0] == point(30, 40);
	assert shown[2] == point(40, 60);
}

test "a move of up to two cells along a row uses the short animation for every corner" {
	const t = placed(30, 40);
	t.moveTo(50, 40);
	const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
	for (const c of t.corners) {
		assert near(c.length, SHORT_ANIMATION_LENGTH);
	}
}

test "on a long jump the leading corners land at once and the trailing ones stretch behind" {
	const t = placed(30, 40);
	t.moveTo(130, 40);
	assert t.animate(FRAME, CursorShape.Block, 10, 20, false);
	const shown = t.shownCorners();
	assert shown[1] == point(140, 40);
	assert shown[2] == point(140, 60);
	assert shown[0].x < 130;
	assert shown[3].x < 130;
	assert near(t.corners[0].length, ANIMATION_LENGTH);
	assert near(t.corners[1].length, 0);
}

test "a jump along the pixel diagonal moves its side corners at half the trailing pace" {
	const t = placed(30, 40);
	t.moveTo(130, 140);
	assert t.animate(FRAME, CursorShape.Block, 10, 20, false);
	assert near(t.corners[2].length, 0);
	assert near(t.corners[0].length, ANIMATION_LENGTH);
	assert near(t.corners[1].length, ANIMATION_LENGTH / 2);
	assert near(t.corners[3].length, ANIMATION_LENGTH / 2);
}

test "every jump keeps the cursor's shape convex until it rests" {
	for (const to of [point(130, 40), point(830, 40), point(130, 840), point(-270, -360), point(40, 40)]) {
		const t = placed(30, 40);
		t.moveTo(to.x, to.y);
		let frames = 0;
		while (!t.resting() || frames == 0) {
			const _moving = t.animate(FRAME, CursorShape.Block, 10, 20, false);
			assert t.shownCorners().convex();
			frames += 1;
		}
	}
}

test "sixty and a hundred and twenty frames a second trace the same motion" {
	const a = placed(30, 40);
	const b = placed(30, 40);
	a.moveTo(130, 240);
	b.moveTo(130, 240);
	for (let f = 0; f < 12; f++) {
		const _a = a.animate(FRAME, CursorShape.Block, 10, 20, false);
		const _b = b.animate(FRAME / 2, CursorShape.Block, 10, 20, false);
		const _c = b.animate(FRAME / 2, CursorShape.Block, 10, 20, false);
		const ca = a.currents();
		const cb = b.currents();
		for (let i = 0; i < 4; i++) {
			assert ca[i].minus(cb[i]).length() < 0.1;
		}
	}
}

test "a bar keeps its corners in the left eighth of the cell" {
	const t = placed(30, 40);
	const _moving = t.animate(FRAME, CursorShape.Bar, 10, 20, false);
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
	for (let f = 0; f < 4; f++) {
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

test "the corners rest on their cell before the dust of the move has faded" {
	const t = placed(30, 40);
	assert t.resting();
	t.moveTo(30, 240);
	assert t.animate(FRAME, CursorShape.Block, 10, 20, false);
	assert !t.resting();
	let frames = 0;
	while (!t.resting()) {
		assert t.animate(FRAME, CursorShape.Block, 10, 20, false);
		frames += 1;
	}
	assert frames < 60;
	assert t.particles.length > 0;
	for (const p of t.particles) {
		assert p.lifetime <= PARTICLE_LIFETIME;
		assert particleAlpha(p) <= PARTICLE_OPACITY;
	}
	const faded = t.settled(CursorShape.Block, 10, 20);
	assert t.particles.length == 0;
	assert faded <= ((PARTICLE_LIFETIME / FRAME) as int32) + 1;
}

test "an immediate move snaps every corner and sprays nothing" {
	const t = placed(30, 40);
	t.moveTo(130, 240);
	assert !t.animate(FRAME, CursorShape.Block, 10, 20, true);
	assert t.particles.length == 0;
	assert t.shownCorners()[0] == point(130, 240);
}
