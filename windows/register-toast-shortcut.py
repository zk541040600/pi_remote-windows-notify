from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path


CLSCTX_INPROC_SERVER = 0x1
STGM_READWRITE = 0x00000002
VT_LPWSTR = 31
S_OK = 0
HRESULT = ctypes.c_long


class GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", wintypes.DWORD),
        ("Data2", wintypes.WORD),
        ("Data3", wintypes.WORD),
        ("Data4", ctypes.c_ubyte * 8),
    ]

    def __init__(self, value: str):
        super().__init__()
        ole32 = ctypes.OleDLL("ole32")
        hr = ole32.CLSIDFromString(wintypes.LPCWSTR(value), ctypes.byref(self))
        if hr != S_OK:
            raise OSError(f"CLSIDFromString failed for {value}: 0x{hr & 0xffffffff:08x}")


class PROPERTYKEY(ctypes.Structure):
    _fields_ = [("fmtid", GUID), ("pid", wintypes.DWORD)]


class PROPVARIANT(ctypes.Structure):
    _fields_ = [
        ("vt", wintypes.USHORT),
        ("wReserved1", wintypes.USHORT),
        ("wReserved2", wintypes.USHORT),
        ("wReserved3", wintypes.USHORT),
        ("pwszVal", wintypes.LPWSTR),
    ]


CLSID_ShellLink = GUID("{00021401-0000-0000-C000-000000000046}")
IID_IShellLinkW = GUID("{000214F9-0000-0000-C000-000000000046}")
IID_IPersistFile = GUID("{0000010b-0000-0000-C000-000000000046}")
IID_IPropertyStore = GUID("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
PKEY_AppUserModel_ID = PROPERTYKEY(GUID("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"), 5)


def _check(hr: int, label: str) -> None:
    if hr != S_OK:
        raise OSError(f"{label} failed: 0x{hr & 0xffffffff:08x}")


def _vtbl(obj: ctypes.c_void_p):
    return ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents


def _release(obj: ctypes.c_void_p) -> None:
    if not obj:
        return
    release = ctypes.WINFUNCTYPE(wintypes.ULONG, ctypes.c_void_p)(_vtbl(obj)[2])
    release(obj)


def _query_interface(obj: ctypes.c_void_p, iid: GUID) -> ctypes.c_void_p:
    out = ctypes.c_void_p()
    query = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p))(_vtbl(obj)[0])
    _check(query(obj, ctypes.byref(iid), ctypes.byref(out)), "QueryInterface")
    return out


def _call_string(obj: ctypes.c_void_p, index: int, value: str, label: str) -> None:
    fn = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, wintypes.LPCWSTR)(_vtbl(obj)[index])
    _check(fn(obj, value), label)


def create_shortcut(shortcut_path: Path, target_path: str, arguments: str, workdir: str, icon: str, app_id: str) -> None:
    shortcut_path.parent.mkdir(parents=True, exist_ok=True)
    ole32 = ctypes.OleDLL("ole32")
    ole32.CoInitialize(None)
    shell_link = ctypes.c_void_p()
    try:
        _check(
            ole32.CoCreateInstance(
            ctypes.byref(CLSID_ShellLink),
            None,
            CLSCTX_INPROC_SERVER,
            ctypes.byref(IID_IShellLinkW),
            ctypes.byref(shell_link),
            ),
            "CoCreateInstance(ShellLink)",
        )

        persist_file = ctypes.c_void_p()
        property_store = ctypes.c_void_p()
        # IShellLinkW vtable indexes after IUnknown: SetWorkingDirectory=9,
        # SetArguments=11, SetIconLocation=17, SetPath=20.
        _call_string(shell_link, 20, target_path, "IShellLinkW.SetPath")
        _call_string(shell_link, 11, arguments, "IShellLinkW.SetArguments")
        _call_string(shell_link, 9, workdir, "IShellLinkW.SetWorkingDirectory")
        icon_location, icon_index = (icon, 0)
        if "," in icon:
            icon_location, raw_index = icon.rsplit(",", 1)
            try:
                icon_index = int(raw_index)
            except ValueError:
                icon_index = 0
        set_icon = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, wintypes.LPCWSTR, ctypes.c_int)(_vtbl(shell_link)[17])
        _check(set_icon(shell_link, icon_location, icon_index), "IShellLinkW.SetIconLocation")

        property_store = _query_interface(shell_link, IID_IPropertyStore)
        prop_value = PROPVARIANT(VT_LPWSTR, 0, 0, 0, app_id)
        set_value = ctypes.WINFUNCTYPE(
            HRESULT,
            ctypes.c_void_p,
            ctypes.POINTER(PROPERTYKEY),
            ctypes.POINTER(PROPVARIANT),
        )(_vtbl(property_store)[6])
        commit = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p)(_vtbl(property_store)[7])
        _check(set_value(property_store, ctypes.byref(PKEY_AppUserModel_ID), ctypes.byref(prop_value)), "IPropertyStore.SetValue(AppUserModelID)")
        _check(commit(property_store), "IPropertyStore.Commit")

        persist_file = _query_interface(shell_link, IID_IPersistFile)
        save = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, wintypes.LPCWSTR, wintypes.BOOL)(_vtbl(persist_file)[6])
        _check(save(persist_file, str(shortcut_path), True), "IPersistFile.Save")
    finally:
        if 'property_store' in locals():
            _release(property_store)
        if 'persist_file' in locals():
            _release(persist_file)
        _release(shell_link)
        ole32.CoUninitialize()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shortcut", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--arguments", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--icon", required=True)
    parser.add_argument("--app-id", default="Pi Remote")
    args = parser.parse_args()

    shortcut_path = Path(args.shortcut)
    create_shortcut(shortcut_path, args.target, args.arguments, args.workdir, args.icon, args.app_id)
    print(shortcut_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
