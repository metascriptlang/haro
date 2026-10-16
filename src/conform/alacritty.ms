import { readFile } from "std/fs";
import { LineRun } from "../grid/lines";
import { Rgb, Underline } from "../vt/vt";
import { Screen } from "./screen";

const ROOT = "fixtures/conform/alacritty/";
const DEFAULT_FG: Rgb = { r: 12, g: 34, b: 56 };
const DEFAULT_BG: Rgb = { r: 65, g: 43, b: 21 };
const HEX = "0123456789abcdef";
const GHOSTTY_NAMED: uint32[] = [
	0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
	0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
];

enum Compare {
	Text,
	RunsOwnPalette,
	RunsDefaultPalette,
}

function hex2(n: int32): string {
	return HEX[n >> 4] + HEX[n & 15];
}

function ownIndexed(n: int32): Rgb {
	return { r: n as uint8, g: ((n * 7 + 31) % 256) as uint8, b: (255 - n) as uint8 };
}

function cubeLevel(v: int32): uint8 {
	return (v == 0 ? 0 : v * 40 + 55) as uint8;
}

function defaultIndexed(n: int32): Rgb {
	if (n < 16) {
		const c = GHOSTTY_NAMED[n];
		return { r: ((c >> 16) & 255) as uint8, g: ((c >> 8) & 255) as uint8, b: (c & 255) as uint8 };
	}
	if (n < 232) {
		const k = n - 16;
		return { r: cubeLevel(k / 36), g: cubeLevel((k / 6) % 6), b: cubeLevel(k % 6) };
	}
	const gray = ((n - 232) * 10 + 8) as uint8;
	return { r: gray, g: gray, b: gray };
}

function palettePrelude(own: boolean): string {
	let out = "";
	for (let n = 0; own && n < 256; n++) {
		const c = ownIndexed(n);
		out += `]4;${n};rgb:${hex2(c.r as int32)}/${hex2(c.g as int32)}/${hex2(c.b as int32)}`;
	}
	out += `]10;rgb:${hex2(DEFAULT_FG.r as int32)}/${hex2(DEFAULT_FG.g as int32)}/${hex2(DEFAULT_FG.b as int32)}`;
	out += `]11;rgb:${hex2(DEFAULT_BG.r as int32)}/${hex2(DEFAULT_BG.g as int32)}/${hex2(DEFAULT_BG.b as int32)}`;
	return out;
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
		const run: LineRun = {
			units: parts[0].parseInt() as int32,
			fg: colorOf(parts[1], DEFAULT_FG, own),
			bg: colorOf(parts[2], DEFAULT_BG, own),
			underline: underlineOf(flags),
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
			const want = expectedRuns(expectAttrs[y], own);
			if (!runsEqual(s.runs(y), want)) {
				failure = `row ${y} runs: expected${showRuns(want)} got${showRuns(s.runs(y))}`;
			}
		}
	}
	s.close();
	if (failure != "") { console.log(`${name} (chunk ${chunk}): ${failure}`); }
	return failure;
}

test "alacritty alt_reset: one frame and many frames" {
	assert conforms("alt_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("alt_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty clear_underline: one frame and many frames" {
	assert conforms("clear_underline", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("clear_underline", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty colored_reset: one frame and many frames" {
	assert conforms("colored_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty colored_underline: one frame and many frames" {
	assert conforms("colored_underline", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("colored_underline", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty csi_rep: one frame and many frames" {
	assert conforms("csi_rep", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("csi_rep", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty delete_chars_reset: one frame and many frames" {
	assert conforms("delete_chars_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_chars_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty delete_lines: one frame and many frames" {
	assert conforms("delete_lines", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("delete_lines", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty erase_chars_reset: one frame and many frames" {
	assert conforms("erase_chars_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("erase_chars_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty fish_cc: one frame and many frames" {
	assert conforms("fish_cc", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("fish_cc", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty grid_reset: one frame and many frames" {
	assert conforms("grid_reset", 0, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("grid_reset", 61, Compare.RunsDefaultPalette, -1) == "";
}

test "alacritty history: one frame and many frames" {
	assert conforms("history", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("history", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty hyperlinks: one frame and many frames" {
	assert conforms("hyperlinks", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("hyperlinks", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty indexed_256_colors: one frame and many frames" {
	assert conforms("indexed_256_colors", 0, Compare.RunsDefaultPalette, -1) == "";
	assert conforms("indexed_256_colors", 61, Compare.RunsDefaultPalette, -1) == "";
}

test "alacritty insert_blank_reset: one frame and many frames" {
	assert conforms("insert_blank_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("insert_blank_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty issue_855: one frame and many frames" {
	assert conforms("issue_855", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("issue_855", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty ll: one frame and many frames" {
	assert conforms("ll", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("ll", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty newline_with_cursor_beyond_scroll_region: one frame and many frames" {
	assert conforms("newline_with_cursor_beyond_scroll_region", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("newline_with_cursor_beyond_scroll_region", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty origin_goto: one frame and many frames" {
	assert conforms("origin_goto", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("origin_goto", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty region_scroll_down: one frame and many frames" {
	assert conforms("region_scroll_down", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("region_scroll_down", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty row_reset: one frame and many frames" {
	assert conforms("row_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("row_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty scroll_in_region_up_preserves_history: one frame and many frames" {
	assert conforms("scroll_in_region_up_preserves_history", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_in_region_up_preserves_history", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty scroll_up_reset: one frame and many frames" {
	assert conforms("scroll_up_reset", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("scroll_up_reset", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty sgr: one frame and many frames" {
	assert conforms("sgr", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("sgr", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tab_rendering: one frame and many frames" {
	assert conforms("tab_rendering", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tab_rendering", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tmux_git_log: one frame and many frames" {
	assert conforms("tmux_git_log", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_git_log", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty tmux_htop: one frame and many frames" {
	assert conforms("tmux_htop", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("tmux_htop", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty underline: one frame and many frames" {
	assert conforms("underline", 0, Compare.RunsOwnPalette, 7) == "";
	assert conforms("underline", 61, Compare.RunsOwnPalette, 7) == "";
}

test "alacritty vim_24bitcolors_bce: one frame and many frames" {
	assert conforms("vim_24bitcolors_bce", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_24bitcolors_bce", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vim_large_window_scroll: one frame and many frames" {
	assert conforms("vim_large_window_scroll", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_large_window_scroll", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vim_simple_edit: one frame and many frames" {
	assert conforms("vim_simple_edit", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("vim_simple_edit", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty vttest_origin_mode_1: one frame and many frames" {
	assert conforms("vttest_origin_mode_1", 0, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_1", 61, Compare.Text, -1) == "";
}

test "alacritty vttest_origin_mode_2: one frame and many frames" {
	assert conforms("vttest_origin_mode_2", 0, Compare.Text, -1) == "";
	assert conforms("vttest_origin_mode_2", 61, Compare.Text, -1) == "";
}

test "alacritty vttest_scroll: one frame and many frames" {
	assert conforms("vttest_scroll", 0, Compare.Text, -1) == "";
	assert conforms("vttest_scroll", 61, Compare.Text, -1) == "";
}

test "alacritty vttest_tab_clear_set: one frame and many frames" {
	assert conforms("vttest_tab_clear_set", 0, Compare.Text, -1) == "";
	assert conforms("vttest_tab_clear_set", 61, Compare.Text, -1) == "";
}

test "alacritty wrapline_alt_toggle: one frame and many frames" {
	assert conforms("wrapline_alt_toggle", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("wrapline_alt_toggle", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty zerowidth: one frame and many frames" {
	assert conforms("zerowidth", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zerowidth", 61, Compare.RunsOwnPalette, -1) == "";
}

test "alacritty zsh_tab_completion: one frame and many frames" {
	assert conforms("zsh_tab_completion", 0, Compare.RunsOwnPalette, -1) == "";
	assert conforms("zsh_tab_completion", 61, Compare.RunsOwnPalette, -1) == "";
}
