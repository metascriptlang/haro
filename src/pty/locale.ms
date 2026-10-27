when (macos) {
	import { env } from "std/process";

	@passL("-framework CoreFoundation");
	@include("CoreFoundation/CoreFoundation.h");
	@include("xlocale.h");

	extern const kCFLocaleLanguageCode: Ptr<void> from "kCFLocaleLanguageCode";
	extern const kCFLocaleCountryCode: Ptr<void> from "kCFLocaleCountryCode";
	extern const LC_ALL_MASK: int32 from "LC_ALL_MASK";
	extern function CFLocaleCopyCurrent(): Ptr<void>;
	extern function CFLocaleGetValue(locale: Ptr<void>, key: Ptr<void>): Ptr<void> | null;
	extern function CFStringGetCString(s: Ptr<void>, buf: Span<uint8>, encoding: uint32): uint8;
	extern function CFRelease(object: Ptr<void>): void;
	extern function newlocale(mask: int32, name: cstring, base: Ptr<void> | null): Ptr<void> | null;
	extern function freelocale(locale: Ptr<void>): void;

	const UTF8: uint32 = 0x08000100;

	function localeText(locale: Ptr<void>, key: Ptr<void>): string {
		const value = CFLocaleGetValue(locale, key);
		let buf: Vec<uint8> = new Array(64);
		if (value === null || CFStringGetCString(value, buf, UTF8) == 0) { return ""; }
		let n = 0;
		while (buf[n] != 0) { n++; }
		return buf[0..n].asString();
	}

	export function installed(name: string): boolean {
		const locale = newlocale(LC_ALL_MASK, name, null);
		if (locale === null) { return false; }
		freelocale(locale);
		return true;
	}

	const FALLBACK_LANG = "en_US.UTF-8";

	export function utf8Locale(language: string, region: string): string {
		const name = `${language}_${region}.UTF-8`;
		return installed(name) ? name : FALLBACK_LANG;
	}

	export function preferredLang(): string {
		const current = CFLocaleCopyCurrent();
		const language = localeText(current, kCFLocaleLanguageCode);
		const region = localeText(current, kCFLocaleCountryCode);
		CFRelease(current);
		return utf8Locale(language, region);
	}
}

export function langEntry(): string {
	when (macos) {
		if (env.get("LANG") == "") { return `LANG=${preferredLang()}`; }
	}
	return "";
}
