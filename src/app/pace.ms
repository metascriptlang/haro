export interface Pace {
	queued: boolean;
	wakes: int32;
	applies: int32;
}

export function start(this typeof Pace): Pace {
	return { queued: false, wakes: 0, applies: 0 };
}

export function asksFrame(this p: Pace): boolean {
	p.wakes += 1;
	if (p.queued) { return false; }
	p.queued = true;
	return true;
}

export function applied(this p: Pace): void {
	p.queued = false;
	p.applies += 1;
}

test "the first wake asks for a frame" {
	const p = Pace.start();
	assert p.asksFrame();
	p.applied();
	assert p.applies == 1;
}

test "wakes before the frame ride the frame already asked for" {
	const p = Pace.start();
	assert p.asksFrame();
	assert !p.asksFrame();
	assert !p.asksFrame();
	p.applied();
	assert p.wakes == 3;
	assert p.applies == 1;
}

test "a wake after the frame applied asks for the next one" {
	const p = Pace.start();
	assert p.asksFrame();
	p.applied();
	assert p.asksFrame();
}

test "a burst of a wake every millisecond applies once per frame and strands no output" {
	const p = Pace.start();
	let dirty = false;
	let frames = 0;
	for (let ms = 0; ms < 400; ms++) {
		if (ms < 200) {
			dirty = true;
			const _asked = p.asksFrame();
		}
		if (ms % 16 == 15 && p.queued) {
			p.applied();
			dirty = false;
			frames += 1;
		}
	}
	assert !dirty;
	assert p.applies == frames;
	assert frames <= 200 / 16 + 1;
}
