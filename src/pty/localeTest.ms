when (macos) {
	import { installed, preferredLang, utf8Locale } from "./locale";
}

test "a language and region with an installed UTF-8 locale name that locale" {
	assert utf8Locale("fr", "FR") == "fr_FR.UTF-8";
	assert utf8Locale("zh", "CN") == "zh_CN.UTF-8";
}

test "a language and region with no installed locale fall back to US English" {
	assert utf8Locale("en", "VN") == "en_US.UTF-8";
	assert utf8Locale("", "") == "en_US.UTF-8";
}

test "the macOS locale preference maps to an installed UTF-8 locale" {
	const lang = preferredLang();
	assert lang.endsWith(".UTF-8");
	assert installed(lang);
}
