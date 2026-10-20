const MAX_URI_LENGTH: int32 = 2048;
const SCHEMES = ["http://", "https://"];

export function openable(uri: string): boolean {
	if (uri.length == 0 || uri.length > MAX_URI_LENGTH) { return false; }
	for (let i = 0; i < uri.length; i++) {
		const c = uri.charCodeAt(i);
		if (c <= 0x20 || c == 0x7F) { return false; }
	}
	const lower = uri.toLowerCase();
	for (const scheme of SCHEMES) {
		if (!lower.startsWith(scheme)) { continue; }
		const hostStart = lower.charAt(scheme.length);
		return hostStart != "" && hostStart != "/" && hostStart != "?" && hostStart != "#";
	}
	return false;
}

test "only http and https links with a host are opened" {
	assert openable("https://example.com/a?b=1");
	assert openable("HTTP://Example.com");
	assert openable("http://localhost:8080/");
	assert !openable("https://");
	assert !openable("https:///path");
	assert !openable("http://?q=1");
}

test "every other scheme is refused, the ones that run something included" {
	assert !openable("file:///C:/Windows/System32/calc.exe");
	assert !openable("javascript:alert(1)");
	assert !openable("ms-msdt:/id");
	assert !openable("mailto:me@example.com");
	assert !openable("C:\\Windows\\notepad.exe");
	assert !openable("example.com");
	assert !openable("");
}

test "a link with whitespace or control characters is refused" {
	assert !openable("https://example.com/a b");
	assert !openable("https://example.com/\n");
	assert !openable("https://exa\x1bmple.com");
}
