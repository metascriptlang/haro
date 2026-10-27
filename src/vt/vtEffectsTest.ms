import {
	Rgb,
	Vt,
	VtError,
	answerClipboard,
	clipboardAsked,
	create,
	free,
	palette,
	pwd,
	setDefaultColors,
	takeClipboard,
	takeEvents,
	takeReplies,
	title,
	update,
	write,
	writeText,
} from "./vt";
import { NOTIFICATION_BODY_BYTES, NOTIFICATION_TITLE_BYTES } from "./vtEffects";
import { pushAll } from "./vtNative";
import { ascii, withVt } from "./vtRig";

test "a cursor position query is answered with the cursor's place" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("ab\x1b[6n");
		assert vt.pending() == "\x1b[1;3R";
	});
}

test "bells, a title and a pwd reach the host as events once each" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x07a\x07\x1b]2;build: ok\x07\x1b]7;file:///C:/Users/me\x07");
		const first = vt.takeEvents();
		assert first.bells == 2;
		assert first.titleChanged;
		assert first.pwdChanged;
		const title = vt.title();
		assert title.ok;
		if (title.ok) { assert title.value == "build: ok"; }
		const pwd = vt.pwd();
		assert pwd.ok;
		if (pwd.ok) { assert pwd.value == "file:///C:/Users/me"; }
		const second = vt.takeEvents();
		assert second.bells == 0;
		assert !second.titleChanged;
		assert !second.pwdChanged;
	});
}

test "a desktop notification reaches the host once, by OSC 9 with a body and OSC 777 with a title" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]9;build done\x07");
		const nine = vt.takeEvents().notification;
		assert nine !== null;
		if (nine !== null) {
			assert nine.title == "";
			assert nine.body == "build done";
		}
		vt.writeText("\x1b]777;notify;make;all green\x07");
		const rxvt = vt.takeEvents().notification;
		assert rxvt !== null;
		if (rxvt !== null) {
			assert rxvt.title == "make";
			assert rxvt.body == "all green";
		}
		assert vt.takeEvents().notification === null;
	});
}

test "a notification's text stops at its cap on a character, and bytes that are not UTF-8 read as U+FFFD" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText(`\x1b]777;notify;${"t".repeat(300)};${"中".repeat(400)}\x07`);
		const long = vt.takeEvents().notification;
		assert long !== null;
		if (long !== null) {
			assert long.title == "t".repeat(NOTIFICATION_TITLE_BYTES);
			assert long.body == "中".repeat(NOTIFICATION_BODY_BYTES / 3);
		}
		let bytes: Vec<uint8> = [];
		pushAll(bytes, "\x1b]9;a".asBytes());
		for (const b of [0xff, 0x62, 0xe4, 0xb8, 0x63, 0xed, 0xa0, 0x80, 0x07]) { bytes.push(b as uint8); }
		vt.write(bytes);
		const broken = vt.takeEvents().notification;
		assert broken !== null;
		if (broken !== null) { assert broken.body == "a\u{fffd}b\u{fffd}\u{fffd}c\u{fffd}\u{fffd}\u{fffd}"; }
	});
}

function replyTo(query: string): string {
	const created = Vt.create(20, 4);
	if (!created.ok) { return "create failed"; }
	const vt = created.value;
	defer vt.free();
	vt.writeText(query);
	const replied = vt.pending();
	return replied;
}

test "the device attributes and the version name Haro as a VT220 with colour and clipboard" {
	assert replyTo("\x1b[c") == "\x1b[?62;22;52c";
	assert replyTo("\x1b[>c") == "\x1b[>1;10;0c";
	assert replyTo("\x1b[>q") == "\x1bP>|haro\x1b\\";
}

test "the tertiary device attributes carry a zero unit id" {
	assert replyTo("\x1b[=c") == "\x1bP!|00000000\x1b\\";
}

test "a mode report names a mode set, reset and unknown" {
	assert replyTo("\x1b[?2004$p") == "\x1b[?2004;2$y";
	assert replyTo("\x1b[?2004h\x1b[?2004$p") == "\x1b[?2004;1$y";
	assert replyTo("\x1b[?9999$p") == "\x1b[?9999;0$y";
}

test "colour queries answer with the host's defaults, a program's override and the palette" {
	assert replyTo("\x1b]11;?\x07") == "\x1b]11;rgb:0000/0000/0000\x07";
	assert replyTo("\x1b]10;?\x07") == "\x1b]10;rgb:ffff/ffff/ffff\x07";
	assert replyTo("\x1b]11;rgb:10/20/30\x07\x1b]11;?\x07") == "\x1b]11;rgb:1010/2020/3030\x07";
	assert replyTo("\x1b]4;1;?\x07") == "\x1b]4;1;rgb:cccc/6666/6666\x07";
}

test "a theme the host sets is what a colour query reports" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert vt.setDefaultColors({ r: 0x28, g: 0x2c, b: 0x34 }, { r: 0xff, g: 0xff, b: 0xfe }).ok;
		vt.writeText("\x1b]11;?\x1b\\");
		assert vt.pending() == "\x1b]11;rgb:ffff/ffff/fefe\x1b\\";
	});
}

function cursorColorAfter(text: string): Result<Rgb | null, VtError> {
	const vt = try Vt.create(20, 4);
	defer vt.free();
	vt.writeText(text);
	const updated = vt.update();
	const colors = vt.palette();
	if (!updated.ok || !colors.ok) { return Result.err(VtError.ReadFailed); }
	return Result.ok(colors.value.cursor);
}

test "a program sets the cursor colour with OSC 12 and resets it with OSC 112" {
	const red: Rgb = { r: 255, g: 0, b: 0 };
	const fresh = cursorColorAfter("");
	assert fresh.ok && fresh.value === null;
	const set = cursorColorAfter("\x1b]12;#ff0000\x07");
	assert set.ok && set.value == red;
	const reset = cursorColorAfter("\x1b]12;#ff0000\x07\x1b]112\x07");
	assert reset.ok && reset.value === null;
}

test "an OSC 52 write reaches the host once, and only for the standard clipboard" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;p;cHJpbWFyeQ==\x07");
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;c;aGVsbG8gd29ybGQ=\x07");
		assert vt.takeClipboard() == "hello world";
		assert vt.takeClipboard() === null;
		vt.writeText("\x1b]52;c;\x07");
		assert vt.takeClipboard() == "";
	});
}

function pending(this vt: Vt): string {
	const replies = vt.takeReplies();
	return ascii(replies);
}

test "a size query is answered with the terminal's own cells and pixels, as is the report mode 2048 starts with" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b[18t");
		assert vt.pending() == "\x1b[8;4;20t";
		vt.writeText("\x1b[14t\x1b[16t");
		assert vt.pending() == "\x1b[4;0;0t\x1b[6;0;0t";
		vt.writeText("\x1b[?2048h");
		assert vt.pending() == "\x1b[48;4;20;0;0t";
	});
}

test "an OSC 52 read waits for the host and is answered in the frame the program used" {
	assert withVt(20, 4, (vt: Vt): void => {
		assert !vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.pending() == "";
		assert vt.clipboardAsked();
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("hello", true).ok;
		assert vt.pending() == "\x1b]52;c;aGVsbG8=\x1b\\";
		assert !vt.answerClipboard("again", true).ok;
		vt.writeText("\x1b]52;c;?\x07");
		assert vt.clipboardAsked();
		assert vt.answerClipboard("secret", false).ok;
		assert vt.pending() == "\x1b]52;c;\x07";
	});
}

test "base64 in an OSC 52 answer pads one and two leftover bytes" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("ab", true).ok;
		assert vt.pending() == "\x1b]52;c;YWI=\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("a", true).ok;
		assert vt.pending() == "\x1b]52;c;YQ==\x1b\\";
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.answerClipboard("", true).ok;
		assert vt.pending() == "\x1b]52;c;\x1b\\";
	});
}

test "an OSC 5522 clipboard read is refused at once rather than waiting for an OSC 52 answer" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]5522;type=read:id=r1;dGV4dC9wbGFpbg==\x1b\\");
		assert !vt.clipboardAsked();
		assert vt.pending() == "\x1b]5522;type=read:status=EPERM:id=r1\x1b\\";
	});
}

test "clipboard writes while a read waits leave the waiting answer intact" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;YQ==\x1b\\\x1b]52;c;Yg==\x1b\\");
		assert vt.answerClipboard("hello", true).ok;
		assert vt.pending() == "\x1b]52;c;aGVsbG8=\x1b\\";
	});
}

test "a second read while one waits, and a primary-selection read, get an empty answer at once" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.clipboardAsked();
		vt.writeText("\x1b]52;c;?\x1b\\");
		assert vt.pending() == "\x1b]52;c;\x1b\\";
		assert !vt.clipboardAsked();
		assert vt.answerClipboard("x", true).ok;
		assert vt.pending() == "\x1b]52;c;eA==\x1b\\";
		vt.writeText("\x1b]52;p;?\x1b\\");
		assert vt.pending() == "\x1b]52;p;\x1b\\";
		assert !vt.clipboardAsked();
	});
}
