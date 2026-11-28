#!/usr/bin/env python3
"""KR-MP Unified LuaJIT Syntax & Unit Test Runner.

Runs:
  1. Full LuaJIT syntax check across client/UH.lua and all client/kr_mp/*.lua.
  2. Every tests/verify_*.lua suite inside a fresh LuaJIT state.

Usage:
  python tools/run_unit_tests.py
  python tools/run_unit_tests.py --filter diagnostics
  python tools/run_unit_tests.py --lua-dll D:\\FL8.2.0\\lua51.dll
"""
import argparse
import ctypes
import glob
import os
import shutil
import sys


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_POSIX = REPO_ROOT.replace("\\", "/")


def find_lua_dll(explicit_path):
    candidates = []
    if explicit_path:
        candidates.append(explicit_path)
    env_dll = os.environ.get("KR_MP_LUA_DLL")
    if env_dll:
        candidates.append(env_dll)
    candidates.extend([
        r"D:\FL8.2.0\lua51.dll",
        os.path.join(os.path.dirname(REPO_ROOT), "FL8.2.0", "lua51.dll"),
        os.path.join(REPO_ROOT, "game-sandbox", "lua51.dll"),
    ])
    for p in candidates:
        if p and os.path.isfile(p):
            return p
    return None


def load_luajit(dll_path):
    dll = ctypes.CDLL(dll_path)
    dll.luaL_newstate.restype = ctypes.c_void_p
    dll.luaL_openlibs.argtypes = [ctypes.c_void_p]
    dll.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    dll.luaL_loadfile.restype = ctypes.c_int
    dll.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    dll.lua_pcall.restype = ctypes.c_int
    dll.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    dll.lua_tolstring.restype = ctypes.c_char_p
    dll.lua_close.argtypes = [ctypes.c_void_p]
    return dll


def run_syntax_check(dll):
    lua_files = sorted(
        [os.path.join(REPO_ROOT, "client", "UH.lua")]
        + glob.glob(os.path.join(REPO_ROOT, "client", "kr_mp", "*.lua"))
    )
    L = dll.luaL_newstate()
    dll.luaL_openlibs(L)
    errs = 0
    for f in lua_files:
        rc = dll.luaL_loadfile(L, f.encode("utf-8"))
        if rc != 0:
            err = dll.lua_tolstring(L, -1, None)
            msg = err.decode("utf-8", errors="replace") if err else str(rc)
            print(f"[SYNTAX FAIL] {os.path.relpath(f, REPO_ROOT)}: {msg}")
            errs += 1
    dll.lua_close(L)
    print(f"LuaJIT syntax check: {len(lua_files) - errs}/{len(lua_files)} OK")
    return errs == 0


def run_suites(dll, filter_substr):
    tests_dir = os.path.join(REPO_ROOT, "tests")
    suites = sorted(glob.glob(os.path.join(tests_dir, "verify_*.lua")))
    if filter_substr:
        fl = filter_substr.lower()
        suites = [s for s in suites if fl in os.path.basename(s).lower()]
    if not suites:
        print(f"[ERROR] No matching test suites found under {tests_dir}")
        return False

    tmp_dir = os.path.join(tests_dir, ".tmp_run")
    shutil.rmtree(tmp_dir, ignore_errors=True)
    os.makedirs(tmp_dir, exist_ok=True)
    os.environ["KR_MP_REPO_ROOT"] = REPO_POSIX
    os.environ["KR_MP_TEST_TMP"] = tmp_dir.replace("\\", "/")

    passed = 0
    failed = []
    try:
        for suite_path in suites:
            name = os.path.basename(suite_path)
            print(f"--- Running {name} ---")
            sys.stdout.flush()
            L = dll.luaL_newstate()
            dll.luaL_openlibs(L)
            rc = dll.luaL_loadfile(L, suite_path.encode("utf-8"))
            if rc != 0:
                err = dll.lua_tolstring(L, -1, None)
                msg = err.decode("utf-8", errors="replace") if err else str(rc)
                print(f"[LOAD ERR] {name}: {msg}")
                failed.append(name)
            else:
                rc2 = dll.lua_pcall(L, 0, 0, 0)
                if rc2 != 0:
                    err = dll.lua_tolstring(L, -1, None)
                    msg = err.decode("utf-8", errors="replace") if err else str(rc2)
                    print(f"[RUN ERR] {name}: {msg}")
                    failed.append(name)
                else:
                    passed += 1
            dll.lua_close(L)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        for stray in (
            os.path.join(REPO_ROOT, "kr_mp_prefs.json"),
            os.path.join(REPO_ROOT, "kr_mp_last_session.json"),
        ):
            if os.path.exists(stray):
                try:
                    os.remove(stray)
                except OSError:
                    pass

    print(f"\n=== KR-MP LUAJIT UNIT SUITES: {passed}/{len(suites)} PASSED ===")
    if failed:
        print("FAILED SUITES:", ", ".join(failed))
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Run KR-MP LuaJIT syntax checks and unit suites.")
    parser.add_argument("--lua-dll", default="", help="Path to FL 8.2.0 lua51.dll")
    parser.add_argument("--filter", default="", help="Substring filter for suite filenames")
    args = parser.parse_args()

    dll_path = find_lua_dll(args.lua_dll)
    if not dll_path:
        print("[ERROR] Could not locate FL 8.2.0 lua51.dll (pass --lua-dll or set KR_MP_LUA_DLL)")
        sys.exit(2)

    os.chdir(REPO_ROOT)
    dll = load_luajit(dll_path)
    ok_syn = run_syntax_check(dll)
    if not ok_syn:
        sys.exit(1)
    ok_suites = run_suites(dll, args.filter)
    sys.exit(0 if ok_suites else 1)


if __name__ == "__main__":
    main()
