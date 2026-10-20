const FILE_SCHEME = "file://";

export struct FileUri {
	host: string;
	path: string;
}

function hexValue(c: int32): int32 | null {
	if (c >= "0".code && c <= "9".code) { return c - "0".code; }
	if (c >= "a".code && c <= "f".code) { return c - "a".code + 10; }
	if (c >= "A".code && c <= "F".code) { return c - "A".code + 10; }
	return null;
}

function percentDecoded(text: string): string | null {
	const bytes: Readonly<Span<char>> = text;
	const byteCount = text.byteLength as int32;
	let out: Vec<uint8> = [];
	let i = 0;
	while (i < byteCount) {
		const c = bytes[i] as int32;
		if (c != "%".code) {
			out.push(c as uint8);
			i++;
			continue;
		}
		if (i + 2 >= byteCount) { return null; }
		const hi = hexValue(bytes[i + 1] as int32);
		const lo = hexValue(bytes[i + 2] as int32);
		if (hi === null || lo === null) { return null; }
		out.push((hi * 16 + lo) as uint8);
		i += 3;
	}
	const decoded: string | null = out[0..(out.length as int32)].asString();
	return decoded;
}

function isAsciiLetter(c: int32): boolean {
	return (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code);
}

function withoutDriveSlash(path: string): string {
	if (path.length < 3 || path.charAt(0) != "/" || path.charAt(2) != ":") { return path; }
	return isAsciiLetter(path.charCodeAt(1)) ? path.slice(1, path.length) : path;
}

export function fileUri(uri: string): FileUri | null {
	if (!uri.startsWith(FILE_SCHEME)) { return null; }
	const afterScheme = uri.slice(FILE_SCHEME.length, uri.length);
	const slash = afterScheme.indexOf("/");
	if (slash < 0) { return null; }
	const path = percentDecoded(afterScheme.slice(slash, afterScheme.length));
	if (path === null) { return null; }
	const found: FileUri | null = { host: afterScheme.slice(0, slash), path: withoutDriveSlash(path) };
	return found;
}

export function isLocalHost(host: string, machine: string): boolean {
	const lower = host.toLowerCase();
	return lower == "" || lower == "localhost" || lower == machine.toLowerCase();
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
