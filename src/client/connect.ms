import { execPath } from "std/process";
import { Connection, connectToUnix } from "../server/transport";
import { Dial, DialError, offline } from "./link";

when (!windows) {
	@include("./detached.h");
	@compile("./detached.c");

	extern function haroStartDetached(path: cstring, flag: cstring): int32;
}

const CONNECT_TIMEOUT_MS: int32 = 2000;
const RETRY_DELAYS_MS: int32[] = [25, 50, 100, 200, 400, 800, 1600];

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

export function dialLocal(path: string): Dial {
	return async (uploading: () => void): Promise<Result<Connection, DialError>> => {
		const c = await connectLocal(path);
		return c.ok ? Result.ok(c.value) : Result.err(offline(c.error));
	};
}

export function dialUnix(path: string): Dial {
	return async (uploading: () => void): Promise<Result<Connection, DialError>> => {
		const c = await connectToUnix(path, CONNECT_TIMEOUT_MS);
		return c.ok ? Result.ok(c.value) : Result.err(offline(`no server at ${path}: ${c.error.toString()}`));
	};
}
