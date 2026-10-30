import { KeyMod } from "../keys/keys";
import {
	MouseAction,
	MouseButton,
	MouseInput,
	Rgb,
	ShellMark,
	ShellStep,
	geometryOf,
	writeText,
} from "../vt/vt";
import { View, fitRows, open, paint, text } from "../app/frame";
import { RowNote } from "../grid/lines";
import {
	Frame,
	Term,
	TermError,
	sendReplies,
	shutdown,
	drain,
	pumpFrame,
} from "./term";
import {
	FrameError,
	RowUpdate,
	annotate,
	decorate,
	fitShown,
	planRows,
	unannotate,
	undecorate,
} from "./rows";
import {
	Sink,
	boardOf,
	drag,
	handled,
	onFresh,
	onPty,
	onRefused,
	onTerm,
	onUnfit,
	settled,
	spotAt,
} from "./terminalRig";
import { Controls, open } from "./controls";
import { copySelection } from "./clipboard";
import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { GhosttyTrackedGridRef } from "../../vendor/ghostty/include/ghostty/vt.h";

test "a frame under synchronized output is not applied until the hold ends" {
	assert onFresh("abc\x1b[?2026h", (t: Term, sink: Sink): void => {
		const held = t.pumpFrame();
		assert held.ok;
		if (held.ok) {
			assert held.value.held;
			assert held.value.cursor === null;
			assert held.value.rows === null;
		}
		const s = t.session;
		assert s !== null;
		if (s !== null) { s.vt.writeText("\x1b[?2026l"); }
		const released = t.pumpFrame();
		assert released.ok;
		if (released.ok) {
			assert !released.value.held;
			assert released.value.cursor !== null;
			const rows = released.value.rows;
			assert rows !== null;
			if (rows !== null) {
				const view = View.open();
				view.fitRows(t.shown.length as int32);
				view.paint(rows);
				assert view.text(0) == "abc";
			}
		}
	}).ok;
}

test "a frame carries what the program asked of the host: a clipboard write, bells, a title, a notification, shell marks" {
	const asked = "\x1b]52;c;aGk=\x07\x07\x07\x1b]2;build done\x07\x1b]9;tests passed\x07" +
		"\x1b]133;D;0\x07\x1b]133;A\x07";
	assert onFresh(asked, (t: Term, sink: Sink): void => {
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.copied == "hi";
			assert frame.value.bells == 2;
			assert frame.value.title == "build done";
			assert frame.value.notifications.length == 1;
			assert frame.value.notifications[0].body == "tests passed";
			assert frame.value.shell.length == 2;
			assert frame.value.shell[1].step === ShellStep.Prompt;
			assert !frame.value.asked;
		}
		const next = t.pumpFrame();
		assert next.ok;
		if (next.ok) {
			assert next.value.copied === null;
			assert next.value.bells == 0;
			assert next.value.title === null;
			assert next.value.notifications.length == 0;
			assert next.value.shell.length == 0;
		}
	}).ok;
}

test "a frame that fails keeps what the program asked of the host for the next frame" {
	const asked = "\x1b]52;c;aGk=\x07\x07\x07\x1b]2;build done\x07\x1b]9;tests passed\x07\x1b]133;A\x07";
	assert onFresh(asked, (t: Term, sink: Sink): void => {
		t.shown.pop();
		const failed = t.pumpFrame();
		assert !failed.ok;
		t.shown.fitShown(5);
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.copied == "hi";
			assert frame.value.bells == 2;
			assert frame.value.title == "build done";
			assert frame.value.notifications.length == 1;
			assert frame.value.shell.length == 1;
		}
	}).ok;
}

test "a clipboard read that was asked in a failed frame is still asked in the next" {
	assert onFresh("\x1b]52;c;?\x07", (t: Term, sink: Sink): void => {
		t.shown.pop();
		assert !t.pumpFrame().ok;
		t.shown.fitShown(5);
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) { assert frame.value.asked; }
	}).ok;
}

test "planning rows for a grid shorter than the screen names the row that does not fit" {
	assert onFresh("abc", (t: Term, sink: Sink): void => {
		const s = t.session;
		assert s !== null;
		if (s !== null) {
			t.shown.pop();
			const planned = t.shown.planRows(s.vt, null, t.decor);
			assert !planned.ok;
			if (!planned.ok) { assert planned.error == FrameError.RowOutOfRange; }
		}
	}).ok;
}

test "a clipboard read waits in the frame and its answer goes out through the reply queue" {
	assert onFresh("\x1b]52;c;?\x07", (t: Term, sink: Sink): void => {
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) { assert frame.value.asked; }
		assert sink.sent == "";
		const s = t.session;
		assert s !== null;
		if (s !== null) { assert s.vt.answerClipboard("x", true).ok; }
		const sent = t.sendReplies();
		assert sent.ok;
		assert sink.sent == "\x1b]52;c;eA==\x07";
	}).ok;
}

test "text past ASCII reaches the program as the same text" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		assert t.sendText("hé").ok;
		assert sink.sent == "hé";
	}).ok;
}

test "focus reports go out only while the program asked for them" {
	assert onTerm("ready", (a: Term, off: Sink): void => {
		assert a.sendFocus(true).ok;
		assert off.sent == "";
	}).ok;
	assert onTerm("\x1b[?1004h", (b: Term, on: Sink): void => {
		assert b.sendFocus(true).ok;
		assert b.sendFocus(false).ok;
		assert on.sent == "\x1b[I\x1b[O";
	}).ok;
}

test "a mouse report is the program's encoding of the pointer, nothing while it asked for none" {
	const geometry = geometryOf(8, 16, 160, 80);
	const none = 0 as BitSet<KeyMod>;
	const press: MouseInput = { action: MouseAction.Press, button: MouseButton.Left, mods: none, x: 17, y: 17 };
	const release: MouseInput = { ...press, action: MouseAction.Release };
	assert onTerm("ready", (a: Term, quiet: Sink): void => {
		assert a.sendMouse(press, geometry).ok;
		assert quiet.sent == "";
	}).ok;
	assert onTerm("\x1b[?1000h\x1b[?1006h", (t: Term, sink: Sink): void => {
		assert t.sendMouse(press, geometry).ok;
		assert t.sendMouse(release, geometry).ok;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
	}).ok;
}

test "output drained ahead of the frame shows in the grid only when the frame applies it" {
	assert onUnfit("one\r\ntwo", (t: Term, sink: Sink): void => {
		assert t.fit(20, 3).ok;
		const view = View.open();
		view.fitRows(3);
		const drained = t.drain();
		assert drained.ok;
		if (drained.ok) { assert !drained.value; }
		assert !t.alive;
		assert view.text(0) == "";
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.ended;
			assert !frame.value.more;
			const rows = frame.value.rows;
			assert rows !== null;
			if (rows !== null) { view.paint(rows); }
		}
		assert view.text(0) == "one";
		assert view.text(1) == "two";
		const next = t.pumpFrame();
		assert next.ok;
		if (next.ok) { assert !next.value.ended; }
	}).ok;
}

test "a replayed recording fills the grid in one frame and ends the stream once" {
	assert onUnfit("one\r\n\x1b[31mtwo\x1b[0m", (t: Term, sink: Sink): void => {
		assert t.cols == 0;
		assert t.fit(20, 3).ok;
		assert t.cols == 20;
		assert t.shown.length == 3;
		const view = View.open();
		view.fitRows(3);
		const first = t.pumpFrame();
		assert first.ok;
		if (first.ok) {
			assert first.value.ended;
			assert !first.value.more;
			assert first.value.cursor !== null;
			const rows = first.value.rows;
			assert rows !== null;
			if (rows !== null) { view.paint(rows); }
		}
		assert view.text(0) == "one";
		assert view.text(1) == "two";
		assert view.grid.at(1).spans[0].text == "two";
		assert view.text(2) == "";
		const second = t.pumpFrame();
		assert second.ok;
		if (second.ok) { assert !second.value.ended; }
		assert !t.alive;
		assert t.shellExitCode() == 0;
	}).ok;
}

test "a pty that refuses to open names its cause in the error fit returns" {
	assert onRefused(PtyError.OpenBlankCommand, (t: Term): void => {
		const fitted = t.fit(80, 24);
		assert !fitted.ok;
		if (!fitted.ok) { assert fitted.error == TermError.PtyOpenBlankCommand; }
	}).ok;
	assert onRefused(PtyError.OpenTableFull, (t: Term): void => {
		const fitted = t.fit(80, 24);
		assert !fitted.ok;
		if (!fitted.ok) { assert fitted.error == TermError.PtyOpenTableFull; }
	}).ok;
}

test "input the program has not read past its limit is refused as backlogged, not as a broken write" {
	const pty: Pty = {
		...Replay.ofText("").toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			return Result.err(PtyError.Backlogged);
		},
		exitCode: (): int32 | null => { return null; },
	};
	assert onPty(pty, (): float64 => 0, 80, 24, (t: Term): void => {
		const sent = t.sendText("x");
		assert !sent.ok;
		if (!sent.ok) { assert sent.error == TermError.InputBacklogged; }
	}).ok;
}

const TINT: Rgb = { r: 58, g: 28, b: 36 };

function tintedYs(view: View, rows: int32): string {
	let out: string[] = [];
	for (let y = 0; y < rows; y++) {
		const runs = view.grid.at(y).line.runs;
		if (runs.length > 0 && runs[0].bg == TINT) { out.push(`${y}`); }
	}
	return out.join(",");
}

function paintedYs(view: View, frame: Result<Frame, TermError>): string {
	if (!frame.ok) { return "<failed>"; }
	const rows = frame.value.rows;
	if (rows === null) { return "<held>"; }
	view.paint(rows);
	return rows.rows.map((r: RowUpdate): string => `${r.y}`).join(",");
}

function failedBlock(marks: Readonly<Span<ShellMark>>): [int32, int32] {
	for (const m of marks) {
		if (m.step === ShellStep.CommandDone) { return [m.done.prompt ?? -1, m.done.end]; }
	}
	return [-1, -1];
}

test "a decoration tints its block's rows, moves up with them, and hides on the alternate screen" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		const view = View.open();
		view.fitRows(5);
		const first = t.pumpFrame();
		assert first.ok;
		if (!first.ok) { return; }
		const rows = first.value.rows;
		if (rows !== null) { view.paint(rows); }
		const block = failedBlock(first.value.shell);
		t.decor.decorate({ id: 1, from: block[0], to: block[1], tint: { fg: null, bg: TINT } });
		assert paintedYs(view, t.pumpFrame()) == "0,1";
		assert tintedYs(view, 5) == "0,1";
		const s = t.session;
		assert s !== null;
		if (s === null) { return; }
		s.vt.writeText("a\r\nb\r\nc\r\nd");
		assert !paintedYs(view, t.pumpFrame()).split(",").includes("0");
		assert view.text(0) == "oops";
		assert tintedYs(view, 5) == "0";
		s.vt.writeText("\x1b[?1049h");
		paintedYs(view, t.pumpFrame());
		assert tintedYs(view, 5) == "";
		s.vt.writeText("\x1b[?1049l");
		paintedYs(view, t.pumpFrame());
		assert tintedYs(view, 5) == "0";
		t.decor.undecorate(1);
		assert paintedYs(view, t.pumpFrame()) == "0";
		assert tintedYs(view, 5) == "";
	}).ok;
}

function notedYs(view: View, rows: int32): string {
	let out: string[] = [];
	for (let y = 0; y < rows; y++) {
		if (view.text(y).endsWith("exit 1")) { out.push(`${y}`); }
	}
	return out.join(",");
}

const EXIT_NOTE: RowNote = { text: "exit 1", fg: null, bg: null };

test "an annotation sits on its anchor's row, moves up with it, and hides on the alternate screen" {
	const ran = "x\r\n" +
		"\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		const view = View.open();
		view.fitRows(5);
		const first = t.pumpFrame();
		assert first.ok;
		if (!first.ok) { return; }
		const rows = first.value.rows;
		if (rows !== null) { view.paint(rows); }
		const block = failedBlock(first.value.shell);
		t.decor.annotate({ id: 1, at: block[0], note: EXIT_NOTE });
		assert paintedYs(view, t.pumpFrame()) == "1";
		assert view.text(1) == "$ false       exit 1", view.text(1);
		const s = t.session;
		assert s !== null;
		if (s === null) { return; }
		s.vt.writeText("a\r\nb\r\nc");
		assert !paintedYs(view, t.pumpFrame()).split(",").includes("0");
		assert notedYs(view, 5) == "0";
		s.vt.writeText("\x1b[?1049h");
		paintedYs(view, t.pumpFrame());
		assert notedYs(view, 5) == "";
		s.vt.writeText("\x1b[?1049l");
		paintedYs(view, t.pumpFrame());
		assert notedYs(view, 5) == "0";
		t.decor.unannotate(1);
		assert paintedYs(view, t.pumpFrame()) == "0";
		assert notedYs(view, 5) == "";
	}).ok;
}

test "copying a row that carries an annotation returns only the row's own text" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		const first = t.pumpFrame();
		assert first.ok;
		if (!first.ok) { return; }
		t.decor.annotate({ id: 1, at: failedBlock(first.value.shell)[0], note: EXIT_NOTE });
		const view = View.open();
		view.fitRows(5);
		paintedYs(view, t.pumpFrame());
		assert notedYs(view, 5) == "0";
		const c = Controls.open();
		const board = boardOf("");
		assert drag(c, t, board, spotAt(0, 0), spotAt(19, 0));
		assert handled(settled(board, c, t, c.copySelection(t)));
		assert board.copied == "$ false", board.copied;
	}).ok;
}

interface Pending {
	blocked: boolean;
	sent: string;
}

function blockable(state: Pending): Pty {
	return {
		...Replay.ofText("").toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			if (state.blocked) { return Result.err(PtyError.Backlogged); }
			state.sent += data.asString();
			return Result.ok(null);
		},
		exitCode: (): int32 | null => { return null; },
	};
}

test "a reply refused as backlogged stays queued until a write takes it" {
	const state: Pending = { blocked: true, sent: "" };
	assert onPty(blockable(state), (): float64 => 0, 20, 5, (t: Term): void => {
		const s = t.session;
		assert s !== null;
		if (s === null) { return; }
		s.vt.writeText("\x1b[5n");
		assert !t.sendReplies().ok;
		state.blocked = false;
		assert t.sendReplies().ok;
		assert state.sent == "\x1b[0n";
		assert t.sendReplies().ok;
		assert state.sent == "\x1b[0n";
	}).ok;
}

test "a reply the program has not read past its limit is refused as backlogged, not as a broken write" {
	const state: Pending = { blocked: true, sent: "" };
	assert onPty(blockable(state), (): float64 => 0, 20, 5, (t: Term): void => {
		const s = t.session;
		assert s !== null;
		if (s === null) { return; }
		s.vt.writeText("\x1b[5n");
		const sent = t.sendReplies();
		assert !sent.ok;
		if (!sent.ok) { assert sent.error == TermError.InputBacklogged; }
	}).ok;
}

interface Ticks {
	at: float64;
}

test "a drain reads the clock the terminal was opened with to spend its budget" {
	const ticks: Ticks = { at: 0 };
	const now = (): float64 => {
		ticks.at += 10;
		return ticks.at;
	};
	assert onPty(Replay.ofText("ab").toPty(), now, 20, 5, (t: Term): void => {
		const more = t.drain();
		assert more.ok;
		if (more.ok) { assert more.value; }
	}).ok;
}

test "shutting a terminal down twice frees its handles once" {
	assert onTerm("ready", (t: Term, sink: Sink): void => {
		t.shutdown();
		t.shutdown();
		assert t.session === null;
	}).ok;
}

test "a failed decoration pass keeps the tints on screen and is retried by the next frame" {
	const ran = "\x1b]133;A\x07$ false\r\n\x1b]133;C\x07oops\r\n\x1b]133;D;1\x07\x1b]133;A\x07$ ";
	assert onFresh(ran, (t: Term, sink: Sink): void => {
		const first = t.pumpFrame();
		assert first.ok;
		if (!first.ok) { return; }
		const block = failedBlock(first.value.shell);
		t.decor.decorate({ id: 1, from: block[0], to: block[1], tint: { fg: null, bg: TINT } });
		assert t.pumpFrame().ok;
		assert t.decor.tints[0] !== null;
		const s = t.session;
		assert s !== null;
		if (s === null) { return; }
		let saved: Vec<GhosttyTrackedGridRef> = [];
		for (const a of s.vt.effects.anchors) { saved.push(a.tracked); }
		const bad = 0 as GhosttyTrackedGridRef;
		for (let i = 0; i < s.vt.effects.anchors.length; i++) {
			s.vt.effects.anchors[i].tracked = bad;
		}
		t.decor.decorate({ id: 2, from: block[0], to: block[1], tint: { fg: null, bg: TINT } });
		const failed = t.pumpFrame();
		for (let i = 0; i < s.vt.effects.anchors.length; i++) {
			s.vt.effects.anchors[i].tracked = saved[i];
		}
		assert !failed.ok;
		assert t.decor.stale;
		assert t.decor.tints[0] !== null;
		assert t.pumpFrame().ok;
		assert !t.decor.stale;
	}).ok;
}
