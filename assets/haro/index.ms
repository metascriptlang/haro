export interface Keybind {
	keys: string;
	text?: string;
	action?:
		| "close_window"
		| "copy"
		| "paste"
		| "select_all"
		| "clear_scrollback"
		| "scroll_line_up"
		| "scroll_line_down"
		| "scroll_page_up"
		| "scroll_page_down"
		| "scroll_to_top"
		| "scroll_to_bottom"
		| "prompt_up"
		| "prompt_down"
		| "increase_font_size"
		| "decrease_font_size"
		| "reset_font_size"
		| "open_config"
		| "reload_config";
	mode?: "alt" | "~alt";
}

export interface KeyPress {
	code: string;
	text: string;
	shift: boolean;
	ctrl: boolean;
	alt: boolean;
	super: boolean;
	repeat: boolean;
}

export interface KeyAnswer {
	handled: boolean;
	send?: string;
}

export type Anchor = int32;

export interface Prompt {
	at: Anchor;
}

export interface CommandDone {
	exitCode?: number;
	command: string;
	durationMs?: number;
	prompt?: Anchor;
	output?: Anchor;
	end: Anchor;
}

export interface Decoration {
	from: Anchor;
	to: Anchor;
	background?: string;
	foreground?: string;
}

export extern function send(text: string): void from "haro.send";
export extern function notify(title: string, body: string): void from "haro.notify";
export extern function decorate(d: Decoration): int32 from "haro.decorate";
export extern function undecorate(id: int32): void from "haro.undecorate";

export interface Annotation {
	at: Anchor;
	text: string;
	foreground?: string;
	background?: string;
}

export extern function annotate(a: Annotation): int32 from "haro.annotate";
export extern function unannotate(id: int32): void from "haro.unannotate";

const FAILED_BACKGROUND = "#3a1c24";

function tookText(durationMs?: number): string {
	if (durationMs === undefined) { return ""; }
	return ` · ${(durationMs / 1000).toFixed(1)}s`;
}

export function markFailed(e: CommandDone): void {
	const code = e.exitCode;
	const prompt = e.prompt;
	if (code === undefined || code == 0 || prompt === undefined) { return; }
	decorate({ from: prompt, to: e.end, background: FAILED_BACKGROUND });
	annotate({ at: prompt, text: `exit ${code}${tookText(e.durationMs)}` });
}

export interface HaroConfig {
	fontFamily?: string[];
	fontSize?: number;
	padding?: number;
	command?: string;
	shellIntegration?: boolean;
	workingDirectory?: string;
	scrollback?: int32;
	foreground?: string;
	background?: string;
	palette?: string[];
	keybinds?: Keybind[];
	optionAsAlt?: "neither" | "left" | "right" | "both";
	copyOnSelect?: boolean;
	onKey?: (e: KeyPress) => KeyAnswer;
	onPrompt?: (e: Prompt) => void;
	onCommandDone?: (e: CommandDone) => void;
}

export const saigonNight = {
	background: "#16161e",
	foreground: "#a9b1d6",
	palette: [
		"#363b54", "#f7768e", "#73daca", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#787c99",
		"#363b54", "#f7768e", "#41a6b5", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#acb0d0",
	],
};
