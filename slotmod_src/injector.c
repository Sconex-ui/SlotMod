// SlotMod.exe - starts the game if needed (Steam by default, see SlotMod.ini) and injects slotmod.dll.
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

static DWORD find_pid(const wchar_t *exe) {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W pe = {sizeof pe};
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
        if (!_wcsicmp(pe.szExeFile, exe)) { pid = pe.th32ProcessID; break; }
    CloseHandle(snap);
    return pid;
}

static int has_module(DWORD pid, const wchar_t *name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32W me = {sizeof me};
    int found = 0;
    for (BOOL ok = Module32FirstW(snap, &me); ok; ok = Module32NextW(snap, &me))
        if (!_wcsicmp(me.szModule, name)) { found = 1; break; }
    CloseHandle(snap);
    return found;
}

typedef struct { DWORD pid; int found; } WinFind;
static BOOL CALLBACK enum_win(HWND h, LPARAM lp) {
    WinFind *w = (WinFind *)lp;
    DWORD pid;
    GetWindowThreadProcessId(h, &pid);
    if (pid == w->pid && IsWindowVisible(h)) { w->found = 1; return FALSE; }
    return TRUE;
}

static void fail(const char *m) { MessageBoxA(NULL, m, "SlotMod", MB_ICONERROR); ExitProcess(1); }

int WINAPI WinMain(HINSTANCE a, HINSTANCE b, LPSTR c, int d) {
    (void)a; (void)b; (void)c; (void)d;
    wchar_t dir[MAX_PATH], dll[MAX_PATH], game[MAX_PATH];
    GetModuleFileNameW(NULL, dir, MAX_PATH);
    wcsrchr(dir, L'\\')[1] = 0;
    swprintf(dll, MAX_PATH, L"%sslotmod.dll", dir);
    if (GetFileAttributesW(dll) == INVALID_FILE_ATTRIBUTES) fail("slotmod.dll not found next to SlotMod.exe");

    DWORD pid = find_pid(L"Slotbound.exe");
    if (!pid) {
        // How to start the game: SlotMod.ini next to SlotMod.exe may contain
        //   [SlotMod]
        //   launch=<program path relative to the SlotMod folder, or a URL>
        // Default: start the game through Steam.
        wchar_t ini[MAX_PATH], launch[MAX_PATH], target[MAX_PATH];
        swprintf(ini, MAX_PATH, L"%sSlotMod.ini", dir);
        GetPrivateProfileStringW(L"SlotMod", L"launch", L"steam://rungameid/4459590", launch, MAX_PATH, ini);
        swprintf(game, MAX_PATH, L"%s..\\", dir);
        if (wcsstr(launch, L"://") || (launch[0] && launch[1] == L':')) wcscpy_s(target, MAX_PATH, launch);
        else swprintf(target, MAX_PATH, L"%s%s", dir, launch);
        wchar_t workdir[MAX_PATH];
        wcscpy_s(workdir, MAX_PATH, target);
        wchar_t *slash = wcsrchr(workdir, L'\\');
        if (slash && !wcsstr(launch, L"://")) slash[1] = 0; else wcscpy_s(workdir, MAX_PATH, game);
        if ((INT_PTR)ShellExecuteW(NULL, L"open", target, NULL, workdir, SW_SHOWNORMAL) <= 32)
            fail("Could not start the game. Start Slotbound yourself, then run SlotMod.exe again, or set launch= in SlotMod.ini.");
        for (int i = 0; i < 1200 && !(pid = find_pid(L"Slotbound.exe")); i++) Sleep(100);
        if (!pid) fail("Slotbound.exe did not start");
    }
    // wait until the game window is up and love.dll is loaded (startup checks are done by then)
    for (int i = 0; i < 1200; i++) {
        WinFind w = {pid, 0};
        EnumWindows(enum_win, (LPARAM)&w);
        if (w.found && has_module(pid, L"love.dll")) break;
        if (!find_pid(L"Slotbound.exe")) fail("Slotbound.exe exited");
        Sleep(100);
    }
    Sleep(3000);
    if (has_module(pid, L"slotmod.dll")) { MessageBoxA(NULL, "SlotMod is already loaded. Press F1 in game.", "SlotMod", MB_ICONINFORMATION); return 0; }

    HANDLE p = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!p) fail("OpenProcess failed (try running as the same user / admin)");
    size_t sz = (wcslen(dll) + 1) * sizeof(wchar_t);
    void *mem = VirtualAllocEx(p, NULL, sz, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    WriteProcessMemory(p, mem, dll, sz, NULL);
    LPTHREAD_START_ROUTINE ll = (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryW");
    HANDLE t = CreateRemoteThread(p, NULL, 0, ll, mem, 0, NULL);
    if (!t) fail("CreateRemoteThread failed");
    WaitForSingleObject(t, 10000);
    DWORD code = 0;
    GetExitCodeThread(t, &code);
    VirtualFreeEx(p, mem, 0, MEM_RELEASE);
    CloseHandle(t);
    CloseHandle(p);
    if (!code) fail("Injection failed (LoadLibrary returned NULL)");
    return 0;
}
