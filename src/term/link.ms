import { chmod, exists, isDir, isFile, mkdir, realpath, removeAll, symlink, writeFile } from "std/fs";
import { hostname, tmpDir } from "std/os";
import { fileUri, isLocalHost } from "./pwd";

const MAX_URI_LENGTH: int32 = 2048;
const SCHEMES: string[] = ["http://", "https://"];
const PROGRAM_EXTENSIONS: string[] = [
	".app", ".command", ".tool", ".terminal", ".workflow", ".scpt", ".pkg", ".mpkg",
	".exe", ".com", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".msi", ".lnk", ".scr",
	".hta", ".wsf", ".jse", ".vbe", ".reg", ".dll", ".pif", ".jar", ".url", ".cpl", ".msc",
];

export enum LinkRefusal {
	NotALink,
	BadFileUri,
	RemoteHost,
	Missing,
	NotFileOrDirectory,
	StatFailed,
	ExecutePermission,
	RunsAsProgram,
}

export function refusalText(r: LinkRefusal): string {
	return match (r) {
		LinkRefusal.NotALink => "only http, https and local file links open",
		LinkRefusal.BadFileUri => "the file link is malformed",
		LinkRefusal.RemoteHost => "the file is on another machine",
		LinkRefusal.Missing => "no such file",
		LinkRefusal.NotFileOrDirectory => "neither a file nor a directory",
		LinkRefusal.StatFailed => "the file cannot be inspected",
		LinkRefusal.ExecutePermission => "the file has an execute permission bit",
		LinkRefusal.RunsAsProgram => "the file type runs as a program",
	};
}

function hasNoControlChars(text: string, first: int32): boolean {
	for (let i = 0; i < text.length; i++) {
		const c = text.charCodeAt(i);
		if (c < first || c == 0x7F) { return false; }
	}
	return true;
}

function extensionOf(path: string): string {
	let end = path.length;
	while (end > 0) {
		const c = path.charAt(end - 1);
		if (c != "/" && c != "\\" && c != "." && c != " ") { break; }
		end--;
	}
	let start = end;
	while (start > 0) {
		const c = path.charAt(start - 1);
		if (c == "/" || c == "\\") { break; }
		start--;
	}
	const dot = path.slice(start, end).lastIndexOf(".");
	return dot < 0 ? "" : path.slice(start + dot, end).toLowerCase();
}

function runsAsProgram(path: string): boolean {
	return PROGRAM_EXTENSIONS.includes(extensionOf(path)) ||
		PROGRAM_EXTENSIONS.includes(extensionOf(realpath(path)));
}

when (windows) {
	function hasExecuteBit(path: string): Result<boolean, LinkRefusal> { return Result.ok(false); }
} else {
	@include("sys/stat.h");

	extern struct Stat from "struct stat" { st_mode: uint32; }
	extern function cStat(path: cstring, ref buf: Stat): int32 from "stat";

	function hasExecuteBit(path: string): Result<boolean, LinkRefusal> {
		let st: Stat = {};
		if (cStat(path as cstring, st) != 0) { return Result.err(LinkRefusal.StatFailed); }
		return Result.ok((st.st_mode & 0o111) != 0);
	}
}

function fileRefusal(uri: string): LinkRefusal | null {
	const parsed = fileUri(uri);
	if (!parsed.ok) { return LinkRefusal.BadFileUri; }
	const path = parsed.value.path;
	if (!hasNoControlChars(path, 0x20)) { return LinkRefusal.BadFileUri; }
	if (!isLocalHost(parsed.value.host, hostname())) { return LinkRefusal.RemoteHost; }
	if (runsAsProgram(path)) { return LinkRefusal.RunsAsProgram; }
	if (!exists(path)) { return LinkRefusal.Missing; }
	if (!isFile(path) && !isDir(path)) { return LinkRefusal.NotFileOrDirectory; }
	const executable = hasExecuteBit(path);
	if (!executable.ok) { return executable.error; }
	if (isFile(path) && executable.value) { return LinkRefusal.ExecutePermission; }
	return null;
}

export function openable(uri: string): Result<void, LinkRefusal> {
	if (uri.length == 0 || uri.length > MAX_URI_LENGTH || !hasNoControlChars(uri, 0x21)) {
		return Result.err(LinkRefusal.NotALink);
	}
	const lower = uri.toLowerCase();
	if (lower.startsWith("file://")) {
		const refusal = fileRefusal(uri);
		if (refusal === null) { return Result.ok(null); }
		return Result.err(refusal);
	}
	for (const scheme of SCHEMES) {
		if (!lower.startsWith(scheme)) { continue; }
		const hostStart = lower.charAt(scheme.length);
		return match (hostStart) {
			"" | "/" | "?" | "#" => Result.err(LinkRefusal.NotALink),
			_ => Result.ok(null),
		};
	}
	return Result.err(LinkRefusal.NotALink);
}

function opens(uri: string): boolean {
	return openable(uri).ok;
}

function refusedFor(uri: string): LinkRefusal | null {
	const r = openable(uri);
	if (r.ok) { return null; }
	return r.error;
}

test "only http and https links with a host are opened" {
	assert opens("https://example.com/a?b=1");
	assert opens("HTTP://Example.com");
	assert opens("http://localhost:8080/");
	assert !opens("https://");
	assert !opens("https:///path");
	assert !opens("http://?q=1");
}

test "every other scheme is refused, the ones that run something included" {
	assert !opens("javascript:alert(1)");
	assert !opens("ms-msdt:/id");
	assert !opens("mailto:me@example.com");
	assert !opens("C:\\Windows\\notepad.exe");
	assert !opens("example.com");
	assert !opens("");
}

test "a link with whitespace or control characters is refused" {
	assert !opens("https://example.com/a b");
	assert !opens("https://example.com/\n");
	assert !opens("https://exa\x1bmple.com");
}

const SCRATCH = `${tmpDir()}/haroLinkTest`;

function scratch(): string {
	removeAll(SCRATCH);
	mkdir(SCRATCH);
	return SCRATCH;
}

test "a plain file and a plain directory open, by an empty or local host" {
	const dir = scratch();
	assert writeFile(`${dir}/note.txt`, "hi").ok;
	assert mkdir(`${dir}/plain`).ok;
	assert opens(`file://${dir}/note.txt`);
	assert opens(`file://localhost${dir}/note.txt`);
	assert opens(`file://LOCALHOST${dir}/plain`);
	assert opens(`file://${hostname()}${dir}/note.txt`);
	removeAll(dir);
}

test "a percent-encoded path is decoded before it is looked up" {
	const dir = scratch();
	assert writeFile(`${dir}/my note.txt`, "hi").ok;
	assert opens(`file://${dir}/my%20note.txt`);
	assert refusedFor(`file://${dir}/my%2Fnote.txt`) == LinkRefusal.Missing;
	assert refusedFor(`file://${dir}/my%00note.txt`) == LinkRefusal.BadFileUri;
	assert refusedFor(`file://${dir}/%zz`) == LinkRefusal.BadFileUri;
	removeAll(dir);
}

test "a file on another machine is refused although its path exists here" {
	const dir = scratch();
	assert writeFile(`${dir}/note.txt`, "hi").ok;
	assert refusedFor(`file://elsewhere.example${dir}/note.txt`) == LinkRefusal.RemoteHost;
	removeAll(dir);
}

test "a missing path is refused" {
	const dir = scratch();
	assert refusedFor(`file://${dir}/absent.txt`) == LinkRefusal.Missing;
	removeAll(dir);
}

when (!windows) {
	test "a file with an execute bit is refused, whichever class of user holds it" {
		const dir = scratch();
		const path = `${dir}/tool`;
		assert writeFile(path, "#!/bin/sh").ok;
		assert chmod(path, 0o755).ok;
		assert refusedFor(`file://${path}`) == LinkRefusal.ExecutePermission;
		assert chmod(path, 0o601).ok;
		assert refusedFor(`file://${path}`) == LinkRefusal.ExecutePermission;
		assert chmod(path, 0o644).ok;
		assert opens(`file://${path}`);
		removeAll(dir);
	}

	test "a link to a program is refused by what the link resolves to" {
		const dir = scratch();
		assert writeFile(`${dir}/run.command`, "echo").ok;
		assert symlink(`${dir}/run.command`, `${dir}/harmless`).ok;
		assert refusedFor(`file://${dir}/harmless`) == LinkRefusal.RunsAsProgram;
		removeAll(dir);
	}
}

test "a file type that launches as a program is refused by name, case aside, even when absent" {
	const dir = scratch();
	assert mkdir(`${dir}/x.app`).ok;
	assert writeFile(`${dir}/run.command`, "echo").ok;
	assert writeFile(`${dir}/SETUP.EXE`, "").ok;
	assert refusedFor(`file://${dir}/x.app`) == LinkRefusal.RunsAsProgram;
	assert refusedFor(`file://${dir}/x.app/`) == LinkRefusal.RunsAsProgram;
	assert refusedFor(`file://${dir}/run.command`) == LinkRefusal.RunsAsProgram;
	assert refusedFor(`file://${dir}/SETUP.EXE`) == LinkRefusal.RunsAsProgram;
	assert refusedFor(`file://${dir}/gone.Ps1`) == LinkRefusal.RunsAsProgram;
	assert refusedFor("file:///c:/x.exe") == LinkRefusal.RunsAsProgram;
	assert refusedFor("file:///c:/x.exe.") == LinkRefusal.RunsAsProgram;
	assert refusedFor("file:///c:/x.exe\\") == LinkRefusal.RunsAsProgram;
	assert refusedFor(`file://${dir}/x.apple`) == LinkRefusal.Missing;
	removeAll(dir);
}


test "the Windows file types that run on a double click are refused by name" {
	for (const ext of [".hta", ".wsf", ".jse", ".vbe", ".reg", ".dll", ".pif", ".jar", ".url", ".cpl", ".msc"]) {
		assert refusedFor(`file:///c:/x${ext}`) == LinkRefusal.RunsAsProgram;
	}
}

test "a file link needs a path" {
	assert refusedFor("file://") == LinkRefusal.BadFileUri;
	assert refusedFor("file://host") == LinkRefusal.BadFileUri;
}
