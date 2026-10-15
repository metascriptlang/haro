#include "wake.h"
#include "../pty/conpty.h"

void ionWakeLoop(void);

void appWireWake(void) {
	ptySetWake(ionWakeLoop);
}
