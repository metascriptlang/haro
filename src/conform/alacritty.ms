import { readFile } from "std/fs";
import { LineRun } from "../grid/lines";
import { CellFlag, Rgb, Underline } from "../vt/vt";
import { DEFAULT_BG, DEFAULT_FG, fromCssHex, indexed, palettePrelude } from "./palette";
import { Screen, runsText } from "./screen";

const ROOT = "fixtures/conform/alacritty/";

enum Compare {
	Text,
	RunsOwnPalette,
	RunsDefaultPalette,
}

struct Fixture {
	cols: int32;
	rows: int32;
	text: string[];
	attrs: string[];
	input: string;
}

function fixtureFile(name: string, file: string): Result<string, string> {
	const read = readFile(ROOT + name + "/" + file);
	if (!read.ok) { return Result.err(`missing ${name}/${file}`); }
	return Result.ok(read.value);
}

function loadFixture(name: string, compare: Compare): Result<Fixture, string> {
	const size = try fixtureFile(name, "size.txt");
	const text = try fixtureFile(name, "rows.txt");
	const input = try fixtureFile(name, "in.bin");
	let attrs: string[] = [];
	if (compare != Compare.Text) {
		const read = try fixtureFile(name, "attrs.txt");
		attrs = read.split("\n");
	}
	const colsRows = size.trim().split(" ");
	return Result.ok({
		cols: colsRows[0].parseInt() as int32,
		rows: colsRows[1].parseInt() as int32,
		text: text.split("\n"),
		attrs: attrs,
		input: input,
	});
}

function colorOf(token: string, fallback: Rgb, own: boolean): Result<Rgb, string> {
	if (token == "d") { return Result.ok(fallback); }
	if (token[0] == "i") {
		const n = token.slice(1).parseInt();
		if (!(n >= 0 && n <= 255)) { return Result.err(`palette index ${token} is not 0 to 255`); }
		return Result.ok(indexed(n as uint8, own));
	}
	return fromCssHex(token);
}

function underlineOf(flags: string): Underline {
	if (flags.includes("u")) { return Underline.Single; }
	if (flags.includes("U")) { return Underline.Double; }
	if (flags.includes("c")) { return Underline.Curly; }
	if (flags.includes("o")) { return Underline.Dotted; }
	if (flags.includes("a")) { return Underline.Dashed; }
	return Underline.None;
}

function sameLook(a: LineRun, b: LineRun): boolean {
	return a.fg == b.fg && a.bg == b.bg && a.underline == b.underline &&
		a.flags == b.flags;
}

function flagsOf(flags: string): BitSet<CellFlag> {
	let out = 0 as BitSet<CellFlag>;
	if (flags.includes("B")) { out = out.incl(CellFlag.Bold); }
	if (flags.includes("I")) { out = out.incl(CellFlag.Italic); }
	if (flags.includes("S")) { out = out.incl(CellFlag.Strikethrough); }
	return out;
}

function merged(runs: Vec<LineRun>): Vec<LineRun> {
	let out: Vec<LineRun> = [];
	for (const run of runs) {
		const last = out.length as int32;
		if (last > 0 && sameLook(out[last - 1], run)) {
			out[last - 1].units += run.units;
		} else {
			out.push({ ...run, underlineColor: null });
		}
	}
	return out;
}

function expectedRuns(line: string, own: boolean): Result<Vec<LineRun>, string> {
	let runs: Vec<LineRun> = [];
	if (line == "") { return Result.ok(runs); }
	for (const item of line.split(" ")) {
		const parts = item.split(":");
		const flags = parts[3];
		const inverse = flags.includes("V");
		const fg = try colorOf(parts[1], DEFAULT_FG, own);
		const bg = try colorOf(parts[2], DEFAULT_BG, own);
		runs.push({
			units: parts[0].parseInt() as int32,
			fg: inverse ? bg : fg,
			bg: inverse ? fg : bg,
			underline: underlineOf(flags),
			underlineColor: null,
			flags: flagsOf(flags),
		});
	}
	return Result.ok(merged(runs));
}

function withoutTrailingEmpty(runs: Vec<LineRun>, textUnits: int32): Vec<LineRun> {
	let out = runs;
	let total = 0;
	for (const run of out) { total += run.units; }
	while (total > textUnits && out.length > 0) {
		const last = out[out.length - 1];
		const styled = last.bg != DEFAULT_BG || last.underline != Underline.None ||
			last.flags.has(CellFlag.Strikethrough);
		if (styled) { break; }
		const cut = Math.min(last.units, total - textUnits);
		total -= cut;
		if (cut < last.units) {
			out[out.length - 1].units -= cut;
			break;
		}
		out.pop();
	}
	return out;
}

function firstFailure(
	name: string,
	chunk: int32,
	compare: Compare,
	skipRunsRow: int32 | null,
): Result<void, string> {
	const fixture = try loadFixture(name, compare);
	const opened = Screen.open(fixture.cols, fixture.rows);
	if (!opened.ok) { return Result.err("open failed"); }
	const s = opened.value;
	defer s.close();
	const own = compare == Compare.RunsOwnPalette;
	if (!s.feed(palettePrelude(own)).ok) { return Result.err("prelude frame failed"); }
	if (!s.feedChunks(fixture.input, chunk).ok) { return Result.err("frame failed"); }
	if (!s.sameAsFreshRead()) {
		return Result.err("grid differs from a fresh read of the screen");
	}
	for (let y = 0; y < fixture.rows; y++) {
		if (s.text(y) != fixture.text[y]) {
			return Result.err(`row ${y}: expected "${fixture.text[y]}" got "${s.text(y)}"`);
		}
		if (compare == Compare.Text || (skipRunsRow !== null && y == skipRunsRow)) { continue; }
		const expected = try expectedRuns(fixture.attrs[y], own);
		const want = runsText(withoutTrailingEmpty(expected, fixture.text[y].length as int32));
		const got = runsText(merged(s.runs(y)));
		if (got != want) { return Result.err(`row ${y} runs: expected ${want}got ${got}`); }
	}
	return Result.ok(null);
}

function conformsFramed(
	name: string,
	smallChunk: int32,
	compare: Compare,
	skipRunsRow: int32 | null,
): string {
	let failures = "";
	for (const chunk of [0, 61, smallChunk]) {
		const checked = firstFailure(name, chunk, compare, skipRunsRow);
		if (!checked.ok) {
			console.log(`${name} (chunk ${chunk}): ${checked.error}`);
			failures += checked.error;
		}
	}
	return failures;
}

struct Case {
	name: string;
	chunk: int32;
	compare: Compare;
	skipRunsRow: int32 | null;
}

const SGR_21_AFTER_CURLY_ROW: int32 = 7;

const CASES: Case[] = [
	{ name: "alt_reset", chunk: 7, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "clear_underline", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "colored_reset", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "colored_underline", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "csi_rep", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "delete_chars_reset", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "delete_lines", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "erase_chars_reset", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "fish_cc", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "grid_reset", chunk: 1, compare: Compare.RunsDefaultPalette, skipRunsRow: null },
	{ name: "history", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "hyperlinks", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{
		name: "indexed_256_colors",
		chunk: 1,
		compare: Compare.RunsDefaultPalette,
		skipRunsRow: null,
	},
	{ name: "insert_blank_reset", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "issue_855", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "ll", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{
		name: "newline_with_cursor_beyond_scroll_region",
		chunk: 1,
		compare: Compare.RunsOwnPalette,
		skipRunsRow: null,
	},
	{ name: "origin_goto", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "region_scroll_down", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "row_reset", chunk: 7, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{
		name: "scroll_in_region_up_preserves_history",
		chunk: 1,
		compare: Compare.RunsOwnPalette,
		skipRunsRow: null,
	},
	{ name: "scroll_up_reset", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "sgr", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "tab_rendering", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "tmux_git_log", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "tmux_htop", chunk: 7, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{
		name: "underline",
		chunk: 1,
		compare: Compare.RunsOwnPalette,
		skipRunsRow: SGR_21_AFTER_CURLY_ROW,
	},
	{
		name: "vim_24bitcolors_bce",
		chunk: 509,
		compare: Compare.RunsOwnPalette,
		skipRunsRow: null,
	},
	{
		name: "vim_large_window_scroll",
		chunk: 509,
		compare: Compare.RunsOwnPalette,
		skipRunsRow: null,
	},
	{ name: "vim_simple_edit", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "vttest_origin_mode_1", chunk: 7, compare: Compare.Text, skipRunsRow: null },
	{ name: "vttest_origin_mode_2", chunk: 1, compare: Compare.Text, skipRunsRow: null },
	{ name: "vttest_scroll", chunk: 1, compare: Compare.Text, skipRunsRow: null },
	{ name: "vttest_tab_clear_set", chunk: 1, compare: Compare.Text, skipRunsRow: null },
	{ name: "wrapline_alt_toggle", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "zerowidth", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
	{ name: "zsh_tab_completion", chunk: 1, compare: Compare.RunsOwnPalette, skipRunsRow: null },
];

test "every alacritty fixture conforms: whole, in 61-byte and in its own small frames" {
	for (const c of CASES) {
		const failures = conformsFramed(c.name, c.chunk, c.compare, c.skipRunsRow);
		assert failures == "", `${c.name}: ${failures}`;
	}
}

test "underline row 7 ends double where the fixture records curly, after 4:3 then 21" {
	const fixture = loadFixture("underline", Compare.RunsOwnPalette);
	assert fixture.ok, "underline fixture";
	const opened = Screen.open(fixture.value.cols, fixture.value.rows);
	assert opened.ok, "open";
	const s = opened.value;
	defer s.close();
	assert s.feed(palettePrelude(true)).ok, "prelude";
	assert s.feedChunks(fixture.value.input, 0).ok, "feed";
	assert s.runs(SGR_21_AFTER_CURLY_ROW)[0].underline == Underline.Double;
}
