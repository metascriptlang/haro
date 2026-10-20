import { Rgb } from "../vt/vt";

export const DEFAULT_FG: Rgb = { r: 12, g: 34, b: 56 };
export const DEFAULT_BG: Rgb = { r: 65, g: 43, b: 21 };
export const HEX = "0123456789abcdef";
const DEFAULT_NAMED: uint32[] = [
	0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
	0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
];

function hex2(n: int32): string {
	return HEX[n >> 4] + HEX[n & 15];
}

export function ownIndexed(n: int32): Rgb {
	return { r: n as uint8, g: ((n * 7 + 31) % 256) as uint8, b: (255 - n) as uint8 };
}

function cubeLevel(v: int32): uint8 {
	return (v == 0 ? 0 : v * 40 + 55) as uint8;
}

export function defaultIndexed(n: int32): Rgb {
	if (n < 16) {
		const c = DEFAULT_NAMED[n];
		return { r: ((c >> 16) & 255) as uint8, g: ((c >> 8) & 255) as uint8, b: (c & 255) as uint8 };
	}
	if (n < 232) {
		const k = n - 16;
		return { r: cubeLevel(k / 36), g: cubeLevel((k / 6) % 6), b: cubeLevel(k % 6) };
	}
	const gray = ((n - 232) * 10 + 8) as uint8;
	return { r: gray, g: gray, b: gray };
}

export function palettePrelude(own: boolean): string {
	let out = "";
	for (let n = 0; own && n < 256; n++) {
		const c = ownIndexed(n);
		out += `\x1b]4;${n};rgb:${hex2(c.r as int32)}/${hex2(c.g as int32)}/${hex2(c.b as int32)}\x07`;
	}
	out += `\x1b]10;rgb:${hex2(DEFAULT_FG.r as int32)}/${hex2(DEFAULT_FG.g as int32)}/${hex2(DEFAULT_FG.b as int32)}\x07`;
	out += `\x1b]11;rgb:${hex2(DEFAULT_BG.r as int32)}/${hex2(DEFAULT_BG.g as int32)}/${hex2(DEFAULT_BG.b as int32)}\x07`;
	return out;
}
