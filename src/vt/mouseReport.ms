import {
	GhosttyMouseAction,
	GhosttyMouseEncoder,
	GhosttyMouseEncoderOption,
	GhosttyMouseEncoderSize,
	GhosttyMouseEvent,
	ghostty_mouse_encoder_free,
	ghostty_mouse_encoder_new,
	ghostty_mouse_encoder_setopt_from_terminal,
	ghostty_mouse_event_clear_button,
	ghostty_mouse_event_new,
	ghostty_mouse_event_set_action,
	ghostty_mouse_event_set_position,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import { modsMask } from "../keys/keys";
import { Vt } from "./terminal";
import {
	mouseEncode,
	mouseSetButton,
	mouseSetFlag,
	mouseSetMods,
	mouseSetSize,
	ok,
	vtAllocator,
} from "./vtNative";
import {
	Mouse,
	MouseAction,
	MouseCodec,
	MouseGeometry,
	MouseInput,
	VtError,
} from "./vtTypes";

function mouseActionOf(a: MouseAction): GhosttyMouseAction {
	return match (a) {
		MouseAction.Press => GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
		MouseAction.Release => GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
		MouseAction.Motion => GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
	};
}

function open(this m: Mouse): Result<MouseCodec, VtError> {
	const known = m.codec;
	if (known !== null) { return Result.ok(known); }
	let encoder: GhosttyMouseEncoder;
	let event: GhosttyMouseEvent;
	if (!ok(ghostty_mouse_encoder_new(vtAllocator(), encoder))) {
		return Result.err(VtError.ReadFailed);
	}
	if (!ok(ghostty_mouse_event_new(vtAllocator(), event))) {
		ghostty_mouse_encoder_free(encoder);
		return Result.err(VtError.ReadFailed);
	}
	let track = true;
	const trackOption = GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL;
	mouseSetFlag(encoder, trackOption, track);
	const codec: MouseCodec = { encoder: encoder, event: event };
	m.codec = codec;
	return Result.ok(codec);
}

// x and y are surface pixels with the grid at the origin.
export function mouseReport(
	this vt: Vt,
	input: MouseInput,
	geometry: MouseGeometry,
	anyPressed: boolean,
	buf: Span<uint8>,
): Result<int32, VtError> {
	const m = vt.mouse;
	const codec = try m.open();
	const encoder = codec.encoder;
	const event = codec.event;
	if (m.stale) {
		ghostty_mouse_encoder_setopt_from_terminal(encoder, vt.terminal);
		m.stale = false;
	}
	const known = m.geometry;
	if (known === null || known != geometry) {
		let size: GhosttyMouseEncoderSize = {
			size: sizeof GhosttyMouseEncoderSize,
			screen_width: geometry.width as uint32,
			screen_height: geometry.height as uint32,
			cell_width: geometry.cellWidth as uint32,
			cell_height: geometry.cellHeight as uint32,
			padding_top: geometry.padTop as uint32,
			padding_bottom: geometry.padBottom as uint32,
			padding_right: geometry.padRight as uint32,
			padding_left: geometry.padLeft as uint32,
		};
		mouseSetSize(encoder, GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, size);
		m.geometry = geometry;
	}
	let pressed = anyPressed;
	const pressedOption = GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED;
	mouseSetFlag(encoder, pressedOption, pressed);
	ghostty_mouse_event_set_action(event, mouseActionOf(input.action));
	if (input.button == 0) {
		ghostty_mouse_event_clear_button(event);
	} else {
		mouseSetButton(event, input.button);
	}
	mouseSetMods(event, modsMask(input.mods));
	ghostty_mouse_event_set_position(event, { x: input.x, y: input.y });
	let written: uint64 = 0;
	if (!ok(mouseEncode(encoder, event, buf, written))) { return Result.err(VtError.ReadFailed); }
	return Result.ok(written as int32);
}
