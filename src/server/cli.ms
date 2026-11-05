import { Config, defaults } from "../config/config";
import { TailnetAllow } from "./tailnet";
import { TailnetChoice } from "./serve";

export enum Verb {
	Run,
	Start,
	Status,
	Stop,
	Logs,
	Proxy,
	Version,
	Help,
}

export struct Invocation {
	verb: Verb;
	listenTailnet: boolean;
	tailnetPort: int32 | null;
	allow: TailnetAllow;
	stateDir: string | null;
	detach: boolean;
}

export const USAGE: string = `usage: haro-server <command> [options]

commands:
  run      serve in the foreground, logging to stderr
  start    serve in the background, logging to the state directory; refused while a server answers
  status   the server's pid, listeners and attached clients
  stop     ask the server to close its shells and exit
  logs     print the log of a server started with start
  proxy    bridge stdin and stdout to the server, starting it when none answers (the window runs this over ssh)
  version  this binary's version, protocol version and libghostty-vt build

options:
  --listen-tailnet[=PORT]      also listen on this machine's tailnet addresses (port 7681 unless given)
  --tailnet-allow-identified   let in every identified tailnet user and tagged device, not only the machine's owner
  --state-dir DIR              where start writes and logs reads the log

HARO_SOCKET names the unix socket; the config file is read as the window reads it.`;

const VERBS: string[] = ["run", "start", "status", "stop", "logs", "proxy", "version", "help"];
const LISTEN_TAILNET = "--listen-tailnet";
const ALLOW_IDENTIFIED = "--tailnet-allow-identified";
const STATE_DIR = "--state-dir";
const DETACH = "--detach";
const MAX_PORT: int32 = 65535;

function verbOf(word: string): Verb | null {
	return match (word) {
		"run" => Verb.Run,
		"start" => Verb.Start,
		"status" => Verb.Status,
		"stop" => Verb.Stop,
		"logs" => Verb.Logs,
		"proxy" => Verb.Proxy,
		"version" => Verb.Version,
		"--version" => Verb.Version,
		"help" => Verb.Help,
		"--help" => Verb.Help,
		"-h" => Verb.Help,
		_ => null,
	};
}

function portOf(text: string): Result<int32, string> {
	const port = parseInt(text);
	if (`${port}` != text || port < 1 || port > MAX_PORT) {
		return Result.err(`${LISTEN_TAILNET}=${text}: the port must be 1 to ${MAX_PORT}`);
	}
	return Result.ok(port as int32);
}

function serving(verb: Verb): boolean {
	return verb == Verb.Run || verb == Verb.Start;
}

export function parseArgs(args: string[]): Result<Invocation, string> {
	if (args.length == 0) { return Result.err(`no command: one of ${VERBS.join(", ")}`); }
	const verb = verbOf(args[0]);
	if (verb === null) { return Result.err(`unknown command ${args[0]}: one of ${VERBS.join(", ")}`); }
	let got: Invocation = {
		verb: verb,
		listenTailnet: false,
		tailnetPort: null,
		allow: TailnetAllow.Owner,
		stateDir: null,
		detach: false,
	};
	let i = 1;
	while (i < args.length) {
		const arg = args[i];
		i += 1;
		if (arg == LISTEN_TAILNET || arg.startsWith(`${LISTEN_TAILNET}=`)) {
			if (!serving(verb)) { return Result.err(`${arg} belongs to run or start, not ${args[0]}`); }
			got.listenTailnet = true;
			if (arg != LISTEN_TAILNET) { got.tailnetPort = try portOf(arg.slice(LISTEN_TAILNET.length + 1)); }
		} else if (arg == ALLOW_IDENTIFIED) {
			if (!serving(verb)) { return Result.err(`${arg} belongs to run or start, not ${args[0]}`); }
			got.allow = TailnetAllow.Identified;
		} else if (arg == DETACH && verb == Verb.Run) {
			got.detach = true;
		} else if (arg == STATE_DIR || arg.startsWith(`${STATE_DIR}=`)) {
			if (verb != Verb.Start && verb != Verb.Logs && verb != Verb.Proxy) {
				return Result.err(`${STATE_DIR} belongs to start, logs or proxy, not ${args[0]}`);
			}
			let dir = arg.slice(STATE_DIR.length + 1);
			if (arg == STATE_DIR) {
				if (i >= args.length) { return Result.err(`${STATE_DIR} needs a directory`); }
				dir = args[i];
				i += 1;
			}
			if (dir == "") { return Result.err(`${STATE_DIR} needs a directory`); }
			got.stateDir = dir;
		} else {
			return Result.err(`unknown option ${arg} for ${args[0]}`);
		}
	}
	return Result.ok(got);
}

export function runArgs(inv: Invocation): string[] {
	const out = ["run", DETACH];
	if (inv.listenTailnet) {
		const port = inv.tailnetPort;
		out.push(port === null ? LISTEN_TAILNET : `${LISTEN_TAILNET}=${port}`);
	}
	if (inv.allow == TailnetAllow.Identified) { out.push(ALLOW_IDENTIFIED); }
	return out;
}

export function tailnetChoice(inv: Invocation, config: Config): TailnetChoice | null {
	if (!inv.listenTailnet && !config.serverTailnet) { return null; }
	return { port: inv.tailnetPort ?? config.serverTailnetPort, allow: inv.allow };
}

function refusal(args: string[]): string {
	const got = parseArgs(args);
	return got.ok ? "" : got.error;
}

test "each command parses, and help has three spellings" {
	const cases: string[] = ["run", "start", "status", "stop", "logs", "proxy", "version", "--version", "help", "--help", "-h"];
	const verbs: Verb[] = [
		Verb.Run, Verb.Start, Verb.Status, Verb.Stop, Verb.Logs, Verb.Proxy,
		Verb.Version, Verb.Version, Verb.Help, Verb.Help, Verb.Help,
	];
	for (let i = 0; i < cases.length; i++) {
		const got = parseArgs([cases[i]]);
		assert got.ok && got.value.verb == verbs[i], cases[i];
		assert got.ok && !got.value.listenTailnet && got.value.allow == TailnetAllow.Owner;
	}
}

test "the tailnet listener is off by default, takes the configured port bare, and a port after =" {
	const bare = parseArgs(["run", "--listen-tailnet"]);
	assert bare.ok && bare.value.listenTailnet && bare.value.tailnetPort === null;
	const given = parseArgs(["start", "--listen-tailnet=9001", "--tailnet-allow-identified"]);
	assert given.ok && given.value.tailnetPort == 9001 && given.value.allow == TailnetAllow.Identified;
	assert refusal(["run", "--listen-tailnet=0"]) == "--listen-tailnet=0: the port must be 1 to 65535";
	assert refusal(["run", "--listen-tailnet=65536"]) == "--listen-tailnet=65536: the port must be 1 to 65535";
	assert refusal(["run", "--listen-tailnet=07681"]) == "--listen-tailnet=07681: the port must be 1 to 65535";
	assert refusal(["run", "--listen-tailnet="]) == "--listen-tailnet=: the port must be 1 to 65535";
}

test "a serving option on a command that does not serve is refused naming both" {
	assert refusal(["status", "--listen-tailnet"]) == "--listen-tailnet belongs to run or start, not status";
	assert refusal(["stop", "--tailnet-allow-identified"]) == "--tailnet-allow-identified belongs to run or start, not stop";
	assert refusal(["run", "--state-dir", "/tmp/x"]) == "--state-dir belongs to start, logs or proxy, not run";
	assert refusal(["start", "--detach"]) == "unknown option --detach for start";
}

test "no command, an unknown command and an unknown option are refused" {
	assert refusal([]) == "no command: one of run, start, status, stop, logs, proxy, version, help";
	assert refusal(["serve"]) == "unknown command serve: one of run, start, status, stop, logs, proxy, version, help";
	assert refusal(["proxy", "--listen-tailnet"]) == "--listen-tailnet belongs to run or start, not proxy";
	assert refusal(["run", "--listen"]) == "unknown option --listen for run";
}

test "the state directory is read with a space or an =, and an empty one is refused" {
	const spaced = parseArgs(["logs", "--state-dir", "/var/haro"]);
	assert spaced.ok && spaced.value.stateDir == "/var/haro";
	const joined = parseArgs(["start", "--state-dir=/var/haro"]);
	assert joined.ok && joined.value.stateDir == "/var/haro";
	assert refusal(["start", "--state-dir"]) == "--state-dir needs a directory";
	assert refusal(["start", "--state-dir="]) == "--state-dir needs a directory";
}

test "start hands its serving options to the detached run" {
	const plain = parseArgs(["start"]);
	assert plain.ok && runArgs(plain.value).join(" ") == "run --detach";
	const full = parseArgs(["start", "--state-dir", "/s", "--listen-tailnet=9001", "--tailnet-allow-identified"]);
	assert full.ok && runArgs(full.value).join(" ") == "run --detach --listen-tailnet=9001 --tailnet-allow-identified";
	const bare = parseArgs(["start", "--listen-tailnet"]);
	assert bare.ok && runArgs(bare.value).join(" ") == "run --detach --listen-tailnet";
	const detached = parseArgs(runArgs(full.value));
	assert detached.ok && detached.value.detach && detached.value.tailnetPort == 9001;
}

test "the flag or the config turns the tailnet on, and the flag's port wins" {
	const off = parseArgs(["run"]);
	assert off.ok && tailnetChoice(off.value, defaults()) === null;
	const configured = { ...defaults(), serverTailnet: true, serverTailnetPort: 9100 };
	const fromConfig = off.ok ? tailnetChoice(off.value, configured) : null;
	assert fromConfig !== null && fromConfig.port == 9100 && fromConfig.allow == TailnetAllow.Owner;
	const flagged = parseArgs(["run", "--listen-tailnet", "--tailnet-allow-identified"]);
	const bare = flagged.ok ? tailnetChoice(flagged.value, defaults()) : null;
	assert bare !== null && bare.port == 7681 && bare.allow == TailnetAllow.Identified;
	const ported = parseArgs(["run", "--listen-tailnet=9001"]);
	const wins = ported.ok ? tailnetChoice(ported.value, configured) : null;
	assert wins !== null && wins.port == 9001;
}
