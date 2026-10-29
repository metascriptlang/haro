import { Rgb } from "../vt/vt";

export const DEFAULT_FG: Rgb = { r: 12, g: 34, b: 56 };
export const DEFAULT_BG: Rgb = { r: 65, g: 43, b: 21 };
const HEX = "0123456789abcdef";
const DEFAULT_NAMED: uint32[] = [
	0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
	0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
];

export function rgb(r: int32, g: int32, b: int32): Rgb {
	return { r: r as uint8, g: g as uint8, b: b as uint8 };
}

function hexDigits(channel: uint8): string {
	const n = channel as int32;
	return HEX[n >> 4] + HEX[n & 15];
}

function hexChannel(text: string, at: int32): int32 {
	return HEX.indexOf(text[at]) * 16 + HEX.indexOf(text[at + 1]);
}

function isHexDigits(text: string, from: int32, to: int32): boolean {
	for (let i = from; i < to; i++) {
		if (HEX.indexOf(text[i]) < 0) { return false; }
	}
	return true;
}

export function cssHex(c: Rgb): string {
	return "#" + hexDigits(c.r) + hexDigits(c.g) + hexDigits(c.b);
}

export function fromCssHex(text: string): Result<Rgb, string> {
	if (text.length != 7 || text[0] != "#" || !isHexDigits(text, 1, 7)) {
		return Result.err(`"${text}" is not a #rrggbb colour in lower-case hex`);
	}
	return Result.ok(rgb(hexChannel(text, 1), hexChannel(text, 3), hexChannel(text, 5)));
}

function oscRgb(c: Rgb): string {
	return `rgb:${hexDigits(c.r)}/${hexDigits(c.g)}/${hexDigits(c.b)}`;
}

function ownIndexed(index: uint8): Rgb {
	const n = index as int32;
	return rgb(n, (n * 7 + 31) % 256, 255 - n);
}

function cubeLevel(v: int32): uint8 {
	return (v == 0 ? 0 : v * 40 + 55) as uint8;
}

export function defaultIndexed(index: uint8): Rgb {
	const n = index as int32;
	if (n < 16) {
		const c = DEFAULT_NAMED[n];
		return {
			r: ((c >> 16) & 255) as uint8,
			g: ((c >> 8) & 255) as uint8,
			b: (c & 255) as uint8,
		};
	}
	if (n < 232) {
		const k = n - 16;
		return { r: cubeLevel(k / 36), g: cubeLevel((k / 6) % 6), b: cubeLevel(k % 6) };
	}
	const gray = ((n - 232) * 10 + 8) as uint8;
	return { r: gray, g: gray, b: gray };
}

export function indexed(n: uint8, own: boolean): Rgb {
	return own ? ownIndexed(n) : defaultIndexed(n);
}

export function palettePrelude(own: boolean): string {
	let out = "";
	if (own) {
		for (let n = 0; n < 256; n++) {
			out += `\x1b]4;${n};${oscRgb(ownIndexed(n as uint8))}\x07`;
		}
	}
	return out + `\x1b]10;${oscRgb(DEFAULT_FG)}\x07\x1b]11;${oscRgb(DEFAULT_BG)}\x07`;
}
