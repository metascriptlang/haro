export const FRAME_MS: float64 = 16;

export enum Cue {
	Hold,
	Now,
	Later,
}

export interface Pace {
	gap: float64;
	last: float64;
	waiting: boolean;
	wakes: int32;
	applies: int32;
}

export function start(this typeof Pace, gap: float64): Pace {
	return { gap: gap, last: -gap, waiting: false, wakes: 0, applies: 0 };
}

export function wake(this p: Pace, now: float64): Cue {
	p.wakes += 1;
	if (p.waiting) { return Cue.Hold; }
	if (now - p.last >= p.gap) { return Cue.Now; }
	p.waiting = true;
	return Cue.Later;
}

export function wait(this p: Pace, now: float64): float64 {
	const left = p.last + p.gap - now;
	return left > 0 ? left : 0;
}

export function applied(this p: Pace, now: float64): void {
	p.last = now;
	p.waiting = false;
	p.applies += 1;
}

test "the first wake applies at once" {
	const p = Pace.start(16);
	assert p.wake(0) == Cue.Now;
	p.applied(0);
	assert p.applies == 1;
}

test "a wake inside the gap waits for what is left of it, and later wakes ride that wait" {
	const p = Pace.start(16);
	assert p.wake(100) == Cue.Now;
	p.applied(100);
	assert p.wake(104) == Cue.Later;
	assert p.wait(104) == 12;
	assert p.wake(110) == Cue.Hold;
	assert p.wake(115) == Cue.Hold;
	p.applied(116);
	assert !p.waiting;
	assert p.wakes == 4;
}

test "a wake after a quiet gap applies at once again" {
	const p = Pace.start(16);
	p.applied(100);
	assert p.wake(116) == Cue.Now;
	assert p.wake(200) == Cue.Now;
}

test "a timer that fires late still leaves a full gap before the next apply" {
	const p = Pace.start(16);
	p.applied(0);
	assert p.wake(1) == Cue.Later;
	p.applied(31);
	assert p.wake(32) == Cue.Later;
	assert p.wait(32) == 15;
}

test "a burst of a wake every millisecond applies once per gap and strands no output" {
	const p = Pace.start(16);
	let dirty = false;
	let due = -1;
	let applies = 0;
	for (let ms = 0; ms < 400; ms++) {
		if (ms < 200) {
			dirty = true;
			const cue = p.wake(ms);
			if (cue == Cue.Now) {
				p.applied(ms);
				dirty = false;
				applies += 1;
			}
			if (cue == Cue.Later) { due = ms + (p.wait(ms) as int32); }
		}
		if (p.waiting && ms == due) {
			p.applied(ms);
			dirty = false;
			applies += 1;
		}
	}
	assert !dirty;
	assert applies == p.applies;
	assert applies <= 200 / 16 + 2;
	assert applies >= 200 / 16;
}
