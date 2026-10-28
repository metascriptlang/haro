import {
	GhosttyClipboardLocation,
	GhosttyClipboardRead,
	GhosttyClipboardReadReply,
	GhosttyClipboardReadResult,
	GhosttyClipboardWrite,
	GhosttyClipboardWriteReply,
	GhosttyClipboardWriteResult,
	GhosttyDeviceAttributes,
	GhosttyRenderState,
	GhosttySizeReportSize,
	GhosttyString,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalDesktopNotification,
	ghostty_render_state_update,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { Handle } from "std/ffi";
import {
	GHOSTTY_DA_CONFORMANCE_LEVEL_2,
	GHOSTTY_DA_DEVICE_TYPE_VT220,
	GHOSTTY_DA_FEATURE_ANSI_COLOR,
	GHOSTTY_DA_FEATURE_CLIPBOARD,
	ok,
	pushAll,
	terminalGet,
	vtEffectsWire,
} from "./vtNative";
import { VtError } from "./vtTypes";

const HOLD_LIMIT_MS: float64 = 1000;

export interface Effects {
	state: GhosttyRenderState;
	replies: Vec<uint8>;
	events: VtEvents;
	heldSinceMs: float64 | null;
	holdLimitMs: float64;
	clipboard: string | null;
	readFrame: Vec<uint8> | null;
	readAsked: boolean;
}

export function openEffects(
	terminal: GhosttyTerminal,
	state: GhosttyRenderState,
): Result<Effects, VtError> {
	const e: Effects = {
		state: state,
		replies: [],
		events: NO_EVENTS,
		heldSinceMs: null,
		holdLimitMs: HOLD_LIMIT_MS,
		clipboard: null,
		readFrame: null,
		readAsked: false,
	};
	if (vtEffectsWire(terminal, Handle.borrow(e).ptr) != 0) {
		closeEffects(terminal);
		return Result.err(VtError.CreateFailed);
	}
	return Result.ok(e);
}

export function closeEffects(terminal: GhosttyTerminal): void {
	const _cleared = vtEffectsWire(terminal, null);
}

function effectsAt(p: Ptr<void>): Effects {
	return Handle.at<Effects>(p).value();
}

@exportName("haroVtWritePty")
function writePty(terminal: GhosttyTerminal, effects: Ptr<void>, bytes: Readonly<Ptr<uint8>>, n: size_t): void {
	pushAll(effectsAt(effects).replies, bytes[0..n]);
}

@exportName("haroVtBell")
function bell(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).events.bells += 1;
}

@exportName("haroVtTitleChanged")
function titleChanged(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).events.titleChanged = true;
}

@exportName("haroVtPwdChanged")
function pwdChanged(terminal: GhosttyTerminal, effects: Ptr<void>): void {
	effectsAt(effects).events.pwdChanged = true;
}

@exportName("haroVtRenderHold")
function renderHold(terminal: GhosttyTerminal, effects: Ptr<void>, held: boolean): void {
	const e = effectsAt(effects);
	if (!held) {
		e.heldSinceMs = null;
		return;
	}
	const _captured = ghostty_render_state_update(e.state, terminal);
	e.heldSinceMs = performance.now();
}

const PLAIN_TEXT = "text/plain";

@exportName("haroVtClipboardWrite")
function clipboardWrite(terminal: GhosttyTerminal, effects: Ptr<void>, write: Ptr<GhosttyClipboardWrite>): void {
	let reply: GhosttyClipboardWriteReply = {
		size: sizeof GhosttyClipboardWriteReply as size_t,
		result: GhosttyClipboardWriteResult.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED,
	};
	const text = plainText(write);
	if (text !== null) {
		effectsAt(effects).clipboard = text;
		reply.result = GhosttyClipboardWriteResult.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
	}
	write.reply(write, reply as Ptr<GhosttyClipboardWriteReply>);
}

function plainText(write: Ptr<GhosttyClipboardWrite>): string | null {
	if (write.location != GhosttyClipboardLocation.GHOSTTY_CLIPBOARD_LOCATION_STANDARD) { return null; }
	if (write.contents_len == 0) { return ""; }
	for (const c of write.contents[0..write.contents_len]) {
		if (c.mime.ptr[0..c.mime.len].asString() == PLAIN_TEXT) { return c.data.ptr[0..c.data.len].asString(); }
	}
	return null;
}

const XTVERSION_NAME: cstring = "haro";
const XTVERSION_NAME_BYTES = 4;

@exportName("haroVtDeviceAttributes")
function deviceAttributes(terminal: GhosttyTerminal, effects: Ptr<void>, out da: GhosttyDeviceAttributes): boolean {
	da = {
		primary: { conformance_level: GHOSTTY_DA_CONFORMANCE_LEVEL_2, num_features: 2 },
		secondary: { device_type: GHOSTTY_DA_DEVICE_TYPE_VT220, firmware_version: 10 },
	};
	da.primary.features[0] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
	da.primary.features[1] = GHOSTTY_DA_FEATURE_CLIPBOARD;
	return true;
}

@exportName("haroVtSize")
function sizeReport(terminal: GhosttyTerminal, effects: Ptr<void>, out size: GhosttySizeReportSize): boolean {
	let cols: uint16 = 0;
	let rows: uint16 = 0;
	let width: uint32 = 0;
	let height: uint32 = 0;
	const read = ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLS, cols)) &&
		ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ROWS, rows)) &&
		ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_WIDTH_PX, width)) &&
		ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_HEIGHT_PX, height)) &&
		cols > 0 && rows > 0;
	size = {
		rows: rows,
		columns: cols,
		cell_width: read ? width / (cols as uint32) : 0,
		cell_height: read ? height / (rows as uint32) : 0,
	};
	return read;
}

@exportName("haroVtXtversion")
function xtversion(terminal: GhosttyTerminal, effects: Ptr<void>): GhosttyString {
	const name: GhosttyString = { ptr: XTVERSION_NAME as Ptr<uint8>, len: XTVERSION_NAME_BYTES };
	return name;
}

export const NOTIFICATION_TITLE_BYTES = 256;
export const NOTIFICATION_BODY_BYTES = 1024;
const REPLACEMENT_CHARACTER = "\u{fffd}";
const LONGEST_UTF8_BYTES = 4;

export function byteAt(text: Readonly<GhosttyString>, at: int32): int32 {
	return text.ptr[at] as int32;
}

function wellFormedLength(text: Readonly<GhosttyString>, at: int32, end: int32): int32 {
	const lead = byteAt(text, at);
	if (lead < 0x80) { return 1; }
	let width = 0;
	if (lead >= 0xc2 && lead <= 0xdf) { width = 2; }
	if (lead >= 0xe0 && lead <= 0xef) { width = 3; }
	if (lead >= 0xf0 && lead <= 0xf4) { width = 4; }
	if (width == 0 || at + width > end) { return 0; }
	const low = lead == 0xe0 ? 0xa0 : lead == 0xf0 ? 0x90 : 0x80;
	const high = lead == 0xed ? 0x9f : lead == 0xf4 ? 0x8f : 0xbf;
	const second = byteAt(text, at + 1);
	if (second < low || second > high) { return 0; }
	for (let i = 2; i < width; i++) {
		const next = byteAt(text, at + i);
		if (next < 0x80 || next > 0xbf) { return 0; }
	}
	return width;
}

function wellFormedPrefix(text: Readonly<GhosttyString>, maxBytes: int32): string {
	const scan = maxBytes + LONGEST_UTF8_BYTES;
	const end = text.len < (scan as uint64) ? text.len as int32 : scan;
	const replacement = REPLACEMENT_CHARACTER.asBytes();
	let out: Vec<uint8> = [];
	let at = 0;
	while (at < end) {
		const width = wellFormedLength(text, at, end);
		const size = width == 0 ? replacement.length as int32 : width;
		if (out.length + size > maxBytes) { break; }
		if (width == 0) {
			pushAll(out, replacement);
		} else {
			for (let i = 0; i < width; i++) { out.push(byteAt(text, at + i) as uint8); }
		}
		at += Math.max(width, 1);
	}
	return out[0..out.length].asString();
}

@exportName("haroVtDesktopNotification")
function desktopNotification(
	terminal: GhosttyTerminal,
	effects: Ptr<void>,
	notification: Readonly<Ptr<GhosttyTerminalDesktopNotification>>,
): void {
	const hasBody = notification.size >= (sizeof GhosttyTerminalDesktopNotification as size_t);
	effectsAt(effects).events.notification = {
		title: wellFormedPrefix(notification.title, NOTIFICATION_TITLE_BYTES),
		body: hasBody ? wellFormedPrefix(notification.body, NOTIFICATION_BODY_BYTES) : "",
	};
}

const OSC52_REPLY = "\x1b]52;";
const SHORTEST_OSC52_REPLY = "\x1b]52;c;\x07".byteLength;

// libghostty takes a read's reply before the callback returns, so the callback denies it and this
// moves the empty reply written after mark (ESC ] 52 ; c ; and the program's terminator) into
// readFrame, for answerClipboard to fill once the user decides.
@exportName("haroVtClipboardRead")
function clipboardRead(terminal: GhosttyTerminal, effects: Ptr<void>, read: Ptr<GhosttyClipboardRead>): void {
	let reply: GhosttyClipboardReadReply = {
		size: sizeof GhosttyClipboardReadReply as size_t,
		result: GhosttyClipboardReadResult.GHOSTTY_CLIPBOARD_READ_RESULT_DENIED,
	};
	const e = effectsAt(effects);
	const mark = e.replies.length;
	read.reply(read, reply as Ptr<GhosttyClipboardReadReply>);
	if (read.location == GhosttyClipboardLocation.GHOSTTY_CLIPBOARD_LOCATION_STANDARD) { holdRead(e, mark); }
}

function holdRead(e: Effects, from: int32): void {
	if (e.readFrame !== null || e.replies.length - from < SHORTEST_OSC52_REPLY) { return; }
	const prefix = OSC52_REPLY.asBytes();
	for (let i = 0; i < prefix.length; i++) {
		if (e.replies[from + i] != prefix[i]) { return; }
	}
	let frame: Vec<uint8> = [];
	pushAll(frame, e.replies[from..e.replies.length]);
	e.replies.shrink(from);
	e.readFrame = frame;
	e.readAsked = true;
}

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".asBytes();
const PAD: uint8 = 0x3d;
const SEMICOLON: uint8 = 0x3b;

function pushBase64(ref out: Vec<uint8>, bytes: Readonly<Span<uint8>>): void {
	for (let i = 0; i < bytes.length; i += 3) {
		let v = (bytes[i] as uint32) << 16;
		if (i + 1 < bytes.length) { v |= (bytes[i + 1] as uint32) << 8; }
		if (i + 2 < bytes.length) { v |= bytes[i + 2] as uint32; }
		out.push(BASE64[((v >> 18) & 63) as int32]);
		out.push(BASE64[((v >> 12) & 63) as int32]);
		out.push(i + 1 < bytes.length ? BASE64[((v >> 6) & 63) as int32] : PAD);
		out.push(i + 2 < bytes.length ? BASE64[(v & 63) as int32] : PAD);
	}
}

export function answerRead(this e: Effects, text: string, allow: boolean): boolean {
	const frame = e.readFrame;
	if (frame === null) { return false; }
	let head = 0;
	let semicolons = 0;
	while (head < frame.length && semicolons < 2) {
		if (frame[head] == SEMICOLON) { semicolons++; }
		head++;
	}
	pushAll(e.replies, frame[0..head]);
	if (allow) { pushBase64(e.replies, text.asBytes()); }
	pushAll(e.replies, frame[head..frame.length]);
	e.readFrame = null;
	return true;
}

export struct DesktopNotification {
	title: string;
	body: string;
}

export struct VtEvents {
	bells: int32;
	titleChanged: boolean;
	pwdChanged: boolean;
	notification: DesktopNotification | null;
}

export const NO_EVENTS: VtEvents = { bells: 0, titleChanged: false, pwdChanged: false, notification: null };
