when (windows) {
	import { env, execFileCapture } from "std/process";
}

export interface Faces {
	regular: string;
	bold: string | null;
	italic: string | null;
	boldItalic: string | null;
}

const MACHINE_FONTS = "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
const USER_FONTS = "HKCU\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
const VALUE_SEPARATOR = "    REG_SZ    ";

function stripKind(name: string): string {
	const open = name.lastIndexOf(" (");
	return open > 0 && name.endsWith(")") ? name.slice(0, open) : name;
}

export function facesIn(listing: string, family: string, fontsDir: string): Result<Faces, string> {
	let regular: string | null = null;
	let bold: string | null = null;
	let italic: string | null = null;
	let boldItalic: string | null = null;
	for (const raw of listing.split("\n")) {
		const line = raw.trim();
		const at = line.indexOf(VALUE_SEPARATOR);
		if (at < 0) { continue; }
		const value = line.slice(at + VALUE_SEPARATOR.length).trim();
		const path = (value.indexOf(":") > 0 ? value : `${fontsDir}/${value}`).replaceAll("\\", "/");
		for (const name of stripKind(line.slice(0, at)).split(" & ")) {
			if (name == family || name == `${family} Regular`) { regular = regular ?? path; }
			if (name == `${family} Bold`) { bold = bold ?? path; }
			if (name == `${family} Italic`) { italic = italic ?? path; }
			if (name == `${family} Bold Italic`) { boldItalic = boldItalic ?? path; }
		}
	}
	if (regular === null) { return Result.err(`font family "${family}" is not installed`); }
	return Result.ok({ regular: regular, bold: bold, italic: italic, boldItalic: boldItalic });
}

export function installedFaces(family: string): Result<Faces, string> {
	when (windows) {
		let listing = "";
		for (const key of [USER_FONTS, MACHINE_FONTS]) {
			const out = execFileCapture("reg.exe", ["query", key]);
			if (out.ok) { listing += out.value; }
		}
		return facesIn(listing, family, `${env.get("WINDIR")}/Fonts`);
	} else {
		return Result.err(`font family "${family}" cannot be looked up: installed fonts are found by family on Windows only`);
	}
}

const LISTING = [
	"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
	"    Operator Saigon (TrueType)    REG_SZ    C:\\Fonts\\OperatorSaigon-Regular.otf",
	"    Operator Saigon Italic (TrueType)    REG_SZ    C:\\Fonts\\OperatorSaigon-Italic.otf",
	"    Operator Saigon Light (TrueType)    REG_SZ    C:\\Fonts\\OperatorSaigon-Light.otf",
	"    Segoe UI Bold (TrueType)    REG_SZ    segoeuib.ttf",
	"    Segoe UI (TrueType)    REG_SZ    segoeui.ttf",
	"    Segoe UI Bold Italic (TrueType)    REG_SZ    segoeuiz.ttf",
	"    Microsoft YaHei & Microsoft YaHei UI (TrueType)    REG_SZ    msyh.ttc",
	"",
].join("\r\n");

test "a family's faces come from the registry names, user fonts by full path" {
	const f = facesIn(LISTING, "Operator Saigon", "W:/Fonts");
	assert f.ok;
	assert f.value.regular == "C:/Fonts/OperatorSaigon-Regular.otf";
	assert f.value.italic == "C:/Fonts/OperatorSaigon-Italic.otf";
	assert f.value.bold === null;
	assert f.value.boldItalic === null;
}

test "machine fonts resolve in the fonts folder, and a collection answers each of its names" {
	const segoe = facesIn(LISTING, "Segoe UI", "W:/Fonts");
	assert segoe.ok;
	assert segoe.value.regular == "W:/Fonts/segoeui.ttf";
	assert segoe.value.bold == "W:/Fonts/segoeuib.ttf";
	assert segoe.value.boldItalic == "W:/Fonts/segoeuiz.ttf";
	const yahei = facesIn(LISTING, "Microsoft YaHei UI", "W:/Fonts");
	assert yahei.ok;
	assert yahei.value.regular == "W:/Fonts/msyh.ttc";
}

test "a family with no regular face is refused by name" {
	const missing = facesIn(LISTING, "Operator", "W:/Fonts");
	assert !missing.ok;
	if (!missing.ok) { assert missing.error == `font family "Operator" is not installed`; }
}
