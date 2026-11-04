import { JSON, JsonKind, JsonValue } from "std/core/json";
import { readFile } from "std/fs";
import {
	ChildProcess,
	ChildStream,
	ProcessError,
	ProcessErrorKind,
	spawn,
} from "std/process";

export enum TailnetFault {
	CliMissing,
	NotRunning,
	CliFailed,
	Timeout,
	BadOutput,
	NotTailnetAddress,
	UnknownPeer,
	OtherUser,
}

export struct TailnetError {
	fault: TailnetFault;
	detail: string;
}

export struct TailnetSelf {
	ipv4: string;
	ipv6: string | null;
	userId: int64;
	loginName: string;
	hostName: string;
}

export struct PeerInfo {
	userId: int64;
	loginName: string;
	hostName: string;
	os: string;
}

export struct TailnetPeer {
	hostName: string;
	address: string;
	os: string;
}

const CLI_TIMEOUT_MS: int32 = 5000;

function failure(fault: TailnetFault, detail: string): TailnetError {
	return { fault: fault, detail: detail };
}

// macOS starts a window from Finder or the Dock with
// PATH=/usr/bin:/bin:/usr/sbin:/sbin, which holds no Tailscale CLI.
function installedClis(): string[] {
	when (macos) {
		return [
			"tailscale",
			"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
			"/opt/homebrew/bin/tailscale",
			"/usr/local/bin/tailscale",
		];
	} else when (windows) {
		return ["tailscale", "C:\\Program Files\\Tailscale\\tailscale.exe"];
	} else {
		return ["tailscale"];
	}
}

function processFailure(e: ProcessError): TailnetError {
	return match (e.kind) {
		ProcessErrorKind.Timeout => failure(TailnetFault.Timeout, e.message),
		_ => failure(TailnetFault.CliFailed, e.message),
	};
}

function msLeft(deadline: float64): int32 {
	return Math.max(0, deadline - performance.now()) as int32;
}

function drain(
	child: ChildProcess,
	stream: ChildStream,
	deadline: float64,
): Result<string, TailnetError> {
	let text = "";
	while (true) {
		const got = child.read(stream, msLeft(deadline));
		if (!got.ok) {
			return Result.err(processFailure(got.error));
		}
		if (got.value.ended) {
			return Result.ok(text);
		}
		text += got.value.data;
	}
}

function collect(
	child: ChildProcess,
	timeoutMs: int32,
): Result<string, TailnetError> {
	const deadline = performance.now() + timeoutMs;
	const out = drain(child, ChildStream.Stdout, deadline);
	const errors = drain(child, ChildStream.Stderr, deadline);
	const status = out.ok && errors.ok ? child.wait(msLeft(deadline)) : null;
	child.close();
	if (!out.ok) {
		return Result.err(out.error);
	}
	if (!errors.ok) {
		return Result.err(errors.error);
	}
	if (status === null) {
		return Result.err(failure(TailnetFault.CliFailed, "no status"));
	}
	if (!status.ok) {
		return Result.err(processFailure(status.error));
	}
	const code = status.value.code;
	if (code != 0 || status.value.signal != 0) {
		const said = errors.value.trim();
		return Result.err(
			failure(
				TailnetFault.CliFailed,
				said != "" ? said : `${child.command} exited with ${code}`,
			),
		);
	}
	return Result.ok(out.value);
}

function runCli(
	programs: string[],
	args: string[],
	timeoutMs: int32,
): Result<string, TailnetError> {
	for (const program of programs) {
		const started = spawn(program, args);
		if (started.ok) {
			return collect(started.value, timeoutMs);
		}
		if (started.error.kind != ProcessErrorKind.NotFound) {
			return Result.err(failure(TailnetFault.CliFailed, started.error.message));
		}
	}
	return Result.err(
		failure(
			TailnetFault.CliMissing,
			`no Tailscale CLI found: tried ${programs.join(", ")}`,
		),
	);
}

function badOutput(detail: string): TailnetError {
	return failure(TailnetFault.BadOutput, detail);
}

function parsed(text: string, what: string): Result<JsonValue, TailnetError> {
	const value = JSON.parseValue(text);
	if (!value.ok) {
		return Result.err(badOutput(`${what} is not JSON: ${value.error}`));
	}
	return Result.ok(value.value);
}

function fieldOrNull(
	v: JsonValue,
	path: string,
	name: string,
): Result<JsonValue | null, TailnetError> {
	if (v.kind != JsonKind.Object) {
		return Result.err(badOutput(`${path} is not an object`));
	}
	for (let i = 0; i < v.keys.length; i++) {
		if (v.keys[i] == name) {
			return Result.ok(v.values[i]);
		}
	}
	return Result.ok(null);
}

function field(
	v: JsonValue,
	path: string,
	name: string,
): Result<JsonValue, TailnetError> {
	const found = try fieldOrNull(v, path, name);
	if (found === null) {
		return Result.err(badOutput(`${path}.${name} is missing`));
	}
	return Result.ok(found);
}

function text(
	v: JsonValue,
	path: string,
	name: string,
): Result<string, TailnetError> {
	const found = try field(v, path, name);
	if (found.kind != JsonKind.String) {
		return Result.err(badOutput(`${path}.${name} is not a string`));
	}
	return Result.ok(found.strVal);
}

function textOrEmpty(
	v: JsonValue,
	path: string,
	name: string,
): Result<string, TailnetError> {
	const found = try fieldOrNull(v, path, name);
	if (found === null || found.kind == JsonKind.Null) {
		return Result.ok("");
	}
	if (found.kind != JsonKind.String) {
		return Result.err(badOutput(`${path}.${name} is not a string`));
	}
	return Result.ok(found.strVal);
}

function integer(
	v: JsonValue,
	path: string,
	name: string,
): Result<int64, TailnetError> {
	const found = try field(v, path, name);
	if (found.kind != JsonKind.Int) {
		return Result.err(badOutput(`${path}.${name} is not an integer`));
	}
	return Result.ok(found.intVal);
}

function flag(
	v: JsonValue,
	path: string,
	name: string,
): Result<boolean, TailnetError> {
	const found = try field(v, path, name);
	if (found.kind != JsonKind.Bool) {
		return Result.err(badOutput(`${path}.${name} is not true or false`));
	}
	return Result.ok(found.boolVal);
}

function textList(
	v: JsonValue,
	path: string,
	name: string,
): Result<Vec<string>, TailnetError> {
	const found = try field(v, path, name);
	if (found.kind != JsonKind.Array) {
		return Result.err(badOutput(`${path}.${name} is not a list`));
	}
	let out: Vec<string> = [];
	for (const item of found.items) {
		if (item.kind != JsonKind.String) {
			return Result.err(badOutput(`${path}.${name} holds a non-string`));
		}
		out.push(item.strVal);
	}
	return Result.ok(out);
}

function firstAddress(ips: Vec<string>, ipv6: boolean): string | null {
	for (const ip of ips) {
		if (ip.includes(":") == ipv6) {
			return ip;
		}
	}
	return null;
}

function selfFromStatus(status: JsonValue): Result<TailnetSelf, TailnetError> {
	const state = try text(status, "status", "BackendState");
	if (state != "Running") {
		return Result.err(
			failure(
				TailnetFault.NotRunning,
				`Tailscale is not running (state ${state})`,
			),
		);
	}
	const me = try field(status, "status", "Self");
	const ips = try textList(me, "Self", "TailscaleIPs");
	const ipv4 = firstAddress(ips, false);
	if (ipv4 === null) {
		return Result.err(badOutput("Self.TailscaleIPs holds no IPv4"));
	}
	const userId = try integer(me, "Self", "UserID");
	const users = try field(status, "status", "User");
	const user = try field(users, "User", userId.toString());
	return Result.ok({
		ipv4: ipv4,
		ipv6: firstAddress(ips, true),
		userId: userId,
		loginName: try text(user, `User.${userId}`, "LoginName"),
		hostName: try text(me, "Self", "HostName"),
	});
}

function peersFromStatus(
	status: JsonValue,
	self: TailnetSelf,
): Result<Vec<TailnetPeer>, TailnetError> {
	let out: Vec<TailnetPeer> = [];
	const all = try fieldOrNull(status, "status", "Peer");
	if (all === null || all.kind == JsonKind.Null) {
		return Result.ok(out);
	}
	if (all.kind != JsonKind.Object) {
		return Result.err(badOutput("status.Peer is not an object"));
	}
	for (let i = 0; i < all.keys.length; i++) {
		const path = `Peer[${all.keys[i]}]`;
		const peer = all.values[i];
		const mine = (try integer(peer, path, "UserID")) == self.userId;
		if (!mine || !(try flag(peer, path, "Online"))) {
			continue;
		}
		const ips = try textList(peer, path, "TailscaleIPs");
		const address = firstAddress(ips, false) ?? firstAddress(ips, true);
		if (address === null) {
			return Result.err(badOutput(`${path}.TailscaleIPs is empty`));
		}
		out.push({
			hostName: try text(peer, path, "HostName"),
			address: address,
			os: try textOrEmpty(peer, path, "OS"),
		});
	}
	return Result.ok(out);
}

function peerFromWhois(whois: JsonValue): Result<PeerInfo, TailnetError> {
	const node = try field(whois, "whois", "Node");
	const profile = try field(whois, "whois", "UserProfile");
	const nodeUser = try integer(node, "Node", "User");
	const profileId = try integer(profile, "UserProfile", "ID");
	if (nodeUser != profileId) {
		return Result.err(
			badOutput(`Node.User ${nodeUser} is not UserProfile.ID ${profileId}`),
		);
	}
	const hostinfo = try fieldOrNull(node, "Node", "Hostinfo");
	return Result.ok({
		userId: nodeUser,
		loginName: try text(profile, "UserProfile", "LoginName"),
		hostName: try text(node, "Node", "ComputedName"),
		os:
			hostinfo === null ? "" : try textOrEmpty(hostinfo, "Node.Hostinfo", "OS"),
	});
}

function admit(
	peer: PeerInfo,
	self: TailnetSelf,
): Result<PeerInfo, TailnetError> {
	if (peer.userId != self.userId) {
		return Result.err(
			failure(
				TailnetFault.OtherUser,
				`${peer.hostName} belongs to ${peer.loginName}, not ${self.loginName}`,
			),
		);
	}
	return Result.ok(peer);
}

function allOf(text: string, allowed: string): boolean {
	if (text == "") {
		return false;
	}
	for (let i = 0; i < text.length; i++) {
		if (!allowed.includes(text[i])) {
			return false;
		}
	}
	return true;
}

function decimal(text: string, maxDigits: int32): int32 | null {
	if (text.length > maxDigits || !allOf(text, "0123456789")) {
		return null;
	}
	if (text.length > 1 && text[0] == "0") {
		return null;
	}
	let value: int32 = 0;
	for (let i = 0; i < text.length; i++) {
		value = value * 10 + (text.charCodeAt(i) - 48) as int32;
	}
	return value;
}

function inTailnetIpv4(host: string): boolean {
	const parts = host.split(".");
	if (parts.length != 4) {
		return false;
	}
	for (const part of parts) {
		const octet = decimal(part, 3);
		if (octet === null || octet > 255) {
			return false;
		}
	}
	const second = decimal(parts[1], 3) ?? 0;
	return parts[0] == "100" && second >= 64 && second <= 127;
}

function inTailnetIpv6(host: string): boolean {
	const prefix = "fd7a:115c:a1e0:";
	const lower = host.toLowerCase();
	return (
		lower.startsWith(prefix) &&
		allOf(lower.slice(prefix.length), "0123456789abcdef:")
	);
}

function tailnetHost(remote: string): Result<string, TailnetError> {
	const refused = failure(
		TailnetFault.NotTailnetAddress,
		`${remote} is not a tailnet address and port ` +
			"(100.64.0.0/10 or fd7a:115c:a1e0::/48)",
	);
	const bracketed = remote.startsWith("[");
	const close = bracketed ? remote.indexOf("]:") : remote.lastIndexOf(":");
	if (close < 0) {
		return Result.err(refused);
	}
	const host = bracketed ? remote.slice(1, close) : remote.slice(0, close);
	const port = decimal(remote.slice(close + (bracketed ? 2 : 1)), 5);
	if (port === null || port < 1 || port > 65535) {
		return Result.err(refused);
	}
	const inside = bracketed ? inTailnetIpv6(host) : inTailnetIpv4(host);
	return inside ? Result.ok(host) : Result.err(refused);
}

function statusVia(programs: string[]): Result<JsonValue, TailnetError> {
	const answer = runCli(programs, ["status", "--json"], CLI_TIMEOUT_MS);
	if (!answer.ok) {
		const e = answer.error;
		return Result.err(
			e.fault == TailnetFault.CliFailed
				? failure(TailnetFault.NotRunning, e.detail)
				: e,
		);
	}
	return parsed(answer.value, "tailscale status --json");
}

export function tailnetSelf(): Result<TailnetSelf, TailnetError> {
	return selfFromStatus(try statusVia(installedClis()));
}

export function listenAddress(self: TailnetSelf): string {
	return self.ipv4;
}

export function peers(): Result<Vec<TailnetPeer>, TailnetError> {
	const status = try statusVia(installedClis());
	return peersFromStatus(status, try selfFromStatus(status));
}

export function peerAllowed(
	remote: string,
	self: TailnetSelf,
): Result<PeerInfo, TailnetError> {
	try tailnetHost(remote);
	const answer = runCli(
		installedClis(),
		["whois", "--json", remote],
		CLI_TIMEOUT_MS,
	);
	if (!answer.ok) {
		const e = answer.error;
		return Result.err(
			e.fault == TailnetFault.CliFailed
				? failure(TailnetFault.UnknownPeer, `${remote}: ${e.detail}`)
				: e,
		);
	}
	return admit(
		try peerFromWhois(try parsed(answer.value, "tailscale whois --json")),
		self,
	);
}

const TESTDATA = "src/server/testdata/";

const ME: TailnetSelf = {
	ipv4: "100.100.1.1",
	ipv6: "fd7a:115c:a1e0::1:1",
	userId: 7000000000000001,
	loginName: "person@example.com",
	hostName: "studio",
};

function fixture(name: string): string {
	const read = readFile(TESTDATA + name);
	return read.ok ? read.value : "";
}

function selfOf(status: string): Result<TailnetSelf, TailnetError> {
	return selfFromStatus(try parsed(status, "status"));
}

function peersOf(status: string): Result<Vec<TailnetPeer>, TailnetError> {
	return peersFromStatus(try parsed(status, "status"), ME);
}

function admitted(whois: string): Result<PeerInfo, TailnetError> {
	return admit(try peerFromWhois(try parsed(whois, "whois")), ME);
}

function faultOf<T>(r: Result<T, TailnetError>): TailnetFault | null {
	return r.ok ? null : r.error.fault;
}

test "status names our tailnet addresses, user and host" {
	const self = selfOf(fixture("status.json"));
	assert self.ok;
	if (self.ok) {
		assert self.value.ipv4 == "100.100.1.1";
		assert self.value.ipv6 == "fd7a:115c:a1e0::1:1";
		assert self.value.userId == 7000000000000001;
		assert self.value.loginName == "person@example.com";
		assert self.value.hostName == "studio";
		assert listenAddress(self.value) == "100.100.1.1";
	}
}

test "a status that is not Running is NotRunning naming the state" {
	const r = selfOf(`{"BackendState":"NeedsLogin","Self":null}`);
	assert faultOf(r) == TailnetFault.NotRunning;
	assert !r.ok && r.error.detail.contains("NeedsLogin");
}

test "a status of the wrong shape is BadOutput naming the field" {
	const cases = [
		[`{"BackendState":"Running"}`, "status.Self is missing"],
		[
			`{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.1"],"UserID":"7"}}`,
			"Self.UserID is not an integer",
		],
		[
			`{"BackendState":"Running","Self":{"TailscaleIPs":["fd7a:115c:a1e0::1"]}}`,
			"Self.TailscaleIPs holds no IPv4",
		],
		[
			`{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.1"],"UserID":7},"User":{}}`,
			"User.7 is missing",
		],
		[`[]`, "status is not an object"],
		[`{"BackendState":`, ""],
	];
	for (const c of cases) {
		const r = selfOf(c[0]);
		assert faultOf(r) == TailnetFault.BadOutput;
		assert !r.ok && (c[1] == "" || r.error.detail == c[1]);
	}
}

test "peers are our own online devices with host name, address and OS" {
	const found = peersOf(fixture("status.json"));
	assert found.ok;
	if (found.ok) {
		assert found.value.length == 2;
		assert found.value[0].hostName == "build-1";
		assert found.value[0].address == "100.100.1.2";
		assert found.value[0].os == "linux";
		assert found.value[1].hostName == "pc";
		assert found.value[1].address == "100.100.1.4";
		assert found.value[1].os == "windows";
	}
}

test "a status with no peers lists none" {
	const found = peersOf(`{"Peer":null}`);
	assert found.ok && found.value.length == 0;
}

test "a device of our own user is allowed" {
	const allowed = admitted(fixture("whoisOwn.json"));
	assert allowed.ok;
	if (allowed.ok) {
		assert allowed.value.hostName == "build-1";
		assert allowed.value.os == "linux";
		assert allowed.value.loginName == "person@example.com";
		assert allowed.value.userId == ME.userId;
	}
}

test "a device of another user is refused naming both users" {
	const refused = admitted(fixture("whoisOther.json"));
	assert faultOf(refused) == TailnetFault.OtherUser;
	assert !refused.ok &&
		refused.error.detail ==
			"friend-box belongs to friend@example.com, not person@example.com";
}

test "a whois whose node and profile disagree on the user is BadOutput" {
	const r = admitted(
		`{"Node":{"User":1,"ComputedName":"x"},"UserProfile":{"ID":2,"LoginName":"a"}}`,
	);
	assert faultOf(r) == TailnetFault.BadOutput;
	assert !r.ok && r.error.detail == "Node.User 1 is not UserProfile.ID 2";
}

test "tailnet addresses with a port pass and every other remote is refused" {
	assert tailnetHost("100.100.1.2:5000").ok;
	assert tailnetHost("100.64.0.0:1").ok;
	assert tailnetHost("100.127.255.255:65535").ok;
	assert tailnetHost("[fd7a:115c:a1e0::1:2]:5000").ok;
	assert tailnetHost("[FD7A:115C:A1E0:ab12::1]:22").ok;
	const refused = [
		"192.168.1.2:22",
		"100.63.255.255:22",
		"100.128.0.1:22",
		"10.100.64.1:22",
		"100.64.0.1",
		"100.64.0.1:0",
		"100.64.0.1:65536",
		"100.64.0.1:x",
		"100.064.0.1:22",
		"100.64.0.256:22",
		"100.64.0:22",
		"0.0.0.0:22",
		"[fd7a:115c:a1e1::1]:22",
		"[::ffff:100.64.0.1]:22",
		"[fd7a:115c:a1e0::1%en0]:22",
		"fd7a:115c:a1e0::1:22",
		"[fd7a:115c:a1e0::1]",
		"",
	];
	for (const remote of refused) {
		assert faultOf(tailnetHost(remote)) == TailnetFault.NotTailnetAddress;
	}
}

test "a non-tailnet remote is refused before asking Tailscale" {
	const r = peerAllowed("203.0.113.9:22", ME);
	assert faultOf(r) == TailnetFault.NotTailnetAddress;
}

test "no CLI at any candidate is CliMissing naming each" {
	const r = runCli(
		["/nonexistent/tailscale", "haro-no-such-tailscale-cli"],
		["status"],
		1000,
	);
	assert faultOf(r) == TailnetFault.CliMissing;
	assert !r.ok && r.error.detail.contains("/nonexistent/tailscale");
	const status = statusVia(["/nonexistent/tailscale"]);
	assert faultOf(status) == TailnetFault.CliMissing;
}

test "a CLI that fails reports its stderr, and one that hangs times out" {
	when (windows) { return; }
	const failed = runCli(
		["/bin/sh"],
		["-c", "echo peer not found >&2; exit 1"],
		5000,
	);
	assert faultOf(failed) == TailnetFault.CliFailed;
	assert !failed.ok && failed.error.detail == "peer not found";
	const stopped = statusVia(["false"]);
	assert faultOf(stopped) == TailnetFault.NotRunning;
	const started = performance.now();
	const hung = runCli(["/bin/sh"], ["-c", "sleep 10"], 200);
	assert faultOf(hung) == TailnetFault.Timeout;
	assert performance.now() - started < 5000;
	const said = runCli(["/bin/sh"], ["-c", "echo '{\"a\":1}'"], 5000);
	assert said.ok && said.value == '{"a":1}\n';
}

test "live: this host's Tailscale answers or says it is not running" {
	const self = tailnetSelf();
	if (!self.ok) {
		const fault = self.error.fault;
		assert fault == TailnetFault.CliMissing || fault == TailnetFault.NotRunning;
		return;
	}
	const me = self.value;
	assert tailnetHost(`${listenAddress(me)}:1`).ok;
	const own = peerAllowed(`${me.ipv4}:1`, me);
	assert own.ok && own.value.userId == me.userId;
	assert peers().ok;
}
