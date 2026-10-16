export struct FileUri {
	host: string;
	path: string;
}

function hexValue(c: int32): int32 {
	if (c >= 0x30 && c <= 0x39) { return c - 0x30; }
	if (c >= 0x61 && c <= 0x66) { return c - 0x61 + 10; }
	if (c >= 0x41 && c <= 0x46) { return c - 0x41 + 10; }
	return -1;
}

function unescape(text: string): string | null {
	const src: Readonly<Span<char>> = text;
	const n = text.byteLength as int32;
	let out: Vec<uint8> = [];
	let i = 0;
	while (i < n) {
		const c = src[i] as int32;
		if (c != 0x25) {
			out.push(c as uint8);
			i++;
			continue;
		}
		if (i + 2 >= n) { return null; }
		const hi = hexValue(src[i + 1] as int32);
		const lo = hexValue(src[i + 2] as int32);
		if (hi < 0 || lo < 0) { return null; }
		out.push((hi * 16 + lo) as uint8);
		i += 3;
	}
	const decoded: string | null = out[0..(out.length as int32)].asString();
	return decoded;
}

function drivePath(path: string): string {
	const letter = path.charCodeAt(1);
	const isLetter = (letter >= 0x41 && letter <= 0x5A) || (letter >= 0x61 && letter <= 0x7A);
	if (path.length >= 3 && path.charCodeAt(0) == 0x2F && isLetter && path.charAt(2) == ":") {
		return path.slice(1, path.length);
	}
	return path;
}

export function fileUri(uri: string): FileUri | null {
	if (!uri.startsWith("file://")) { return null; }
	const rest = uri.slice(7, uri.length);
	const slash = rest.indexOf("/");
	if (slash < 0) { return null; }
	const path = unescape(rest.slice(slash, rest.length));
	if (path === null) { return null; }
	const found: FileUri | null = { host: rest.slice(0, slash), path: drivePath(path) };
	return found;
}

export function isLocalHost(host: string, machine: string): boolean {
	if (host == "" || host.toLowerCase() == "localhost") { return true; }
	return host.toLowerCase() == machine.toLowerCase();
}

test "a POSIX file URI gives its path with escapes decoded" {
	const u = fileUri("file://box/home/me/my%20dir");
	assert u !== null;
	if (u !== null) {
		assert u.host == "box";
		assert u.path == "/home/me/my dir";
	}
}

test "a Windows file URI loses the slash before its drive letter" {
	const u = fileUri("file:///C:/Users/me/%E1%BB%87");
	assert u !== null;
	if (u !== null) {
		assert u.host == "";
		assert u.path == "C:/Users/me/ệ";
	}
}

test "anything but a file URI with a path is refused" {
	assert fileUri("http://example.com/a") === null;
	assert fileUri("file://box") === null;
	assert fileUri("file:///a/%zz") === null;
	assert fileUri("file:///a/%4") === null;
	assert fileUri("") === null;
}

test "only an empty, localhost or this machine's host is local" {
	assert isLocalHost("", "Box");
	assert isLocalHost("LOCALHOST", "Box");
	assert isLocalHost("box", "Box");
	assert !isLocalHost("other", "Box");
}
