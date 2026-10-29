import { pushAll } from "./vtNative";

const REPLACEMENT_CHARACTER = "\u{fffd}";
const LONGEST_UTF8_BYTES = 4;

function wellFormedLength(bytes: Readonly<Span<uint8>>, at: int32, end: int32): int32 {
	const lead = bytes[at] as int32;
	if (lead < 0x80) { return 1; }
	let width = 0;
	if (lead >= 0xc2 && lead <= 0xdf) { width = 2; }
	if (lead >= 0xe0 && lead <= 0xef) { width = 3; }
	if (lead >= 0xf0 && lead <= 0xf4) { width = 4; }
	if (width == 0 || at + width > end) { return 0; }
	const low = lead == 0xe0 ? 0xa0 : lead == 0xf0 ? 0x90 : 0x80;
	const high = lead == 0xed ? 0x9f : lead == 0xf4 ? 0x8f : 0xbf;
	const second = bytes[at + 1] as int32;
	if (second < low || second > high) { return 0; }
	for (let i = 2; i < width; i++) {
		const next = bytes[at + i] as int32;
		if (next < 0x80 || next > 0xbf) { return 0; }
	}
	return width;
}

export function wellFormedPrefix(bytes: Readonly<Span<uint8>>, maxBytes: int32): string {
	const scan = maxBytes + LONGEST_UTF8_BYTES;
	const end = bytes.length < scan ? bytes.length as int32 : scan;
	const replacement = REPLACEMENT_CHARACTER.asBytes();
	let out: Vec<uint8> = [];
	let at = 0;
	while (at < end) {
		const width = wellFormedLength(bytes, at, end);
		const size = width == 0 ? replacement.length as int32 : width;
		if (out.length + size > maxBytes) { break; }
		if (width == 0) {
			pushAll(out, replacement);
		} else {
			pushAll(out, bytes[at..at + width]);
		}
		at += Math.max(width, 1);
	}
	return out[0..out.length].asString();
}

export function wellFormed(bytes: Readonly<Span<uint8>>): string {
	return wellFormedPrefix(bytes, (bytes.length as int32) * 3);
}
