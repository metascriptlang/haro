import { env } from "std/process";
import { Message, MessageKind } from "../server/protocol";
import { Vt, lines, update } from "../vt/vt";
import { vtBuild } from "../vt/snapshot";
import { seededVt } from "../pty/remote";
import { Axis, PaneId, panes } from "../workspace/tree";
import { CommandKind } from "../workspace/workspace";
import { Linked, linkTo } from "./link";
import { run, serverPath, sshArgs, sshDial } from "./ssh";
import { Screen, screenParts } from "./wire";

const WAIT_MS: float64 = 30000;
const DIAL_MS: int32 = 60000;

async function until(done: () => boolean): Promise<boolean> {
	const start = performance.now();
	while (!done()) {
		if (performance.now() - start > WAIT_MS) { return false; }
		await sleepAsync(20);
	}
	return true;
}

function text(this vt: Vt): string {
	if (!vt.update().ok) { return "<update failed>"; }
	const got = vt.lines();
	return got.ok ? got.value.join("\n") : "<lines failed>";
}

class Heard {
	messages: Message[] = [];
	ended: string | null = null;

	output(pane: PaneId): string {
		let said = "";
		for (const m of this.messages) {
			if (m.kind == MessageKind.Output && m.pane == pane) { said += m.bytes.asString(); }
		}
		return said;
	}

	newestPanes(): PaneId[] {
		let ids: PaneId[] = [];
		for (const m of this.messages) {
			const parts = screenParts(m);
			if (parts === null || parts.layout === null) { continue; }
			ids = [];
			for (const tab of parts.layout.tabs) {
				for (const p of tab.root.panes()) { ids.push(p.id); }
			}
		}
		return ids;
	}
}

async function remote(host: string, command: string): Promise<string> {
	const ran = await run(sshArgs(host, command));
	if (!ran.ok) { return `<${ran.error}>`; }
	return `${ran.value.code} ${ran.value.out.trim()} ${ran.value.err}`;
}

class Uploads {
	count: int32 = 0;
}

async function dialed(host: string, socket: string, uploads: Uploads): Promise<Linked> {
	const got = await linkTo(sshDial(host, socket), (): void => { uploads.count += 1; }, vtBuild(), 80, 24, DIAL_MS);
	if (!got.ok) { throw new Error(`dialing ${host}: ${got.error.why}`); }
	return got.value;
}

test "a real host gets the bundle, keeps a pane's shell across a dropped ssh, and shows it again on redial" {
	const host = env.get("HARO_REMOTE_HOST");
	if (host == "") { return; }
	const dir = `/tmp/haro-e2e-${Date.now()}`;
	const socket = `${dir}/haro.sock`;
	const versionDir = `~/${serverPath().slice(0, serverPath().lastIndexOf("/"))}`;
	console.log(`prepare: ${await remote(host, `rm -rf ${versionDir} && mkdir -p ${dir}`)}`);
	const uploads = new Uploads();

	const first = await dialed(host, socket, uploads);
	assert uploads.count == 1, `uploads ${uploads.count}`;
	const heard = new Heard();
	first.link.listen(
		(m: Message): void => { heard.messages.push(m); },
		(why: string): void => { heard.ended = why; },
	);
	const opening = first.attached.layout.tabs[0].root.panes()[0].id;
	first.link.command({ kind: CommandKind.Split, pane: opening, axis: Axis.SideBySide });
	assert await until((): boolean => heard.newestPanes().length == 2), `${heard.messages.length} messages`;
	const pane = heard.newestPanes().find((id: PaneId): boolean => id != opening) ?? opening;
	const marker = `haro-e2e-${Date.now() % 100000}`;
	first.link.input(pane, [...`echo ${marker}-$((6 * 7))\r`.asBytes()]);
	assert await until((): boolean => heard.output(pane).includes(`${marker}-42`)), heard.output(pane);
	console.log(`typed into pane ${pane as int32} and saw ${marker}-42 in Output`);

	const pids = await run(["pgrep", "-f", `ssh .*${dir}`]);
	const pid = pids.ok ? pids.value.out.trim() : "";
	assert pid != "" && !pid.includes("\n"), `the proxy's ssh pid: '${pid}'`;
	const killed = await run(["kill", "-9", pid]);
	assert killed.ok && killed.value.code == 0;
	assert await until((): boolean => heard.ended !== null), "the link did not see the ssh drop";
	console.log(`killed ssh ${pid}; the link ended: ${heard.ended ?? ""}`);

	const second = await dialed(host, socket, uploads);
	assert uploads.count == 1, `uploads ${uploads.count}`;
	assert second.attached.serverPid == first.attached.serverPid;
	const restored = second.attached.screens.find((s: Screen): boolean => s.pane == pane) ?? null;
	assert restored !== null, `no screen for pane ${pane as int32}`;
	if (restored !== null) {
		const vt = restored.seed.seededVt();
		assert vt.ok;
		if (vt.ok) {
			const shown = vt.value.text();
			assert shown.includes(`${marker}-42`), shown;
			console.log(`reattached to server ${second.attached.serverPid}; pane ${pane as int32} shows ${marker}-42`);
		}
	}
	second.link.detach();
	const stop = `env HARO_SOCKET=${socket} ~/${serverPath()} stop`;
	console.log(`cleanup: ${await remote(host, `${stop}; rm -rf ${versionDir} ${dir}`)}`);
}
