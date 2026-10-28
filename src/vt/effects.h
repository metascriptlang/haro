#ifndef HARO_VT_EFFECTS_H
#define HARO_VT_EFFECTS_H

#include <stdint.h>
#include <ghostty/vt.h>

#ifdef __EMSCRIPTEN__
const GhosttyAllocator* vtAllocator(void);
#endif
int vtEffectsWire(GhosttyTerminal terminal, void* effects);

/* Defined in vtEffects.ms, which includes this header, so a signature that drifts fails the C compile. */
void haroVtWritePty(GhosttyTerminal terminal, void* effects, uint8_t* bytes, size_t n);
void haroVtBell(GhosttyTerminal terminal, void* effects);
void haroVtTitleChanged(GhosttyTerminal terminal, void* effects);
void haroVtPwdChanged(GhosttyTerminal terminal, void* effects);
void haroVtRenderHold(GhosttyTerminal terminal, void* effects, bool held);
bool haroVtDeviceAttributes(GhosttyTerminal terminal, void* effects, GhosttyDeviceAttributes* out);
bool haroVtSize(GhosttyTerminal terminal, void* effects, GhosttySizeReportSize* out);
void haroVtClipboardWritten(void* effects, uint8_t* text, int64_t n);
int64_t haroVtRepliesLength(void* effects);
void haroVtClipboardRead(void* effects, int64_t mark);
GhosttyString haroVtXtversion(GhosttyTerminal terminal, void* effects);
void haroVtDesktopNotification(GhosttyTerminal terminal, void* effects, GhosttyTerminalDesktopNotification* notification);

#endif
