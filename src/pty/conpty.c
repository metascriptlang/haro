#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>

#include "conpty.h"

#define PTY_MAX 16

typedef struct {
	int used;
	HPCON console;
	HANDLE input;
	HANDLE output;
	HANDLE process;
	HANDLE reader;
	HANDLE waiter;
	CRITICAL_SECTION lock;
	uint8_t* data;
	int64_t len;
	int64_t cap;
	int closed;
	int outOfMemory;
	int exitCode;
	int consoleClosed;
} Pty;

static Pty ptys[PTY_MAX];

static int append(Pty* p, const uint8_t* bytes, int64_t n) {
	EnterCriticalSection(&p->lock);
	if (p->len + n > p->cap) {
		int64_t cap = p->cap ? p->cap : 65536;
		while (cap < p->len + n) cap *= 2;
		uint8_t* grown = realloc(p->data, (size_t)cap);
		if (!grown) {
			p->outOfMemory = 1;
			LeaveCriticalSection(&p->lock);
			return 0;
		}
		p->data = grown;
		p->cap = cap;
	}
	memcpy(p->data + p->len, bytes, (size_t)n);
	p->len += n;
	LeaveCriticalSection(&p->lock);
	return 1;
}

static DWORD WINAPI readLoop(LPVOID arg) {
	Pty* p = arg;
	uint8_t chunk[16384];
	DWORD got = 0;
	while (ReadFile(p->output, chunk, sizeof chunk, &got, NULL) && got > 0) {
		if (!append(p, chunk, got)) break;
	}
	EnterCriticalSection(&p->lock);
	p->closed = 1;
	LeaveCriticalSection(&p->lock);
	return 0;
}

static void closeConsole(Pty* p) {
	EnterCriticalSection(&p->lock);
	int already = p->consoleClosed;
	p->consoleClosed = 1;
	LeaveCriticalSection(&p->lock);
	if (!already) ClosePseudoConsole(p->console);
}

static DWORD WINAPI waitLoop(LPVOID arg) {
	Pty* p = arg;
	WaitForSingleObject(p->process, INFINITE);
	DWORD code = 0;
	GetExitCodeProcess(p->process, &code);
	EnterCriticalSection(&p->lock);
	p->exitCode = (int)code;
	LeaveCriticalSection(&p->lock);
	closeConsole(p);
	return 0;
}

static Pty* slot(int id) {
	if (id < 0 || id >= PTY_MAX || !ptys[id].used) return NULL;
	return &ptys[id];
}

int ptyOpen(const char* commandLine, int cols, int rows) {
	int id = -1;
	for (int i = 0; i < PTY_MAX; i++) {
		if (!ptys[i].used) { id = i; break; }
	}
	if (id < 0) return -1;

	HANDLE inRead = NULL, inWrite = NULL, outRead = NULL, outWrite = NULL;
	if (!CreatePipe(&inRead, &inWrite, NULL, 0)) return -1;
	if (!CreatePipe(&outRead, &outWrite, NULL, 0)) {
		CloseHandle(inRead);
		CloseHandle(inWrite);
		return -1;
	}

	COORD size = { (SHORT)cols, (SHORT)rows };
	HPCON console = NULL;
	if (FAILED(CreatePseudoConsole(size, inRead, outWrite, 0, &console))) {
		CloseHandle(inRead);
		CloseHandle(inWrite);
		CloseHandle(outRead);
		CloseHandle(outWrite);
		return -1;
	}
	CloseHandle(inRead);
	CloseHandle(outWrite);

	SIZE_T attrSize = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
	LPPROC_THREAD_ATTRIBUTE_LIST attrs = malloc(attrSize);
	STARTUPINFOEXW si;
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.lpAttributeList = attrs;
	int wideLen = MultiByteToWideChar(CP_UTF8, 0, commandLine, -1, NULL, 0);
	wchar_t* wide = malloc(sizeof(wchar_t) * (size_t)wideLen);
	PROCESS_INFORMATION pi;
	memset(&pi, 0, sizeof pi);
	int ok = attrs && wide
		&& InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize)
		&& UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, sizeof console, NULL, NULL)
		&& MultiByteToWideChar(CP_UTF8, 0, commandLine, -1, wide, wideLen)
		&& CreateProcessW(NULL, wide, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi);
	if (attrs) {
		DeleteProcThreadAttributeList(attrs);
		free(attrs);
	}
	free(wide);
	if (!ok) {
		ClosePseudoConsole(console);
		CloseHandle(inWrite);
		CloseHandle(outRead);
		return -1;
	}
	CloseHandle(pi.hThread);

	Pty* p = &ptys[id];
	memset(p, 0, sizeof *p);
	p->used = 1;
	p->console = console;
	p->input = inWrite;
	p->output = outRead;
	p->process = pi.hProcess;
	p->exitCode = -1;
	InitializeCriticalSection(&p->lock);
	p->reader = CreateThread(NULL, 0, readLoop, p, 0, NULL);
	p->waiter = CreateThread(NULL, 0, waitLoop, p, 0, NULL);
	return id;
}

int64_t ptyRead(int id, uint8_t* buf, int64_t cap) {
	Pty* p = slot(id);
	if (!p) return -1;
	EnterCriticalSection(&p->lock);
	if (p->outOfMemory) {
		LeaveCriticalSection(&p->lock);
		return -2;
	}
	int64_t n = p->len < cap ? p->len : cap;
	if (n > 0) {
		memcpy(buf, p->data, (size_t)n);
		memmove(p->data, p->data + n, (size_t)(p->len - n));
		p->len -= n;
	}
	int ended = p->closed && p->len == 0;
	LeaveCriticalSection(&p->lock);
	if (n == 0 && ended) return -1;
	return n;
}

int64_t ptyWrite(int id, const uint8_t* data, int64_t len) {
	Pty* p = slot(id);
	if (!p) return -1;
	DWORD wrote = 0;
	if (!WriteFile(p->input, data, (DWORD)len, &wrote, NULL)) return -1;
	return wrote;
}

int ptyResize(int id, int cols, int rows) {
	Pty* p = slot(id);
	if (!p) return -1;
	COORD size = { (SHORT)cols, (SHORT)rows };
	return SUCCEEDED(ResizePseudoConsole(p->console, size)) ? 0 : -1;
}

int ptyExitCode(int id) {
	Pty* p = slot(id);
	if (!p) return -1;
	EnterCriticalSection(&p->lock);
	int code = p->exitCode;
	LeaveCriticalSection(&p->lock);
	return code;
}

void ptyClose(int id) {
	Pty* p = slot(id);
	if (!p) return;
	TerminateProcess(p->process, 1);
	WaitForSingleObject(p->waiter, INFINITE);
	CloseHandle(p->input);
	WaitForSingleObject(p->reader, INFINITE);
	CloseHandle(p->output);
	CloseHandle(p->reader);
	CloseHandle(p->waiter);
	CloseHandle(p->process);
	DeleteCriticalSection(&p->lock);
	free(p->data);
	memset(p, 0, sizeof *p);
}
