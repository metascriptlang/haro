#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>

#include "nativePty.h"

#define PTY_MAX 16
#define READ_LIMIT (4 << 20)
#define BATCH_KEEP (4 << 20)

typedef struct {
	int used;
	HPCON console;
	HANDLE input;
	HANDLE output;
	HANDLE process;
	HANDLE reader;
	HANDLE waiter;
	HANDLE writer;
	HANDLE ready;
	CRITICAL_SECTION lock;
	CONDITION_VARIABLE space;
	CONDITION_VARIABLE pending;
	uint8_t* data;
	int64_t head;
	int64_t len;
	int64_t cap;
	uint8_t* out;
	int64_t outLen;
	int64_t outCap;
	int writeFailed;
	int stopping;
	int closed;
	int outOfMemory;
	int exited;
	int exitCode;
	int consoleClosed;
} Pty;

static Pty ptys[PTY_MAX];
static void (*wakeApp)(void);

typedef HRESULT (WINAPI *CreateFn)(COORD, HANDLE, HANDLE, DWORD, HPCON*);
typedef HRESULT (WINAPI *ResizeFn)(HPCON, COORD);
typedef void (WINAPI *CloseFn)(HPCON);

static struct { CreateFn create; ResizeFn resize; CloseFn close; } api;

static void loadApi(void) {
	if (api.create) return;
	HMODULE dll = LoadLibraryExW(L"conpty.dll", NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
	CreateFn create = dll ? (CreateFn)(void*)GetProcAddress(dll, "CreatePseudoConsole") : NULL;
	ResizeFn resize = dll ? (ResizeFn)(void*)GetProcAddress(dll, "ResizePseudoConsole") : NULL;
	CloseFn close = dll ? (CloseFn)(void*)GetProcAddress(dll, "ClosePseudoConsole") : NULL;
	if (create && resize && close) {
		api.resize = resize;
		api.close = close;
		api.create = create;
		return;
	}
	api.resize = ResizePseudoConsole;
	api.close = ClosePseudoConsole;
	api.create = CreatePseudoConsole;
}

void ptySetWake(void (*wake)(void)) {
	wakeApp = wake;
}

static void wake(void) {
	if (wakeApp) wakeApp();
}

static int append(Pty* p, const uint8_t* bytes, int64_t n) {
	EnterCriticalSection(&p->lock);
	while (!p->stopping && p->len - p->head + n > READ_LIMIT) {
		SleepConditionVariableCS(&p->space, &p->lock, INFINITE);
	}
	if (p->stopping) {
		LeaveCriticalSection(&p->lock);
		return 1;
	}
	if (p->head > 0 && p->len + n > p->cap) {
		memmove(p->data, p->data + p->head, (size_t)(p->len - p->head));
		p->len -= p->head;
		p->head = 0;
	}
	if (p->len + n > p->cap) {
		int64_t cap = p->cap ? p->cap : 65536;
		while (cap < p->len + n) cap *= 2;
		uint8_t* grown = realloc(p->data, (size_t)cap);
		if (!grown) {
			p->outOfMemory = 1;
			SetEvent(p->ready);
			LeaveCriticalSection(&p->lock);
			wake();
			return 0;
		}
		p->data = grown;
		p->cap = cap;
	}
	memcpy(p->data + p->len, bytes, (size_t)n);
	p->len += n;
	SetEvent(p->ready);
	LeaveCriticalSection(&p->lock);
	wake();
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
	SetEvent(p->ready);
	LeaveCriticalSection(&p->lock);
	wake();
	return 0;
}

static DWORD WINAPI writeLoop(LPVOID arg) {
	Pty* p = arg;
	uint8_t* batch = NULL;
	int64_t batchCap = 0;
	EnterCriticalSection(&p->lock);
	for (;;) {
		while (!p->stopping && p->outLen == 0) {
			SleepConditionVariableCS(&p->pending, &p->lock, INFINITE);
		}
		if (p->stopping) break;
		uint8_t* full = p->out;
		int64_t fullCap = p->outCap;
		int64_t n = p->outLen;
		p->out = batch;
		p->outCap = batchCap;
		p->outLen = 0;
		batch = full;
		batchCap = fullCap;
		LeaveCriticalSection(&p->lock);
		int ok = 1;
		for (int64_t done = 0; ok && done < n;) {
			DWORD wrote = 0;
			DWORD want = n - done > (1 << 30) ? (1 << 30) : (DWORD)(n - done);
			ok = WriteFile(p->input, batch + done, want, &wrote, NULL);
			done += wrote;
		}
		if (batchCap > BATCH_KEEP) {
			free(batch);
			batch = NULL;
			batchCap = 0;
		}
		EnterCriticalSection(&p->lock);
		if (!ok) p->writeFailed = 1;
	}
	LeaveCriticalSection(&p->lock);
	free(batch);
	return 0;
}

static void closeConsole(Pty* p) {
	EnterCriticalSection(&p->lock);
	int already = p->consoleClosed;
	p->consoleClosed = 1;
	LeaveCriticalSection(&p->lock);
	if (!already) api.close(p->console);
}

static DWORD WINAPI waitLoop(LPVOID arg) {
	Pty* p = arg;
	WaitForSingleObject(p->process, INFINITE);
	DWORD code = 0;
	GetExitCodeProcess(p->process, &code);
	EnterCriticalSection(&p->lock);
	p->exitCode = (int)code;
	p->exited = 1;
	LeaveCriticalSection(&p->lock);
	closeConsole(p);
	return 0;
}

static Pty* slot(int id) {
	if (id < 0 || id >= PTY_MAX || !ptys[id].used) return NULL;
	return &ptys[id];
}

static wchar_t* widened(const char* text) {
	int len = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
	wchar_t* wide = len > 0 ? malloc(sizeof(wchar_t) * (size_t)len) : NULL;
	if (wide && !MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, len)) {
		free(wide);
		return NULL;
	}
	return wide;
}

static wchar_t* expanded(wchar_t* text) {
	if (!text) return NULL;
	DWORD len = ExpandEnvironmentStringsW(text, NULL, 0);
	wchar_t* out = len > 0 ? malloc(sizeof(wchar_t) * len) : NULL;
	if (out && ExpandEnvironmentStringsW(text, out, len) != len) {
		free(out);
		out = NULL;
	}
	free(text);
	return out;
}

int ptyOpen(const char* commandLine, const char* cwd, int cols, int rows) {
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
	loadApi();
	if (FAILED(api.create(size, inRead, outWrite, 0, &console))) {
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
	wchar_t* wide = expanded(widened(commandLine));
	wchar_t* wideCwd = cwd[0] != '\0' ? widened(cwd) : NULL;
	PROCESS_INFORMATION pi;
	memset(&pi, 0, sizeof pi);
	int ok = attrs && wide && (cwd[0] == '\0' || wideCwd)
		&& InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize)
		&& UpdateProcThreadAttribute(
			attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, sizeof console, NULL, NULL)
		&& CreateProcessW(
			NULL, wide, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, wideCwd,
			&si.StartupInfo, &pi);
	if (attrs) {
		DeleteProcThreadAttributeList(attrs);
		free(attrs);
	}
	free(wide);
	free(wideCwd);
	if (!ok) {
		api.close(console);
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
	InitializeConditionVariable(&p->space);
	InitializeConditionVariable(&p->pending);
	p->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (p->ready) p->reader = CreateThread(NULL, 0, readLoop, p, 0, NULL);
	if (p->reader) p->waiter = CreateThread(NULL, 0, waitLoop, p, 0, NULL);
	if (p->waiter) p->writer = CreateThread(NULL, 0, writeLoop, p, 0, NULL);
	if (!p->writer) {
		ptyClose(id);
		return -1;
	}
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
	int64_t held = p->len - p->head;
	int64_t n = held < cap ? held : cap;
	if (n > 0) {
		memcpy(buf, p->data + p->head, (size_t)n);
		p->head += n;
		if (p->head == p->len) p->head = p->len = 0;
		WakeConditionVariable(&p->space);
	}
	int ended = p->closed && p->len == 0;
	if (p->len == 0 && !p->closed) ResetEvent(p->ready);
	LeaveCriticalSection(&p->lock);
	if (n == 0 && ended) return -1;
	return n;
}

int ptyWait(int id, int timeoutMs) {
	Pty* p = slot(id);
	if (!p) return -1;
	DWORD r = WaitForSingleObject(p->ready, (DWORD)timeoutMs);
	if (r == WAIT_OBJECT_0) return 1;
	if (r == WAIT_TIMEOUT) return 0;
	return -2;
}

int64_t ptyWrite(int id, const uint8_t* data, int64_t len) {
	Pty* p = slot(id);
	if (!p) return -1;
	EnterCriticalSection(&p->lock);
	if (p->writeFailed) {
		LeaveCriticalSection(&p->lock);
		return -1;
	}
	if (p->outLen + len > p->outCap) {
		int64_t cap = p->outCap ? p->outCap : 4096;
		while (cap < p->outLen + len) cap *= 2;
		uint8_t* grown = realloc(p->out, (size_t)cap);
		if (!grown) {
			LeaveCriticalSection(&p->lock);
			return -2;
		}
		p->out = grown;
		p->outCap = cap;
	}
	memcpy(p->out + p->outLen, data, (size_t)len);
	p->outLen += len;
	WakeConditionVariable(&p->pending);
	LeaveCriticalSection(&p->lock);
	return len;
}

int ptyResize(int id, int cols, int rows) {
	Pty* p = slot(id);
	if (!p) return -1;
	COORD size = { (SHORT)cols, (SHORT)rows };
	EnterCriticalSection(&p->lock);
	int resized = !p->consoleClosed && SUCCEEDED(api.resize(p->console, size));
	LeaveCriticalSection(&p->lock);
	return resized ? 0 : -1;
}

int ptyExited(int id) {
	Pty* p = slot(id);
	if (!p) return 0;
	EnterCriticalSection(&p->lock);
	int exited = p->exited;
	LeaveCriticalSection(&p->lock);
	return exited;
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
	EnterCriticalSection(&p->lock);
	p->stopping = 1;
	WakeAllConditionVariable(&p->space);
	WakeAllConditionVariable(&p->pending);
	LeaveCriticalSection(&p->lock);
	TerminateProcess(p->process, 1);
	if (p->waiter) {
		WaitForSingleObject(p->waiter, INFINITE);
	} else {
		closeConsole(p);
	}
	if (p->writer) WaitForSingleObject(p->writer, INFINITE);
	CloseHandle(p->input);
	if (p->reader) WaitForSingleObject(p->reader, INFINITE);
	CloseHandle(p->output);
	if (p->reader) CloseHandle(p->reader);
	if (p->waiter) CloseHandle(p->waiter);
	if (p->writer) CloseHandle(p->writer);
	CloseHandle(p->process);
	if (p->ready) CloseHandle(p->ready);
	DeleteCriticalSection(&p->lock);
	free(p->data);
	free(p->out);
	memset(p, 0, sizeof *p);
}
