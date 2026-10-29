import { frameCounts } from "../../../neon/src/platform/ion/window";
when (voidProfiler) {
	import { frameStats } from "../../../void/src/void2d/frameMarks";
	import { DurationRing, ringCount, ringPercentile } from "../../../void/src/void2d/profiler";
}
import { Pace } from "./pace";
import { Stats, launchLine, launched, line, reset } from "./stats";

const STATS_MS = 1000;

let launchShown = false;

function milliseconds(ns: int64): float64 {
	return Math.round((ns as float64) / 10000.0) / 100;
}

when (voidProfiler) {
	function percentiles(ring: DurationRing): string {
		const p50 = milliseconds(ring.ringPercentile(50));
		const p99 = milliseconds(ring.ringPercentile(99));
		return `p50=${p50} p99=${p99}`;
	}
}

function voidLine(): string {
	when (voidProfiler) {
		const draws = frameStats.draws;
		if (draws.ringCount() == 0) { return "void frames=0"; }
		const dirty = frameStats.dirtyToPresent;
		const d2p = dirty.ringCount() == 0 ? "" : ` d2p ${percentiles(dirty)}`;
		return `void frames=${frameStats.frames} draw ${percentiles(draws)}${d2p}`;
	} else {
		return "";
	}
}

function logSince(
	pace: Pace,
	stats: Stats,
	wakes: int32,
	applies: int32,
	requested: int64,
	drawn: int64,
): void {
	setTimeout((): void => {
		const counts = frameCounts();
		const nowRequested = counts[0] as int64;
		const nowDrawn = counts[1] as int64;
		console.log(
			`haro stats: ${stats.line()} wakes=${pace.wakes - wakes} ` +
			`applies=${pace.applies - applies} requested=${nowRequested - requested} ` +
			`drawn=${nowDrawn - drawn} ${voidLine()}`,
		);
		stats.reset();
		if (!launchShown && stats.launched()) {
			launchShown = true;
			console.log(`haro launch: ${stats.launchLine()}`);
		}
		logSince(pace, stats, pace.wakes, pace.applies, nowRequested, nowDrawn);
	}, STATS_MS);
}

export function logStatsEverySecond(pace: Pace, stats: Stats): void {
	stats.recording = true;
	logSince(pace, stats, 0, 0, 0, 0);
}
