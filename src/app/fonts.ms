import { resourcePath } from "../../../ion/src/index";
import { FontStyle, registerFace } from "../../../void/src/void2d/font";
import { Faces } from "../config/fonts";

const ASSETS = resourcePath() == "" ? "assets" : `${resourcePath().replaceAll("\\", "/")}/assets`;
const FONT_REGULAR = `${ASSETS}/JetBrainsMonoNL-Regular.ttf`;
const FONT_BOLD = `${ASSETS}/JetBrainsMonoNL-Bold.ttf`;
const FONT_ITALIC = `${ASSETS}/JetBrainsMonoNL-Italic.ttf`;
const FONT_BOLD_ITALIC = `${ASSETS}/JetBrainsMonoNL-BoldItalic.ttf`;
const BUILT_IN: Faces = {
	regular: FONT_REGULAR,
	bold: FONT_BOLD,
	italic: FONT_ITALIC,
	boldItalic: FONT_BOLD_ITALIC,
};

struct SystemFace {
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
} else {
	function fallbackFaces(): SystemFace[] {
		return [];
	}
}

let registeredFamilies: string[] = [];
let fallbackFamilies: string[] = [];

function registerFamily(this faces: Faces): string {
	const family = faces.regular;
	if (registeredFamilies.includes(family)) { return family; }
	registeredFamilies.push(family);
	const bold = faces.bold;
	const italic = faces.italic;
	const boldItalic = faces.boldItalic;
	registerFace(family, family, 400, FontStyle.Normal);
	if (bold !== null) { registerFace(bold, family, 700, FontStyle.Normal); }
	if (italic !== null) { registerFace(italic, family, 400, FontStyle.Italic); }
	if (boldItalic !== null) { registerFace(boldItalic, family, 700, FontStyle.Italic); }
	return family;
}

export function registerFallbacks(): void {
	fallbackFamilies.push(BUILT_IN.registerFamily());
	for (const face of fallbackFaces()) {
		registerFace(face.path, face.family, 400, FontStyle.Normal);
		fallbackFamilies.push(face.family);
	}
}

export function familyList(configured: Readonly<Span<Faces>>): string[] {
	let families: string[] = [];
	for (const faces of configured) { families.push(faces.registerFamily()); }
	for (const family of fallbackFamilies) { families.push(family); }
	return families;
}
