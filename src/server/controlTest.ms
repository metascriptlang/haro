import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { tmpDir } from "std/os";
import { askStatus, askStop, answeringPid, nobody } from "./control";
import { MAX_SCREEN_BYTES } from "./protocol";
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
}
