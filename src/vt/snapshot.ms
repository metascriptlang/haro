import {
	GhosttyFormatter,
	GhosttyFormatterFormat,
	GhosttyFormatterScreenExtra,
	GhosttyFormatterTerminalExtra,
	GhosttyFormatterTerminalOptions,
	GhosttyAllocator,
	GhosttyBuildInfo,
	GhosttyColorRgb,
	GhosttyResult,
	GhosttyString,
	GhosttyTerminal,
	GhosttyTerminalData,
	ghostty_formatter_free,
	ghostty_free,
	ghostty_formatter_terminal_new,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { Vt } from "./terminal";
import { title } from "./terminal";
import { wellFormed } from "./wellFormed";
import {
	Colors256,
	checked,
	pushAll,
	terminalGet,
	vtAllocator,
} from "./vtNative";
import { VtError } from "./vtTypes";

extern function formatInto(
	formatter: GhosttyFormatter,
	buf: Span<uint8>,
	out written: size_t,
): GhosttyResult from "ghostty_formatter_format_buf";

extern function encodeNative(
	terminal: GhosttyTerminal,
	allocator: Ptr<GhosttyAllocator> | null,
	out bytes: Ptr<uint8> | null,
	out len: size_t,
): GhosttyResult from "ghostty_snapshot_encode_alloc";

extern function buildText(
	key: GhosttyBuildInfo,
	out value: GhosttyString,
): GhosttyResult from "ghostty_build_info";

function restoreOptions(): GhosttyFormatterTerminalOptions {
	return {
		size: sizeof GhosttyFormatterTerminalOptions as size_t,
		emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
		unwrap: true,
		trim: false,
		extra: {
			size: sizeof GhosttyFormatterTerminalExtra as size_t,
			palette: false,
			modes: true,
			scrolling_region: true,
			tabstops: true,
			pwd: true,
			keyboard: true,
			screen: {
				size: sizeof GhosttyFormatterScreenExtra as size_t,
				cursor: true,
				style: true,
				hyperlink: true,
				protection: true,
				kitty_keyboard: true,
				charsets: true,
			},
		},
	};
}

function formatted(formatter: GhosttyFormatter): Result<Vec<uint8>, VtError> {
	let buf: Vec<uint8> = new Array(65536);
	let written: size_t = 0;
	let r = formatInto(formatter, buf, written);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
		buf = new Array(written as int32);
		r = formatInto(formatter, buf, written);
	}
	try checked(r, VtError.ReadFailed);
	buf.length = written as int32;
	return Result.ok(buf);
}

function hex(c: GhosttyColorRgb): string {
	const byte = (v: uint8): string => v.toString(16).padStart(2, "0");
	return `rgb:${byte(c.r)}/${byte(c.g)}/${byte(c.b)}`;
}

function same(a: GhosttyColorRgb, b: GhosttyColorRgb): boolean {
	return a.r == b.r && a.g == b.g && a.b == b.b;
}

function colorPair(
	terminal: GhosttyTerminal,
	current: GhosttyTerminalData,
	initial: GhosttyTerminalData,
): Result<[GhosttyColorRgb, GhosttyColorRgb], VtError> {
	let now: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	let was: GhosttyColorRgb = { r: 0, g: 0, b: 0 };
	try checked(terminalGet(terminal, current, now), VtError.ReadFailed);
	try checked(terminalGet(terminal, initial, was), VtError.ReadFailed);
	return Result.ok([now, was]);
}

function colorOverrides(terminal: GhosttyTerminal): Result<string, VtError> {
	let osc = "";
	let now: Colors256;
	let was: Colors256;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE;
	const initial = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT;
	try checked(terminalGet(terminal, key, now), VtError.ReadFailed);
	try checked(terminalGet(terminal, initial, was), VtError.ReadFailed);
	for (let i = 0; i < 256; i++) {
		if (!same(now.c[i], was.c[i])) {
			osc += `\x1b]4;${i};${hex(now.c[i])}\x1b\\`;
		}
	}
	const fg = try colorPair(
		terminal,
		GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
		GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT,
	);
	if (!same(fg[0], fg[1])) { osc += `\x1b]10;${hex(fg[0])}\x1b\\`; }
	const bg = try colorPair(
		terminal,
		GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
		GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT,
	);
	if (!same(bg[0], bg[1])) { osc += `\x1b]11;${hex(bg[0])}\x1b\\`; }
	return Result.ok(osc);
}

export function snapshot(this vt: Vt): Result<Vec<uint8>, VtError> {
	let formatter: GhosttyFormatter;
	const made = ghostty_formatter_terminal_new(
		vtAllocator(),
		formatter,
		vt.terminal,
		restoreOptions(),
	);
	try checked(made, VtError.ReadFailed);
	defer ghostty_formatter_free(formatter);
	let bytes: Vec<uint8> = [];
	pushAll(bytes, (try colorOverrides(vt.terminal)).asBytes());
	pushAll(bytes, try formatted(formatter));
	const named = try vt.title();
	if (named.length > 0) { pushAll(bytes, `\x1b]2;${named}\x1b\\`.asBytes()); }
	return Result.ok(bytes);
}

export function nativeSnapshot(this vt: Vt): Result<Vec<uint8>, VtError> {
	let bytes: Ptr<uint8> | null = null;
	let len: size_t = 0;
	try checked(encodeNative(vt.terminal, vtAllocator(), bytes, len), VtError.ReadFailed);
	let out: Vec<uint8> = [];
	if (bytes !== null) {
		pushAll(out, bytes[0..len]);
		ghostty_free(vtAllocator(), bytes, len);
	}
	return Result.ok(out);
}

export function vtBuild(): string {
	let version: GhosttyString;
	const key = GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_STRING;
	if (!checked(buildText(key, version), VtError.ReadFailed).ok) {
		throw new Error("vtBuild: libghostty-vt reports no version string");
	}
	return wellFormed(version.ptr[0..version.len]);
}
