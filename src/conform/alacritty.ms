import { readFile } from "std/fs";
import { LineRun } from "../grid/lines";
import { Rgb, Underline } from "../vt/vt";
import { DEFAULT_BG, DEFAULT_FG, HEX, defaultIndexed, ownIndexed, palettePrelude } from "./palette";
import { Screen } from "./screen";

const ROOT = "fixtures/conform/alacritty/";

enum Compare {
	Text,
	RunsOwnPalette,
	RunsDefaultPalette,
}

function hexValue(text: string, at: int32): int32 {
	let v = 0;
	for (let i = at; i < at + 2; i++) {
		const d = HEX.indexOf(text[i]);
		v = v * 16 + d;
	}
	return v;
}

function colorOf(token: string, fallback: Rgb, own: boolean): Rgb {
	if (token == "d") { return fallback; }
	if (token[0] == "i") {
		const n = token.slice(1).parseInt() as int32;
		return own ? ownIndexed(n) : defaultIndexed(n);
	}
	return { r: hexValue(token, 1) as uint8, g: hexValue(token, 3) as uint8, b: hexValue(token, 5) as uint8 };
}

function underlineOf(flags: string): Underline {
	if (flags.includes("u")) { return Underline.Single; }
	if (flags.includes("U")) { return Underline.Double; }
	if (flags.includes("c")) { return Underline.Curly; }
	if (flags.includes("o")) { return Underline.Dotted; }
	if (flags.includes("a")) { return Underline.Dashed; }
	return Underline.None;
}

function sameRun(a: LineRun, b: LineRun): boolean {
	return a.fg == b.fg && a.bg == b.bg && a.underline == b.underline &&
		a.bold == b.bold && a.italic == b.italic && a.strikethrough == b.strikethrough;
}

function expectedRuns(line: string, own: boolean): Vec<LineRun> {
	let out: Vec<LineRun> = [];
	if (line == "") { return out; }
	for (const item of line.split(" ")) {
		const parts = item.split(":");
		const flags = parts[3];
		const inverse = flags.includes("V");
		const fg = colorOf(parts[1], DEFAULT_FG, own);
		const bg = colorOf(parts[2], DEFAULT_BG, own);
		const run: LineRun = {
			units: parts[0].parseInt() as int32,
			fg: inverse ? bg : fg,
			bg: inverse ? fg : bg,
			underline: underlineOf(flags),
			underlineColor: null,
			bold: flags.includes("B"),
			italic: flags.includes("I"),
			strikethrough: flags.includes("S"),
		};
		const last = out.length as int32;
		if (last > 0 && sameRun(out[last - 1], run)) {
			out[last - 1].units += run.units;
		} else {
			out.push(run);
		}
	}
	return out;
}

function withoutTrailingEmpty(runs: Vec<LineRun>, textUnits: int32): Vec<LineRun> {
	let out = runs;
	let total = 0;
	for (const run of out) { total += run.units; }
	while (total > textUnits && out.length > 0) {
		const last = out[out.length - 1];
		if (last.bg != DEFAULT_BG || last.underline != Underline.None || last.strikethrough) { break; }
		const cut = Math.min(last.units, total - textUnits) as int32;
		total -= cut;
		if (cut < last.units) {
			out[out.length - 1].units -= cut;
			break;
		}
		out.pop();
	}
	return out;
}

function recordedFields(runs: Vec<LineRun>): Vec<LineRun> {
	let out: Vec<LineRun> = [];
	for (const run of runs) {
		const last = out.length as int32;
		if (last > 0 && sameRun(out[last - 1], run)) {
			out[last - 1].units += run.units;
		} else {
			out.push({ ...run, underlineColor: null });
		}
	}
	return out;
}

function runsEqual(a: Vec<LineRun>, b: Vec<LineRun>): boolean {
	if (a.length != b.length) { return false; }
	for (let i = 0; i < (a.length as int32); i++) {
		if (a[i].units != b[i].units || !sameRun(a[i], b[i])) { return false; }
	}
	return true;
}

function showRun(r: LineRun): string {
	const fg = `${r.fg.r},${r.fg.g},${r.fg.b}`;
	const bg = `${r.bg.r},${r.bg.g},${r.bg.b}`;
	return `${r.units}[fg ${fg} bg ${bg} u${r.underline as int32} b${r.bold} i${r.italic} s${r.strikethrough}]`;
}

function showRuns(runs: Vec<LineRun>): string {
	let out = "";
	for (const r of runs) { out += " " + showRun(r); }
	return out;
}

function load(name: string, file: string): string {
	const r = readFile(ROOT + name + "/" + file);
	if (!r.ok) { return "<missing " + name + "/" + file + ">"; }
	return r.value;
}

function conforms(name: string, chunk: int32, compare: Compare, skipRunsRow: int32): string {
	const own = compare == Compare.RunsOwnPalette;
	const size = load(name, "size.txt").trim().split(" ");
	const cols = size[0].parseInt() as int32;
	const rows = size[1].parseInt() as int32;
	const expectText = load(name, "rows.txt").split("\n");
	const expectAttrs = load(name, "attrs.txt").split("\n");
	const input = load(name, "in.bin");
	const opened = Screen.open(cols, rows);
	if (!opened.ok) { return "open failed"; }
	const s = opened.value;
	let failure = "";
	if (!s.feed(palettePrelude(own))) { failure = "prelude frame failed"; }
	if (failure == "" && !s.feedChunks(input, chunk)) {
		failure = "frame failed";
	}
	if (failure == "" && !s.sameAsFreshRead()) { failure = "grid differs from a fresh read of the screen"; }
	for (let y = 0; y < rows && failure == ""; y++) {
		if (s.text(y) != expectText[y]) {
			failure = `row ${y}: expected "${expectText[y]}" got "${s.text(y)}"`;
		} else if (compare != Compare.Text && y != skipRunsRow) {
			const want = withoutTrailingEmpty(expectedRuns(expectAttrs[y], own), expectText[y].length as int32);
			const got = recordedFields(s.runs(y));
			if (!runsEqual(got, want)) {
				failure = `row ${y} runs: expected${showRuns(want)} got${showRuns(got)}`;
			}
		}
	}
	s.close();
	if (failure != "") { console.log(`${name} (chunk ${chunk}): ${failure}`); }
	return failure;
}

test "alacritty alt_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("alt_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("alt_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("alt_reset", 7, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty clear_underline: whole, in 61-byte frames, in small frames" {
	assert conforms("clear_underline", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("clear_underline", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("clear_underline", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty colored_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("colored_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_reset", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty colored_underline: whole, in 61-byte frames, in small frames" {
	assert conforms("colored_underline", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_underline", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_underline", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty csi_rep: whole, in 61-byte frames, in small frames" {
	assert conforms("csi_rep", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("csi_rep", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("csi_rep", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty delete_chars_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("delete_chars_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_chars_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_chars_reset", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty delete_lines: whole, in 61-byte frames, in small frames" {
	assert conforms("delete_lines", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_lines", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_lines", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty erase_chars_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("erase_chars_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("erase_chars_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("erase_chars_reset", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty fish_cc: whole, in 61-byte frames, in small frames" {
	assert conforms("fish_cc", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("fish_cc", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("fish_cc", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty grid_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("grid_reset", 0, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("grid_reset", 61, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("grid_reset", 1, Compare.RunsDefaultPalette, -1) == "";
}

test "alacritty history: whole, in 61-byte frames, in small frames" {
	assert conforms("history", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("history", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("history", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty hyperlinks: whole, in 61-byte frames, in small frames" {
	assert conforms("hyperlinks", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("hyperlinks", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("hyperlinks", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty indexed_256_colors: whole, in 61-byte frames, in small frames" {
	assert conforms("indexed_256_colors", 0, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("indexed_256_colors", 61, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("indexed_256_colors", 1, Compare.RunsDefaultPalette, -1) == "";
}

test "alacritty insert_blank_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("insert_blank_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("insert_blank_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("insert_blank_reset", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty issue_855: whole, in 61-byte frames, in small frames" {
	assert conforms("issue_855", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("issue_855", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("issue_855", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty ll: whole, in 61-byte frames, in small frames" {
	assert conforms("ll", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("ll", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("ll", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty newline_with_cursor_beyond_scroll_region: whole, in 61-byte frames, in small frames" {
	assert conforms("newline_with_cursor_beyond_scroll_region", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("newline_with_cursor_beyond_scroll_region", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("newline_with_cursor_beyond_scroll_region", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty origin_goto: whole, in 61-byte frames, in small frames" {
	assert conforms("origin_goto", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("origin_goto", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("origin_goto", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty region_scroll_down: whole, in 61-byte frames, in small frames" {
	assert conforms("region_scroll_down", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("region_scroll_down", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("region_scroll_down", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty row_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("row_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("row_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("row_reset", 7, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty scroll_in_region_up_preserves_history: whole, in 61-byte frames, in small frames" {
	assert conforms("scroll_in_region_up_preserves_history", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_in_region_up_preserves_history", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_in_region_up_preserves_history", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty scroll_up_reset: whole, in 61-byte frames, in small frames" {
	assert conforms("scroll_up_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_up_reset", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_up_reset", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty sgr: whole, in 61-byte frames, in small frames" {
	assert conforms("sgr", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("sgr", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("sgr", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tab_rendering: whole, in 61-byte frames, in small frames" {
	assert conforms("tab_rendering", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tab_rendering", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tab_rendering", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tmux_git_log: whole, in 61-byte frames, in small frames" {
	assert conforms("tmux_git_log", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_git_log", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_git_log", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tmux_htop: whole, in 61-byte frames, in small frames" {
	assert conforms("tmux_htop", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_htop", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_htop", 7, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty underline: whole, in 61-byte frames, in small frames" {
	assert conforms("underline", 0, Compare.RunsOwnPalette, 7) == "";
	assert conforms("underline", 61, Compare.RunsOwnPalette, 7) == "";
	assert conforms("underline", 1, Compare.RunsOwnPalette, 7) == "";
}

test "alacritty vim_24bitcolors_bce: whole, in 61-byte frames, in small frames" {
	assert conforms("vim_24bitcolors_bce", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_24bitcolors_bce", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_24bitcolors_bce", 509, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vim_large_window_scroll: whole, in 61-byte frames, in small frames" {
	assert conforms("vim_large_window_scroll", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_large_window_scroll", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_large_window_scroll", 509, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vim_simple_edit: whole, in 61-byte frames, in small frames" {
	assert conforms("vim_simple_edit", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_simple_edit", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_simple_edit", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vttest_origin_mode_1: whole, in 61-byte frames, in small frames" {
	assert conforms("vttest_origin_mode_1", 0, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_1", 61, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_1", 7, Compare.Text, -1) == "";
}

test "alacritty vttest_origin_mode_2: whole, in 61-byte frames, in small frames" {
	assert conforms("vttest_origin_mode_2", 0, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_2", 61, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_2", 1, Compare.Text, -1) == "";
}

test "alacritty vttest_scroll: whole, in 61-byte frames, in small frames" {
	assert conforms("vttest_scroll", 0, Compare.Text, -1) == "";
	assert conforms("vttest_scroll", 61, Compare.Text, -1) == "";
	assert conforms("vttest_scroll", 1, Compare.Text, -1) == "";
}

test "alacritty vttest_tab_clear_set: whole, in 61-byte frames, in small frames" {
	assert conforms("vttest_tab_clear_set", 0, Compare.Text, -1) == "";
	assert conforms("vttest_tab_clear_set", 61, Compare.Text, -1) == "";
	assert conforms("vttest_tab_clear_set", 1, Compare.Text, -1) == "";
}

test "alacritty wrapline_alt_toggle: whole, in 61-byte frames, in small frames" {
	assert conforms("wrapline_alt_toggle", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("wrapline_alt_toggle", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("wrapline_alt_toggle", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty zerowidth: whole, in 61-byte frames, in small frames" {
	assert conforms("zerowidth", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zerowidth", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zerowidth", 1, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty zsh_tab_completion: whole, in 61-byte frames, in small frames" {
	assert conforms("zsh_tab_completion", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zsh_tab_completion", 61, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zsh_tab_completion", 1, Compare.RunsOwnPalette, -1) == "";
}
