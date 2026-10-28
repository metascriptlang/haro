import {
	GhosttyKeyAction,
	GhosttyKeyEncoder,
	GhosttyKeyEncoderOption,
	GhosttyKeyEvent,
	GhosttyOptionAsAlt,
	GhosttyResult,
	ghostty_key_encoder_free,
	ghostty_key_encoder_new,
	ghostty_key_encoder_setopt_from_terminal,
	ghostty_key_event_free,
	ghostty_key_event_new,
	ghostty_key_event_set_action,
	ghostty_key_event_set_key,
	ghostty_key_event_set_unshifted_codepoint,
	ghostty_key_event_set_utf8,
	size_t,
} from "../../vendor/ghostty/include/ghostty/vt.h";
import {
	KeyAction,
	KeyEvent,
	OptionAsAlt,
	modsMask,
	textSafe,
} from "../keys/keys";
import { keyOf } from "./keyNames";
import { Vt } from "./terminal";
import {
	MODE_BRACKETED_PASTE,
	encoderEncode,
	encoderSetOptionAsAlt,
	eventSetConsumedMods,
	eventSetMods,
	modeOn,
	ok,
	pasteEncode,
	pasteSafe,
	vtAllocator,
} from "./vtNative";
import { PasteError } from "./vtTypes";

export enum KeysError {
	OpenFailed,
	EncodeFailed,
	NoRoom,
}

export struct Keys {
	encoder: GhosttyKeyEncoder;
	event: GhosttyKeyEvent;
	optionAsAlt: OptionAsAlt;
}

function optionAsAltOf(option: OptionAsAlt): GhosttyOptionAsAlt {
	return match (option) {
		OptionAsAlt.Neither => GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE,
		OptionAsAlt.Left => GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_LEFT,
		OptionAsAlt.Right => GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_RIGHT,
		OptionAsAlt.Both => GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_TRUE,
	};
}

function actionOf(a: KeyAction): GhosttyKeyAction {
	return match (a) {
		KeyAction.Release => GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE,
		KeyAction.Press => GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
		KeyAction.Repeat => GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT,
	};
}

export function openKeys(this typeof Keys): Result<Keys, KeysError> {
	let encoder: GhosttyKeyEncoder;
	if (!ok(ghostty_key_encoder_new(vtAllocator(), encoder))) {
		return Result.err(KeysError.OpenFailed);
	}
	let event: GhosttyKeyEvent;
	if (!ok(ghostty_key_event_new(vtAllocator(), event))) {
		ghostty_key_encoder_free(encoder);
		return Result.err(KeysError.OpenFailed);
	}
	return Result.ok({ encoder: encoder, event: event, optionAsAlt: OptionAsAlt.Neither });
}

export function encode(
	this k: Keys,
	vt: Vt,
	e: KeyEvent,
	buf: Span<uint8>,
): Result<int32, KeysError> {
	ghostty_key_encoder_setopt_from_terminal(k.encoder, vt.terminal);
	const optionAsAlt = GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT;
	let option = optionAsAltOf(k.optionAsAlt);
	encoderSetOptionAsAlt(k.encoder, optionAsAlt, option);
	ghostty_key_event_set_action(k.event, actionOf(e.action));
	ghostty_key_event_set_key(k.event, keyOf(e.key));
	eventSetMods(k.event, modsMask(e.mods));
	eventSetConsumedMods(k.event, modsMask(e.consumedMods));
	ghostty_key_event_set_unshifted_codepoint(k.event, e.unshifted);
	if (textSafe(e.text)) {
		ghostty_key_event_set_utf8(k.event, e.text, e.text.byteLength as size_t);
	} else {
		ghostty_key_event_set_utf8(k.event, "", 0);
	}
	let written: size_t = 0;
	const r = encoderEncode(k.encoder, k.event, buf, written);
	if (r == GhosttyResult.GHOSTTY_OUT_OF_SPACE) { return Result.err(KeysError.NoRoom); }
	if (!ok(r)) { return Result.err(KeysError.EncodeFailed); }
	return Result.ok(written as int32);
}

export function freeKeys(this k: Keys): void {
	ghostty_key_event_free(k.event);
	ghostty_key_encoder_free(k.encoder);
}

const PASTE_END = "\x1b[201~";

export function pasteBytes(
	this vt: Vt,
	text: string,
	allowUnsafe: boolean,
): Result<Vec<uint8>, PasteError> {
	const mode = modeOn(vt.terminal, MODE_BRACKETED_PASTE);
	if (!mode.ok) { return Result.err(PasteError.ModeReadFailed); }
	const bracketed = mode.value;
	const unsafe = bracketed ? text.includes(PASTE_END) : !pasteSafe(text.asBytes());
	if (unsafe && !allowUnsafe) { return Result.err(PasteError.Unsafe); }
	let data: Vec<uint8> = [...text.asBytes()];
	let out: Vec<uint8> = new Array(data.length + 16);
	let written: size_t = 0;
	if (!ok(pasteEncode(data, bracketed, out, written))) {
		return Result.err(PasteError.EncodeFailed);
	}
	out.shrink(written as int32);
	return Result.ok(out);
}
