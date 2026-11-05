import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { askStatus, askStop, answeringPid, nobody, otherVersion, otherVersionAdvice } from "./control";
import { MAX_SCREEN_BYTES, MessageKind, encode } from "./protocol";
import { CloseReason, Connection, listenUnix } from "./transport";
import { Server, start } from "./serve";

when (!windows) {
	@include("unistd.h");

	extern function getpid(): int32;

	function socketIn(name: string): string {
		return join(join(tmpDir(), `haro-control-${Date.now()}-${name}`), "s.sock");
	}

	async function serving(socket: string): Promise<Server> {
		const started = await Server.start({
			launch: { command: "sh", shellScripts: null, startIn: null, originCwd: false },
			socket: socket,
			dividerCells: 1,
			tailnet: null,
			screenLimit: MAX_SCREEN_BYTES,
			log: (line: string): void => {},
		});
		if (!started.ok) { throw new Error(`no server: ${started.error}`); }
		return started.value;
	}

	test "status names the server's pid and socket, and stop ends it so nobody answers after" {
		const socket = socketIn("live");
		const s = await serving(socket);
		let code: int32 = -1;
		s.finished.then((c: int32): void => { code = c; });
		assert await answeringPid(socket) == getpid();
		const status = await askStatus(socket);
		assert status.ok, status.ok ? "" : status.error;
		if (status.ok) {
			assert status.value.pid == getpid();
			assert status.value.listeners.join("|") == `unix ${socket}`, status.value.listeners.join("|");
			assert status.value.clients.length == 0;
		}
		const stopped = await askStop(socket);
		assert stopped.ok && stopped.value == getpid(), stopped.ok ? "" : stopped.error;
		const deadline = Date.now() + 5000;
		while (code < 0 && Date.now() < deadline) { await sleepAsync(5); }
		assert code == 0;
		assert await answeringPid(socket) === null;
		const _removed = removeAll(socket.slice(0, socket.lastIndexOf("/")));
	}

	test "with no server, status and stop say nobody answers at the socket" {
		const socket = socketIn("none");
		const status = await askStatus(socket);
		assert !status.ok && status.error == nobody(socket);
		const stopped = await askStop(socket);
		assert !stopped.ok && stopped.error == nobody(socket);
	}

	test "a server of another protocol is named by its program and pid, a current one is not" {
		const live = socketIn("current");
		const _s = await serving(live);
		assert await otherVersion(live) === null;
		const stopped = await askStop(live);
		assert stopped.ok, stopped.ok ? "" : stopped.error;
		const _gone = removeAll(live.slice(0, live.lastIndexOf("/")));
		const old = socketIn("old");
		const refusal = encode({ kind: MessageKind.Refused, reason: "protocol version 2 refused: this server speaks 1" });
		assert refusal.ok;
		const refused: uint8[] = refusal.ok ? refusal.value : [];
		const listener = listenUnix(old, {
			accepted: (c: Connection): void => {
				c.start((chunk: uint8[]): void => {
					const _sent = c.send(refused);
					c.finish();
				}, (why: CloseReason): void => {});
			},
			failed: (): void => {},
		});
		assert listener.ok;
		const said = (await otherVersion(old)) ?? "";
		assert said.includes("this server speaks 1") && said.includes(`pid ${getpid()}`), said;
		if (listener.ok) { listener.value.close(); }
		const _removed = removeAll(old.slice(0, old.lastIndexOf("/")));
	}
}

test "the advice names the stop command of a haro-server, and only asks to quit another program" {
	const reason = "protocol version 2 refused: this server speaks 1";
	const server = otherVersionAdvice("/s", reason, { pid: 7, path: "/h/.haro/server/abc/haro-server" });
	assert server.endsWith("run /h/.haro/server/abc/haro-server stop, then connect again."), server;
	const app = otherVersionAdvice("/s", reason, { pid: 7, path: "/A/Haro.app/Contents/MacOS/haro" });
	assert app.includes("It is /A/Haro.app/Contents/MacOS/haro, pid 7: close its shells, end it with kill 7"), app;
	const unknown = otherVersionAdvice("/s", reason, null);
	assert unknown.startsWith(`A Haro server of another version answers at /s and keeps its shells (${reason}).`);
}
