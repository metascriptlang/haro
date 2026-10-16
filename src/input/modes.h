#ifndef HARO_INPUT_MODES_H
#define HARO_INPUT_MODES_H

#include <ghostty/vt.h>

#define INPUT_MOUSE_TRACKING 1
#define INPUT_ALT_SCROLL 2

/* The mouse modes an app has set, as INPUT_* bits, or -1 when the terminal refused a read. */
int inputMouseModes(GhosttyTerminal terminal);

#endif
