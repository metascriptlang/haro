import {
	GhosttyClipboardLocation,
	GhosttyClipboardRead,
	GhosttyClipboardReadReply,
	GhosttyClipboardReadResult,
	GhosttyClipboardWrite,
	GhosttyClipboardWriteReply,
	GhosttyClipboardWriteResult,
	GhosttyDeviceAttributes,
	GhosttyPointTag,
	GhosttyRenderState,
	GhosttySemanticPromptKind,
	GhosttySemanticPromptPromptKind,
	GhosttySizeReportSize,
	GhosttyString,
	GhosttyTerminal,
	GhosttyTerminalData,
	GhosttyTerminalDesktopNotification,
	GhosttyTerminalScreen,
	GhosttyTerminalSemanticPrompt,
	GhosttyTrackedGridRef,
	ghostty_render_state_update,
	ghostty_tracked_grid_ref_free,
	ghostty_tracked_grid_ref_has_value,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { encodeBase64 } from "std/crypto/encoding";
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
	vtTrack,
} from "./vtNative";
import { VtError } from "./vtTypes";
import { wellFormed, wellFormedPrefix } from "./wellFormed";

const HOLD_LIMIT_MS: float64 = 1000;

export interface Effects {
	state: GhosttyRenderState;
	replies: Vec<uint8>;
	events: VtEvents;
	heldSinceMs: float64 | null;
	holdFailed: boolean;
	freed: boolean;
	holdLimitMs: float64;
	clipboard: string | null;
	readFrame: Vec<uint8> | null;
	readAsked: boolean;
	running: Running | null;
	promptAt: int32 | null;
	anchors: Vec<TrackedAnchor>;
	nextAnchor: int32;
}

struct Running {
	command: string;
	startedMs: float64;
	prompt: int32 | null;
	output: int32;
}

export struct TrackedAnchor {
	id: int32;
	tracked: GhosttyTrackedGridRef;
}

export const ANCHOR_CAP = 1024;

export function openEffects(
	terminal: GhosttyTerminal,
	state: GhosttyRenderState,
): Result<Effects, VtError> {
	const e: Effects = {
		state: state,
		replies: [],
		events: NO_EVENTS,
		heldSinceMs: null,
		holdFailed: false,
		freed: false,
		holdLimitMs: HOLD_LIMIT_MS,
		clipboard: null,
		readFrame: null,
		readAsked: false,
		running: null,
		promptAt: null,
		anchors: [],
		nextAnchor: 0,
	};
	if (vtEffectsWire(terminal, Handle.borrow(e).ptr) != 0) {
		closeEffects(terminal);
		return Result.err(VtError.EffectsWireFailed);
	}
	return Result.ok(e);
}

export function closeEffects(terminal: GhosttyTerminal): Result<void, VtError> {
	if (vtEffectsWire(terminal, null) != 0) { return Result.err(VtError.WriteFailed); }
	return Result.ok(null);
}

function dropLostAnchors(this e: Effects): void {
	let kept: Vec<TrackedAnchor> = [];
	for (const a of e.anchors) {
		if (ghostty_tracked_grid_ref_has_value(a.tracked)) {
			kept.push(a);
		} else {
			ghostty_tracked_grid_ref_free(a.tracked);
		}
	}
	e.anchors = kept;
}

function onPrimaryScreen(terminal: GhosttyTerminal): boolean {
	let screen = GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
	const key = GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN;
	return ok(terminalGet(terminal, key, screen)) &&
		screen == GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
}

function anchorCursor(this e: Effects, terminal: GhosttyTerminal): int32 {
	const id = e.nextAnchor;
	e.nextAnchor += 1;
	e.dropLostAnchors();
	let x: uint16 = 0;
	let y: uint16 = 0;
	let tracked: GhosttyTrackedGridRef;
	const active = GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE;
	const placed = onPrimaryScreen(terminal) &&
		ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_X, x)) &&
		ok(terminalGet(terminal, GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_Y, y)) &&
		ok(vtTrack(terminal, active, x as int32, y as int32, tracked));
	if (!placed) { return id; }
	if (e.anchors.length >= ANCHOR_CAP) {
		ghostty_tracked_grid_ref_free(e.anchors.shift().tracked);
	}
	e.anchors.push({ id: id, tracked: tracked });
	return id;
}

export function anchorIndex(this e: Effects, id: int32): int32 {
	let low = 0;
	let high = e.anchors.length as int32;
	while (low < high) {
		const mid = (low + high) >> 1;
		if (e.anchors[mid].id < id) {
			low = mid + 1;
		} else {
			high = mid;
		}
	}
	return low < (e.anchors.length as int32) && e.anchors[low].id == id ? low : -1;
}

export function freeAnchors(this e: Effects): void {
	for (const a of e.anchors) { ghostty_tracked_grid_ref_free(a.tracked); }
	e.anchors = [];
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
	if (!ok(ghostty_render_state_update(e.state, terminal))) {
		e.holdFailed = true;
		return;
	}
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
		if (c.mime.ptr[0..c.mime.len].asString() == PLAIN_TEXT) { return wellFormed(c.data.ptr[0..c.data.len]); }
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
function boundedText(text: Readonly<GhosttyString>, maxBytes: int32): string {
	return wellFormedPrefix(text.ptr[0..text.len], maxBytes);
}

@exportName("haroVtDesktopNotification")
function desktopNotification(
	terminal: GhosttyTerminal,
	effects: Ptr<void>,
	notification: Readonly<Ptr<GhosttyTerminalDesktopNotification>>,
): void {
	const hasBody = notification.size >= (sizeof GhosttyTerminalDesktopNotification as size_t);
	effectsAt(effects).events.notification = {
		title: boundedText(notification.title, NOTIFICATION_TITLE_BYTES),
		body: hasBody ? boundedText(notification.body, NOTIFICATION_BODY_BYTES) : "",
	};
}

const COMMAND_BYTES = 4096;

@exportName("haroVtSemanticPrompt")
function semanticPrompt(
	terminal: GhosttyTerminal,
	effects: Ptr<void>,
	event: Readonly<Ptr<GhosttyTerminalSemanticPrompt>>,
): void {
	const e = effectsAt(effects);
	const primary = GhosttySemanticPromptPromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY;
	match (event.kind) {
		GhosttySemanticPromptKind.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => {
			if (event.prompt_kind != primary) { return; }
			e.running = null;
			const at = e.anchorCursor(terminal);
			e.promptAt = at;
			e.events.shell.push({ step: ShellStep.Prompt, at: at });
		},
		GhosttySemanticPromptKind.GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => {
			e.running = {
				command: boundedText(event.command, COMMAND_BYTES),
				startedMs: performance.now(),
				prompt: e.promptAt,
				output: e.anchorCursor(terminal),
			};
			e.promptAt = null;
		},
		GhosttySemanticPromptKind.GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => {
			const running = e.running;
			const prompt = running === null ? e.promptAt : running.prompt;
			e.running = null;
			e.promptAt = null;
			e.events.shell.push({
				step: ShellStep.CommandDone,
				done: {
					exitCode: event.has_exit_code ? event.exit_code : null,
					command: running?.command ?? "",
					durationMs: running === null ? null : performance.now() - running.startedMs,
					prompt: prompt,
					output: running === null ? null : running.output,
					end: e.anchorCursor(terminal),
				},
			});
		},
		_ => {},
	}
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

const SEMICOLON: uint8 = 0x3b;

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
	if (allow) { pushAll(e.replies, text.asBytes().encodeBase64().asBytes()); }
	pushAll(e.replies, frame[head..frame.length]);
	e.readFrame = null;
	return true;
}

export struct DesktopNotification {
	title: string;
	body: string;
}

export struct CommandDone {
	exitCode: int32 | null;
	command: string;
	durationMs: float64 | null;
	prompt: int32 | null;
	output: int32 | null;
	end: int32;
}

export enum ShellStep {
	Prompt,
	CommandDone,
}

export struct ShellMark = match (step: ShellStep) {
	ShellStep.Prompt => { at: int32 },
	ShellStep.CommandDone => { done: CommandDone },
};

export struct VtEvents {
	bells: int32;
	titleChanged: boolean;
	pwdChanged: boolean;
	notification: DesktopNotification | null;
	shell: Vec<ShellMark>;
}

export const NO_EVENTS: VtEvents = {
	bells: 0,
	titleChanged: false,
	pwdChanged: false,
	notification: null,
	shell: [],
};
