import { Selection, Unit } from "../select/select";
import {
	Vt,
	create,
	free,
	scrollOffset,
	selectedText,
	selection,
	selectionClear,
	selectionSet,
	setScrollback,
	unitAt,
	update,
	writeText,
} from "./vt";
import {
	at,
	linefeedLines,
	marked,
	numberedLines,
	shown,
	withVt,
} from "./vtRig";

test "a selection across two wrapped rows copies one logical line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("abcdefghijklmnop\r\nnext");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 2, 1, 4)).ok;
		assert shown(vt.selectedText()) == "cdefghijklmno";
		assert vt.selectionSet(marked(0, 0, 2, 3)).ok;
		assert shown(vt.selectedText()) == "abcdefghijklmnop\nnext";
	});
}

test "trailing spaces are trimmed on each copied line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("hi   \r\nthere");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 1, 9)).ok;
		assert shown(vt.selectedText()) == "hi\nthere";
	});
}

test "a double click picks the word under the pointer and a triple click the logical line" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("foo bar-baz qux again");
		assert vt.update().ok;
		const word = vt.unitAt(Unit.Word, at(0, 5));
		assert word.ok;
		if (word.ok) {
			assert word.value.start == at(0, 4);
			const sel = Selection.press(Unit.Word, word.value, false);
			assert vt.selectionSet(sel.marked()).ok;
			assert shown(vt.selectedText()) == "bar-baz";
		}
		const line = vt.unitAt(Unit.Line, at(1, 3));
		assert line.ok;
		if (line.ok) {
			assert line.value.start == at(0, 0);
			assert vt.selectionSet({ range: line.value, block: false }).ok;
			assert shown(vt.selectedText()) == "foo bar-baz qux again";
		}
	});
}

test "a double click on either half of a wide character picks the whole word, and a blank cell after a word picks only itself" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("中文 x");
		assert vt.update().ok;
		for (const col of [0, 1, 2, 3]) {
			const word = vt.unitAt(Unit.Word, at(0, col));
			assert word.ok;
			if (word.ok) {
				assert word.value.start == at(0, 0);
				assert vt.selectionSet({ range: word.value, block: false }).ok;
				assert shown(vt.selectedText()) == "中文";
			}
		}
		const blank = vt.unitAt(Unit.Word, at(0, 6));
		assert blank.ok;
		if (blank.ok) {
			assert blank.value.start == at(0, 6) && blank.value.end == at(0, 6);
		}
	});
}

test "a selection survives five lines of new output" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText(numberedLines(4));
		assert vt.update().ok;
		assert vt.selectionSet(marked(1, 0, 2, 1)).ok;
		assert shown(vt.selectedText()) == "r1\nr2";
		vt.writeText("\r\nn0\r\nn1\r\nn2\r\nn3\r\nn4");
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) {
				assert m.range.start == at(1, 0);
				assert m.range.end == at(2, 1);
			}
		}
		assert shown(vt.selectedText()) == "r1\nr2";
	});
}

test "a selection follows its text when scrollback is pruned" {
	const created = Vt.create(80, 4);
	assert created.ok;
	if (created.ok) {
		const vt = created.value;
		assert vt.setScrollback(1000).ok;
		vt.writeText(numberedLines(6000));
		assert vt.update().ok;
		const row = (try vt.scrollOffset() catch 0) + 3;
		assert vt.selectionSet(marked(row, 0, row, 5)).ok;
		assert shown(vt.selectedText()) == "r5999";
		vt.writeText(linefeedLines(400));
		assert vt.update().ok;
		const kept = vt.selection();
		assert kept.ok;
		if (kept.ok) {
			const m = kept.value;
			assert m !== null;
			if (m !== null) { assert m.range.start.row < row; }
		}
		assert shown(vt.selectedText()) == "r5999";
		vt.free();
	}
}

test "an erased selection is gone from the terminal" {
	assert withVt(10, 4, (vt: Vt): void => {
		vt.writeText("hello");
		assert vt.update().ok;
		assert vt.selectionSet(marked(0, 0, 0, 4)).ok;
		vt.selectionClear();
		const none = vt.selection();
		assert none.ok;
		if (none.ok) { assert none.value === null; }
		assert shown(vt.selectedText()) == "<none>";
	});
}
