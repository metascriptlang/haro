when (windows) {
	import { env, execFileCapture } from "std/process";
} else when (macos) {
	@passL("-framework CoreText -framework CoreFoundation");
	@include("CoreText/CoreText.h");

	extern const kCTFontFamilyNameAttribute: Ptr<void> from "kCTFontFamilyNameAttribute";
	extern const kCTFontStyleNameAttribute: Ptr<void> from "kCTFontStyleNameAttribute";
	extern const kCTFontURLAttribute: Ptr<void> from "kCTFontURLAttribute";
	extern function CTFontCollectionCreateFromAvailableFonts(options: Ptr<void> | null): Ptr<void>;
	extern function CTFontCollectionCreateMatchingFontDescriptors(collection: Ptr<void>): Ptr<void> | null;
	extern function CTFontDescriptorCopyAttribute(descriptor: Ptr<void>, attribute: Ptr<void>): Ptr<void> | null;
	extern function CFArrayGetCount(array: Ptr<void>): int64;
	extern function CFArrayGetValueAtIndex(array: Ptr<void>, index: int64): Ptr<void>;
	extern function CFGetTypeID(object: Ptr<void>): uint64;
	extern function CFStringGetTypeID(): uint64;
	extern function CFURLGetTypeID(): uint64;
	extern function CFStringGetCString(s: Ptr<void>, buf: Span<uint8>, encoding: uint32): uint8;
	extern function CFURLGetFileSystemRepresentation(url: Ptr<void>, resolve: uint8, buf: Span<uint8>): uint8;
	extern function CFRelease(object: Ptr<void>): void;

	const UTF8: uint32 = 0x08000100;

	function untilNul(buf: Vec<uint8>): string {
		let n = 0;
		while (buf[n] != 0) { n++; }
		return buf[0..n].asString();
	}

	function attributeText(descriptor: Ptr<void>, attribute: Ptr<void>): string | null {
		const value = CTFontDescriptorCopyAttribute(descriptor, attribute);
		if (value === null) { return null; }
		let buf: Vec<uint8> = new Array(1024);
		const ok = CFGetTypeID(value) == CFStringGetTypeID() && CFStringGetCString(value, buf, UTF8) != 0;
		CFRelease(value);
		return ok ? untilNul(buf) : null;
	}

	function attributePath(descriptor: Ptr<void>): string | null {
		const url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute);
		if (url === null) { return null; }
		let buf: Vec<uint8> = new Array(4096);
		const ok = CFGetTypeID(url) == CFURLGetTypeID() && CFURLGetFileSystemRepresentation(url, 1, buf) != 0;
		CFRelease(url);
		return ok ? untilNul(buf) : null;
	}

	function familyFiles(family: string): Vec<FontFile> {
		let files: Vec<FontFile> = [];
		const all = CTFontCollectionCreateFromAvailableFonts(null);
		const found = CTFontCollectionCreateMatchingFontDescriptors(all);
		if (found !== null) {
			for (let i: int64 = 0; i < CFArrayGetCount(found); i++) {
				const d = CFArrayGetValueAtIndex(found, i);
				if (attributeText(d, kCTFontFamilyNameAttribute) != family) { continue; }
				const style = attributeText(d, kCTFontStyleNameAttribute);
				const path = attributePath(d);
				if (style !== null && path !== null) { files.push({ name: `${family} ${style}`, path: path }); }
			}
			CFRelease(found);
		}
		CFRelease(all);
		return files;
	}
}

export interface Faces {
	regular: string;
	bold: string | null;
	italic: string | null;
	boldItalic: string | null;
}

export interface FontFile {
	name: string;
	path: string;
}

const MACHINE_FONTS = "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
const USER_FONTS = "HKCU\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
const VALUE_SEPARATOR = "    REG_SZ    ";

function stripKind(name: string): string {
	const open = name.lastIndexOf(" (");
	return open > 0 && name.endsWith(")") ? name.slice(0, open) : name;
}

function registryFiles(listing: string, fontsDir: string): Vec<FontFile> {
	let files: Vec<FontFile> = [];
	for (const raw of listing.split("\n")) {
		const line = raw.trim();
		const at = line.indexOf(VALUE_SEPARATOR);
		if (at < 0) { continue; }
		const value = line.slice(at + VALUE_SEPARATOR.length).trim();
		const path = (value.indexOf(":") > 0 ? value : `${fontsDir}/${value}`).replaceAll("\\", "/");
		for (const name of stripKind(line.slice(0, at)).split(" & ")) { files.push({ name: name, path: path }); }
	}
	return files;
}

export function facesAmong(files: Vec<FontFile>, family: string): Result<Faces, string> {
	let regular: string | null = null;
	let bold: string | null = null;
	let italic: string | null = null;
	let boldItalic: string | null = null;
	for (const f of files) {
		if (f.name == family || f.name == `${family} Regular`) { regular = regular ?? f.path; }
		if (f.name == `${family} Bold`) { bold = bold ?? f.path; }
		if (f.name == `${family} Italic`) { italic = italic ?? f.path; }
		if (f.name == `${family} Bold Italic`) { boldItalic = boldItalic ?? f.path; }
	}
	if (regular === null) { return Result.err(`font family "${family}" is not installed`); }
	return Result.ok({ regular: regular, bold: bold, italic: italic, boldItalic: boldItalic });
}

export function facesIn(listing: string, family: string, fontsDir: string): Result<Faces, string> {
	return facesAmong(registryFiles(listing, fontsDir), family);
}

function collectionIn(faces: Faces): string | null {
	for (const path of [faces.regular, faces.bold, faces.italic, faces.boldItalic]) {
		if (path !== null && (path.toLowerCase().endsWith(".ttc") || path.toLowerCase().endsWith(".otc"))) { return path; }
	}
	return null;
}

export function installedFaces(family: string): Result<Faces, string> {
	when (windows) {
		let listing = "";
		for (const key of [USER_FONTS, MACHINE_FONTS]) {
			const out = execFileCapture("reg.exe", ["query", key]);
			if (out.ok) { listing += out.value; }
		}
		return facesIn(listing, family, `${env.get("WINDIR")}/Fonts`);
	} else when (macos) {
		const faces = try facesAmong(familyFiles(family), family);
		const collection = collectionIn(faces);
		if (collection !== null) {
			return Result.err(`font family "${family}" is in the collection ${collection}, and Haro cannot pick a face out of one yet`);
		}
		return Result.ok(faces);
	} else {
		return Result.err(`font family "${family}" cannot be looked up: installed fonts are found by family on Windows and macOS only`);
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

test "a face inside a font collection is found, so the lookup can refuse it by path" {
	const f = facesAmong([{ name: "Menlo Regular", path: "/System/Library/Fonts/Menlo.ttc" }], "Menlo");
	assert f.ok;
	assert collectionIn(f.value) == "/System/Library/Fonts/Menlo.ttc";
}

when (macos) {
	test "an installed family's files come from CoreText, and a missing one is refused" {
		const symbols = installedFaces("Apple Symbols");
		assert symbols.ok;
		if (symbols.ok) { assert symbols.value.regular == "/System/Library/Fonts/Apple Symbols.ttf"; }
		assert !installedFaces("No Such Family Haro").ok;
	}
}
