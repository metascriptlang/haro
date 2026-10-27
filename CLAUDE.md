# Haro

The repository is public (`github.com/metascriptlang/haro`). Tracked text, commit messages
included, names no terminal or project Haro took a design from, and no path on a developer's
machine, because a reader of a public repository takes a named source as copied code: describe
the behaviour itself, and keep design sources and their `file:line` anchors in the arc card under
`~/metascript/.wt/`. Named as usual: vendored code and test data with their licences
(libghostty-vt, the conformance fixtures), the protocols Haro speaks (xterm and DEC sequences,
OSC numbers, the kitty keyboard protocol, win32-input-mode), the OS parts it runs on (ConPTY,
conhost) and Haro's own stack (Neon, Void, Ion, msc).

## C or MetaScript

Write Haro's code in `.ms`, calls into C libraries and OS APIs included: declare them with
`extern` and `@include` their header, as `src/vt/vt.ms` does for libghostty-vt, because `.ms` is
checked by msc, tested by `msc test` and built for every target Haro has, the web build included,
while a C file is compiled for one.

Write C only for the part MetaScript cannot run safely or cannot express yet, and keep the rest
of that feature in `.ms`:

- A native thread's body, and the code between `fork` and `exec`: DRC counts are not atomic, and
  the runtime must not run in a forked child (`src/pty/conpty.c`, `src/pty/posixPty.c`).
- A construct msc cannot import or emit yet. Name its compiler card in a comment beside the C,
  and move the code into `.ms` when the card lands, because a shim with no card outlives its
  reason.

## Land gate

`scripts/gate.sh` is the gate every land passes: it runs `msc test --tests-in-dir` on each file
under `src` that holds a test. It finds those files itself, because a hand-kept list left out
`src/conform` and let a crash in libghostty-vt reach `main`. `--tests-in-dir` keeps the count to
Haro's own tests: `src/config` embeds the compiler, whose own tests fail when run inside Haro's
test binary and leave its state broken for the tests after them.
