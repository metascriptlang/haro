import { exists } from "std/fs";
import { Connection, connectToUnix } from "../server/transport";
import { Dial, DialError, offline } from "./link";
import { localServer, run } from "./ssh";

const CONNECT_TIMEOUT_MS: int32 = 2000;

async function startServer(): Promise<Result<void, string>> {
	const server = try await localServer();
	if (!exists(server)) {
		return Result.err(
			`no Haro server at ${server}: build one with scripts/buildServer.sh and name out/haro-server with HARO_SERVERS`,
		);
	}
	const started = try await run([server, "start"]);
	if (started.code != 0) { return Result.err(`${server} start: ${started.out.trim()}`); }
	return Result.ok(null);
}

export async function connectLocal(path: string): Promise<Result<Connection, string>> {
	const first = await connectToUnix(path, CONNECT_TIMEOUT_MS);
	if (first.ok) { return Result.ok(first.value); }
	const started = await startServer();
	const again = await connectToUnix(path, CONNECT_TIMEOUT_MS);
	if (again.ok) { return Result.ok(again.value); }
	return Result.err(started.ok ? `the Haro server started but never answered at ${path}` : started.error);
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
