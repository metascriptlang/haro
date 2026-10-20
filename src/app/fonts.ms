import { resourcePath } from "../../../ion/src/index";
import { FontStyle, registerFace } from "../../../void/src/void2d/font";
import { env } from "std/process";
import { Faces } from "../config/fonts";

const ASSETS = resourcePath() == "" ? "assets" : `${resourcePath().replaceAll("\\", "/")}/assets`;
const FONT_REGULAR = `${ASSETS}/JetBrainsMonoNL-Regular.ttf`;
const FONT_BOLD = `${ASSETS}/JetBrainsMonoNL-Bold.ttf`;
const FONT_ITALIC = `${ASSETS}/JetBrainsMonoNL-Italic.ttf`;
const FONT_BOLD_ITALIC = `${ASSETS}/JetBrainsMonoNL-BoldItalic.ttf`;

interface SystemFace {
	path: string;
	family: string;
}

when (windows) {
	function fallbackFaces(): SystemFace[] {
		const fonts = `${env.get("WINDIR")}/Fonts`;
		return [
			{ path: `${fonts}/seguiemj.ttf`, family: "Segoe UI Emoji" },
			{ path: `${fonts}/seguisym.ttf`, family: "Segoe UI Symbol" },
			{ path: `${fonts}/msyh.ttc`, family: "Microsoft YaHei" },
		];
	}
} else when (macos) {
	function fallbackFaces(): SystemFace[] {
		return [
			{ path: "/System/Library/Fonts/Apple Color Emoji.ttc", family: "Apple Color Emoji" },
			{ path: "/System/Library/Fonts/Apple Symbols.ttf", family: "Apple Symbols" },
			{ path: "/System/Library/Fonts/Hiragino Sans GB.ttc", family: "Hiragino Sans GB" },
		];
	}
} else {
	function fallbackFaces(): SystemFace[] {
		return [];
	}
}

function registerBuiltIn(): void {
	registerFace(FONT_BOLD, FONT_REGULAR, 700, FontStyle.Normal);
	registerFace(FONT_ITALIC, FONT_REGULAR, 400, FontStyle.Italic);
	registerFace(FONT_BOLD_ITALIC, FONT_REGULAR, 700, FontStyle.Italic);
	registerFace(FONT_REGULAR, FONT_REGULAR, 400, FontStyle.Normal);
}

function registerFamily(faces: Faces): string {
	const family = faces.regular;
	const bold = faces.bold;
	const italic = faces.italic;
	const boldItalic = faces.boldItalic;
	registerFace(family, family, 400, FontStyle.Normal);
	if (bold !== null) { registerFace(bold, family, 700, FontStyle.Normal); }
	if (italic !== null) { registerFace(italic, family, 400, FontStyle.Italic); }
	if (boldItalic !== null) { registerFace(boldItalic, family, 700, FontStyle.Italic); }
	return family;
}

export function registerFonts(configured: Vec<Faces>): string[] {
	registerBuiltIn();
	let families: string[] = [];
	for (const faces of configured) { families.push(registerFamily(faces)); }
	families.push(FONT_REGULAR);
	for (const face of fallbackFaces()) {
		registerFace(face.path, face.family, 400, FontStyle.Normal);
		families.push(face.family);
	}
	return families;
}
