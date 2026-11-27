// slotmod.dll - injected into a running Slotbound.exe. No game files are touched.
// Hooks love.dll's in-memory import of lua_touserdata/lua_gettop. When called on the
// game's main thread, it periodically runs slotmod.lua's tick function.
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

typedef struct lua_State lua_State;
typedef void *(*fn_touserdata)(lua_State *, int);
typedef int (*fn_gettop)(lua_State *);
typedef int (*fn_loadfile)(lua_State *, const char *);
typedef int (*fn_pcall)(lua_State *, int, int, int);
typedef const char *(*fn_tolstring)(lua_State *, int, size_t *);
typedef void (*fn_settop)(lua_State *, int);
typedef int (*fn_ref)(lua_State *, int);
typedef void (*fn_rawgeti)(lua_State *, int, int);
typedef int (*fn_type)(lua_State *, int);
typedef int (*fn_checkstack)(lua_State *, int);
#define LUA_REGISTRYINDEX (-10000)

static fn_touserdata r_touserdata;
static fn_gettop r_gettop;
static fn_loadfile r_loadfile;
static fn_pcall r_pcall;
static fn_tolstring r_tolstring;
static fn_settop r_settop;
static fn_ref r_ref;
static fn_rawgeti r_rawgeti;
static fn_type r_type;
static fn_checkstack r_checkstack;

static DWORD g_mainTid;
static volatile LONG g_busy;
static ULONGLONG g_last;
static int g_tickref = -2; // -2 not loaded, -1 disabled
static int g_errors;
static char g_dir[MAX_PATH];
static int g_reload;

static void logmsg(const char *msg) {
    char p[MAX_PATH];
    snprintf(p, sizeof p, "%sslotmod_log.txt", g_dir);
    FILE *f = fopen(p, "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
}

static ULONGLONG g_mtime;
static ULONGLONG file_mtime(void) {
    char p[MAX_PATH];
    WIN32_FILE_ATTRIBUTE_DATA a;
    snprintf(p, sizeof p, "%sslotmod.lua", g_dir);
    if (!GetFileAttributesExA(p, GetFileExInfoStandard, &a)) return 0;
    return ((ULONGLONG)a.ftLastWriteTime.dwHighDateTime << 32) | a.ftLastWriteTime.dwLowDateTime;
}

static void tick(lua_State *L) {
    static ULONGLONG lastcheck;
    ULONGLONG now = GetTickCount64();
    if (now - lastcheck > 1000) {          // hot reload when slotmod.lua changes
        lastcheck = now;
        ULONGLONG mt = file_mtime();
        if (mt && mt != g_mtime) {
            if (g_mtime) logmsg("slotmod.lua changed, reloading");
            g_mtime = mt; g_tickref = -2; g_errors = 0;
        }
    }
    if (g_tickref == -1 || !r_checkstack(L, 8)) return;
    int top = r_gettop(L);
    if (g_tickref == -2) {
        char p[MAX_PATH];
        snprintf(p, sizeof p, "%sslotmod.lua", g_dir);
        if (r_loadfile(L, p) != 0 || r_pcall(L, 0, 1, 0) != 0) {
            const char *e = r_tolstring(L, -1, NULL);
            logmsg(e ? e : "load error");
            g_tickref = -1; r_settop(L, top); return;
        }
        if (r_type(L, -1) != 6) { logmsg("slotmod.lua must return a function"); g_tickref = -1; r_settop(L, top); return; }
        g_tickref = r_ref(L, LUA_REGISTRYINDEX);
        logmsg("slotmod.lua loaded");
    }
    r_rawgeti(L, LUA_REGISTRYINDEX, g_tickref);
    if (r_pcall(L, 0, 0, 0) != 0) {
        const char *e = r_tolstring(L, -1, NULL);
        logmsg(e ? e : "tick error");
        if (++g_errors > 30) { logmsg("too many errors, mod disabled"); g_tickref = -1; }
    }
    r_settop(L, top);
}

static void maybe_tick(lua_State *L) {
    if (GetCurrentThreadId() != g_mainTid || g_busy) return;
    ULONGLONG now = GetTickCount64();
    if (now - g_last < 100) return;
    g_last = now;
    g_busy = 1;
    tick(L);
    g_busy = 0;
}

static void *hk_touserdata(lua_State *L, int idx) { maybe_tick(L); return r_touserdata(L, idx); }
static int hk_gettop(lua_State *L) { maybe_tick(L); return r_gettop(L); }

static int patch_iat(HMODULE mod, const char *dll, const char *name, void *hook) {
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
    int n = 0;
    for (; imp->Name; imp++) {
        if (_stricmp((char *)(base + imp->Name), dll)) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *addrs = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            IMAGE_IMPORT_BY_NAME *ibn = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
            if (strcmp((char *)ibn->Name, name)) continue;
            DWORD old;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), PAGE_READWRITE, &old);
            addrs->u1.Function = (ULONG_PTR)hook;
            VirtualProtect(&addrs->u1.Function, sizeof(void *), old, &old);
            n++;
        }
    }
    return n;
}

static DWORD find_main_thread(void) {
    DWORD pid = GetCurrentProcessId(), best = 0;
    ULONGLONG bestTime = ~0ULL;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te = {sizeof te};
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid) continue;
        HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, te.th32ThreadID);
        if (!h) continue;
        FILETIME c, e, k, u;
        if (GetThreadTimes(h, &c, &e, &k, &u)) {
            ULONGLONG t = ((ULONGLONG)c.dwHighDateTime << 32) | c.dwLowDateTime;
            if (t < bestTime) { bestTime = t; best = te.th32ThreadID; }
        }
        CloseHandle(h);
    }
    CloseHandle(snap);
    return best;
}

static DWORD WINAPI setup(LPVOID self) {
    GetModuleFileNameA((HMODULE)self, g_dir, MAX_PATH);
    char *s = strrchr(g_dir, '\\');
    if (s) s[1] = 0;
    HMODULE lua = GetModuleHandleA("lua51.dll"), love = GetModuleHandleA("love.dll");
    if (!lua || !love) { logmsg("lua51.dll/love.dll not loaded yet"); return 1; }
#define G(v, n) v = (void *)GetProcAddress(lua, n)
    G(r_touserdata, "lua_touserdata"); G(r_gettop, "lua_gettop"); G(r_loadfile, "luaL_loadfile");
    G(r_pcall, "lua_pcall"); G(r_tolstring, "lua_tolstring"); G(r_settop, "lua_settop");
    G(r_ref, "luaL_ref"); G(r_rawgeti, "lua_rawgeti"); G(r_type, "lua_type"); G(r_checkstack, "lua_checkstack");
    g_mainTid = find_main_thread();
    int n = patch_iat(love, "lua51.dll", "lua_touserdata", hk_touserdata);
    n += patch_iat(love, "lua51.dll", "lua_gettop", hk_gettop);
    char m[128];
    snprintf(m, sizeof m, "slotmod injected, main thread %lu, %d hooks", g_mainTid, n);
    logmsg(m);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID x) {
    (void)x;
    if (r == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        CloseHandle(CreateThread(NULL, 0, setup, h, 0, NULL));
    }
    return TRUE;
}
