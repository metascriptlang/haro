#ifndef HARO_VT_EFFECTS_H
#define HARO_VT_EFFECTS_H

#include <stdint.h>
#include <ghostty/vt.h>

const GhosttyAllocator* vtAllocator(void);
int vtEffectsWire(GhosttyTerminal terminal, void* effects);

#endif
