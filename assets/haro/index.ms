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
		| "reload_config"
		| "split_right"
		| "split_down"
		| "close_pane"
		| "focus_pane_left"
		| "focus_pane_right"
		| "focus_pane_up"
		| "focus_pane_down"
		| "focus_pane_previous"
		| "focus_pane_next"
		| "resize_pane_left"
		| "resize_pane_right"
		| "resize_pane_up"
		| "resize_pane_down"
		| "toggle_pane_zoom"
		| "new_tab"
		| "close_tab"
		| "previous_tab"
		| "next_tab"
		| "goto_tab_1"
		| "goto_tab_2"
		| "goto_tab_3"
		| "goto_tab_4"
		| "goto_tab_5"
		| "goto_tab_6"
		| "goto_tab_7"
		| "goto_tab_8"
		| "goto_tab_9"
		| "move_tab_left"
		| "move_tab_right"
		| "rename_tab"
		| "toggle_sidebar"
		| "new_tab_on_host"
		| "add_remote_host";
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

export interface CursorEffects {
	glitch?: boolean;
	trail?: boolean;
	dust?: number;
}

export interface RemoteHost {
	label: string;
	address: string;
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
	cursor?: CursorEffects;
	dividerStyle?: "cell" | "line";
	dividerColor?: string;
	focusedDividerColor?: string;
	paneGap?: number;
	paneTitle?: "border" | "none";
	paneResizeStep?: int32;
	sidebarPosition?: "left" | "right";
	sidebarVisible?: boolean;
	sidebarWidth?: int32;
	confirmClose?: boolean;
	newPaneCwd?: "focused" | "start";
	serverTailnet?: boolean;
	serverTailnetPort?: int32;
	remoteHosts?: RemoteHost[];
	remotePrediction?: "auto" | "on" | "off";
	onKey?: (e: KeyPress) => KeyAnswer;
	onPrompt?: (e: Prompt) => void;
	onCommandDone?: (e: CommandDone) => void;
}

export const saigonNight = {
	background: "#1a1b26",
	foreground: "#c0caf5",
	palette: [
		"#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
		"#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
	],
};
