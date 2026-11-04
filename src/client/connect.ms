import { execPath } from "std/process";
import { Connection, connectToTcp, connectToUnix } from "../server/transport";

when (!windows) {
	@include("./detached.h");
	@compile("./detached.c");

	extern function haroStartDetached(path: cstring, flag: cstring): int32;
}

export const DEFAULT_PORT: int32 = 7681;
const CONNECT_TIMEOUT_MS: int32 = 2000;
const RETRY_DELAYS_MS: int32[] = [25, 50, 100, 200, 400, 800, 1600];

export struct Target {
	host: string;
	port: int32;
}

function portOf(text: string, target: string): Result<int32, string> {
	const port = parseInt(text);
	if (`${port}` != text || port < 1 || port > 65535) {
		return Result.err(`--connect ${target}: the port must be 1 to 65535`);
	}
	return Result.ok(port as int32);
}

export function targetOf(target: string): Result<Target, string> {
	if (target.startsWith("[")) {
		const close = target.indexOf("]");
		if (close < 0) { return Result.err(`--connect ${target}: no closing ]`); }
		const host = target.substring(1, close);
		const rest = target.substring(close + 1);
		if (rest == "") { return Result.ok({ host: host, port: DEFAULT_PORT }); }
		if (!rest.startsWith(":")) {
			return Result.err(`--connect ${target}: expected :port after ]`);
		}
		const port = try portOf(rest.substring(1), target);
		return Result.ok({ host: host, port: port });
	}
	const colon = target.indexOf(":");
	if (colon != target.lastIndexOf(":")) {
		return Result.ok({ host: target, port: DEFAULT_PORT });
	}
	if (colon < 0) {
		if (target == "") { return Result.err("--connect needs a host"); }
		return Result.ok({ host: target, port: DEFAULT_PORT });
	}
	const host = target.substring(0, colon);
	if (host == "") { return Result.err(`--connect ${target}: no host before :`); }
	const port = try portOf(target.substring(colon + 1), target);
	return Result.ok({ host: host, port: port });
}

export async function connectTcp(target: Target): Promise<Result<Connection, string>> {
	const c = await connectToTcp(target.host, target.port, CONNECT_TIMEOUT_MS);
	if (!c.ok) {
		return Result.err(
			`no Haro server answered at ${target.host}:${target.port} (${c.error.toString()})`,
		);
	}
	return Result.ok(c.value);
}

function startServer(): Result<void, string> {
	when (windows) {
		return Result.err("this window cannot start a Haro server on Windows yet");
	} else {
		if (execPath == "") {
			return Result.err("the OS does not report this program's path to start its server");
		}
		const pid = haroStartDetached(execPath, "--server");
		if (pid <= 0) { return Result.err(`starting ${execPath} --server failed (${-pid})`); }
		return Result.ok(null);
	}
}

export async function connectLocal(path: string): Promise<Result<Connection, string>> {
	const first = await connectToUnix(path, CONNECT_TIMEOUT_MS);
	if (first.ok) { return Result.ok(first.value); }
	try startServer();
	for (const delay of RETRY_DELAYS_MS) {
		await sleepAsync(delay);
		const again = await connectToUnix(path, CONNECT_TIMEOUT_MS);
		if (again.ok) { return Result.ok(again.value); }
	}
	return Result.err(`the Haro server started but never answered at ${path}`);
}
