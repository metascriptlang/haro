import { readFile } from "std/fs";
import { LineRun } from "../grid/lines";
import { Rgb, Underline } from "../vt/vt";
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

function loadFixture(name: string): Result<Fixture, string> {
	const size = try fixtureFile(name, "size.txt");
	const text = try fixtureFile(name, "rows.txt");
	const attrs = try fixtureFile(name, "attrs.txt");
	const input = try fixtureFile(name, "in.bin");
	const colsRows = size.trim().split(" ");
	return Result.ok({
		cols: colsRows[0].parseInt() as int32,
		rows: colsRows[1].parseInt() as int32,
		text: text.split("\n"),
		attrs: attrs.split("\n"),
		input: input,
	});
}

function colorOf(token: string, fallback: Rgb, own: boolean): Rgb {
	return match (token[0]) {
		"d" => fallback,
		"i" => indexed(token.slice(1).parseInt() as int32, own),
		_ => fromCssHex(token),
	};
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
		a.bold == b.bold && a.italic == b.italic && a.strikethrough == b.strikethrough;
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

function expectedRuns(line: string, own: boolean): Vec<LineRun> {
	let runs: Vec<LineRun> = [];
	if (line == "") { return runs; }
	for (const item of line.split(" ")) {
		const parts = item.split(":");
		const flags = parts[3];
		const inverse = flags.includes("V");
		const fg = colorOf(parts[1], DEFAULT_FG, own);
		const bg = colorOf(parts[2], DEFAULT_BG, own);
		runs.push({
			units: parts[0].parseInt() as int32,
			fg: inverse ? bg : fg,
			bg: inverse ? fg : bg,
			underline: underlineOf(flags),
			underlineColor: null,
			bold: flags.includes("B"),
			italic: flags.includes("I"),
			strikethrough: flags.includes("S"),
		});
	}
	return merged(runs);
}

function withoutTrailingEmpty(runs: Vec<LineRun>, textUnits: int32): Vec<LineRun> {
	let out = runs;
	let total = 0;
	for (const run of out) { total += run.units; }
	while (total > textUnits && out.length > 0) {
		const last = out[out.length - 1];
		const styled = last.bg != DEFAULT_BG || last.underline != Underline.None ||
			last.strikethrough;
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
	const f = try loadFixture(name);
	const opened = Screen.open(f.cols, f.rows);
	if (!opened.ok) { return Result.err("open failed"); }
	const s = opened.value;
	defer s.close();
	const own = compare == Compare.RunsOwnPalette;
	if (!s.feed(palettePrelude(own)).ok) { return Result.err("prelude frame failed"); }
	if (!s.feedChunks(f.input, chunk).ok) { return Result.err("frame failed"); }
	if (!s.sameAsFreshRead()) {
		return Result.err("grid differs from a fresh read of the screen");
	}
	for (let y = 0; y < f.rows; y++) {
		if (s.text(y) != f.text[y]) {
			return Result.err(`row ${y}: expected "${f.text[y]}" got "${s.text(y)}"`);
		}
		if (compare == Compare.Text || (skipRunsRow !== null && y == skipRunsRow)) { continue; }
		const want = runsText(withoutTrailingEmpty(
			expectedRuns(f.attrs[y], own),
			f.text[y].length as int32,
		));
		const got = runsText(merged(s.runs(y)));
		if (got != want) { return Result.err(`row ${y} runs: expected ${want}got ${got}`); }
	}
	return Result.ok(null);
}

function conforms(name: string, chunk: int32, compare: Compare, skipRunsRow: int32 | null): string {
	const checked = firstFailure(name, chunk, compare, skipRunsRow);
	if (checked.ok) { return ""; }
	console.log(`${name} (chunk ${chunk}): ${checked.error}`);
	return checked.error;
}

function conformsFramed(
	name: string,
	smallChunk: int32,
	compare: Compare,
	skipRunsRow: int32 | null = null,
): string {
	let failures = "";
	for (const chunk of [0, 61, smallChunk]) {
		failures += conforms(name, chunk, compare, skipRunsRow);
	}
	return failures;
}

test "alacritty alt_reset: whole, in 61-byte and in 7-byte frames" {
	assert conformsFramed("alt_reset", 7, Compare.RunsOwnPalette) == "";
}

test "alacritty clear_underline: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("clear_underline", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty colored_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("colored_reset", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty colored_underline: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("colored_underline", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty csi_rep: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("csi_rep", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty delete_chars_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("delete_chars_reset", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty delete_lines: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("delete_lines", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty erase_chars_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("erase_chars_reset", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty fish_cc: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("fish_cc", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty grid_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("grid_reset", 1, Compare.RunsDefaultPalette) == "";
}

test "alacritty history: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("history", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty hyperlinks: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("hyperlinks", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty indexed_256_colors: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("indexed_256_colors", 1, Compare.RunsDefaultPalette) == "";
}

test "alacritty insert_blank_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("insert_blank_reset", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty issue_855: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("issue_855", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty ll: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("ll", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty newline_with_cursor_beyond_scroll_region: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed(
		"newline_with_cursor_beyond_scroll_region",
		1,
		Compare.RunsOwnPalette,
	) == "";
}

test "alacritty origin_goto: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("origin_goto", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty region_scroll_down: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("region_scroll_down", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty row_reset: whole, in 61-byte and in 7-byte frames" {
	assert conformsFramed("row_reset", 7, Compare.RunsOwnPalette) == "";
}

test "alacritty scroll_in_region_up_preserves_history: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed(
		"scroll_in_region_up_preserves_history",
		1,
		Compare.RunsOwnPalette,
	) == "";
}

test "alacritty scroll_up_reset: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("scroll_up_reset", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty sgr: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("sgr", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty tab_rendering: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("tab_rendering", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty tmux_git_log: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("tmux_git_log", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty tmux_htop: whole, in 61-byte and in 7-byte frames" {
	assert conformsFramed("tmux_htop", 7, Compare.RunsOwnPalette) == "";
}

test "alacritty underline: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("underline", 1, Compare.RunsOwnPalette, 7) == "";
}

test "alacritty vim_24bitcolors_bce: whole, in 61-byte and in 509-byte frames" {
	assert conformsFramed("vim_24bitcolors_bce", 509, Compare.RunsOwnPalette) == "";
}

test "alacritty vim_large_window_scroll: whole, in 61-byte and in 509-byte frames" {
	assert conformsFramed("vim_large_window_scroll", 509, Compare.RunsOwnPalette) == "";
}

test "alacritty vim_simple_edit: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("vim_simple_edit", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty vttest_origin_mode_1: whole, in 61-byte and in 7-byte frames" {
	assert conformsFramed("vttest_origin_mode_1", 7, Compare.Text) == "";
}

test "alacritty vttest_origin_mode_2: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("vttest_origin_mode_2", 1, Compare.Text) == "";
}

test "alacritty vttest_scroll: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("vttest_scroll", 1, Compare.Text) == "";
}

test "alacritty vttest_tab_clear_set: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("vttest_tab_clear_set", 1, Compare.Text) == "";
}

test "alacritty wrapline_alt_toggle: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("wrapline_alt_toggle", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty zerowidth: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("zerowidth", 1, Compare.RunsOwnPalette) == "";
}

test "alacritty zsh_tab_completion: whole, in 61-byte and in 1-byte frames" {
	assert conformsFramed("zsh_tab_completion", 1, Compare.RunsOwnPalette) == "";
}
