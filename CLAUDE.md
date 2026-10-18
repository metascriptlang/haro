# Haro

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
