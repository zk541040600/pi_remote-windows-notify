from __future__ import annotations

import argparse
from pathlib import Path

from win32com.client import Dispatch
from win32com.propsys import propsys, pscon


def create_shortcut(shortcut_path: Path, target_path: str, arguments: str, workdir: str, icon: str, app_id: str) -> None:
    shell = Dispatch("WScript.Shell")
    shortcut = shell.CreateShortcut(str(shortcut_path))
    shortcut.TargetPath = target_path
    shortcut.Arguments = arguments
    shortcut.WorkingDirectory = workdir
    shortcut.IconLocation = icon
    shortcut.Save()

    store = propsys.SHGetPropertyStoreFromParsingName(str(shortcut_path), None, 2, propsys.IID_IPropertyStore)
    store.SetValue(pscon.PKEY_AppUserModel_ID, propsys.PROPVARIANTType(app_id))
    store.Commit()


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
    shortcut_path.parent.mkdir(parents=True, exist_ok=True)
    create_shortcut(shortcut_path, args.target, args.arguments, args.workdir, args.icon, args.app_id)
    print(shortcut_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
