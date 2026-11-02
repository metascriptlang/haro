export enum Slot {
	Now,
	Tick,
	Taken,
}

export interface Pace {
	queued: boolean;
	settled: boolean;
	wakes: int64;
	applies: int64;
}

export function start(this typeof Pace): Pace {
	return { queued: false, settled: true, wakes: 0, applies: 0 };
}

export function asksFrame(this p: Pace): Slot {
	p.wakes += 1;
	if (p.queued) { return Slot.Taken; }
	p.queued = true;
	return p.settled ? Slot.Now : Slot.Tick;
}

export function applied(this p: Pace): void {
	p.queued = false;
	p.settled = false;
	p.applies += 1;
}

export function ticked(this p: Pace): boolean {
	if (p.queued) { return true; }
	p.settled = true;
	return false;
}

test "the first wake runs at once instead of waiting for the next tick" {
	const p = Pace.start();
	assert p.asksFrame() == Slot.Now;
	p.applied();
	assert p.applies == 1;
}

test "a wake after a run waits for the tick, and wakes before that tick ride it" {
	const p = Pace.start();
	assert p.asksFrame() == Slot.Now;
	p.applied();
	assert p.asksFrame() == Slot.Tick;
	assert p.asksFrame() == Slot.Taken;
	assert p.ticked();
	p.applied();
	assert p.wakes == 3;
	assert p.applies == 2;
}

test "a tick with nothing waiting lets the next wake run at once" {
	const p = Pace.start();
	assert p.asksFrame() == Slot.Now;
	p.applied();
	assert !p.ticked();
	assert p.asksFrame() == Slot.Now;
}

test "a burst of a wake every millisecond applies at most once per tick and strands no output" {
	const p = Pace.start();
	let dirty = false;
	let frames = 0;
	let booked = false;
	for (let ms = 0; ms < 400; ms++) {
		if (ms < 200) {
			dirty = true;
			if (p.asksFrame() == Slot.Now) {
				p.applied();
				dirty = false;
				frames += 1;
				booked = true;
			}
		}
		if (ms % 16 == 15 && booked) {
			booked = p.ticked();
			if (booked) {
				p.applied();
				dirty = false;
				frames += 1;
			}
		}
	}
	assert !dirty;
	assert p.applies == frames;
	assert frames <= 200 / 16 + 2;
}

test "wakes and applies count past the int32 range" {
	const p = Pace.start();
	p.wakes = 2147483647;
	p.applies = 2147483647;
	const _slot = p.asksFrame();
	p.applied();
	assert (p.wakes as int64) > 2147483647;
	assert (p.applies as int64) > 2147483647;
}
