#!/usr/bin/env python3
"""Append-only storage guard for the upgradeable contracts. See check-storage-layout.sh."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SNAP_DIR = ROOT / "storage-layout"
CONTRACTS = [
    ("src/new_perp/src/core/Market.sol", "Market"),
    ("src/new_perp/src/core/Vault.sol", "Vault"),
    ("src/P2PTokenEscrow.sol", "P2PTokenEscrows"),
    ("src/AmxSale.sol", "AmxSale"),
    ("src/AmxVault.sol", "AmxVault"),
    ("src/AmxVaultTestERC20.sol", "AmxVaultTestERC20"),
]


def current_layout(path: str, name: str) -> list:
    out = subprocess.run(
        ["forge", "inspect", f"{path}:{name}", "storage-layout", "--json"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout
    data = json.loads(out)
    types = data["types"]
    # Compare the human-readable type label, NOT the type id: ids embed AST node numbers that
    # change whenever unrelated source is edited, which would cause false alarms.
    return [
        {
            "label": s["label"],
            "slot": s["slot"],
            "offset": s["offset"],
            "type": types[s["type"]]["label"],
            "bytes": types[s["type"]]["numberOfBytes"],
        }
        for s in data["storage"]
    ]


def update() -> int:
    SNAP_DIR.mkdir(exist_ok=True)
    for path, name in CONTRACTS:
        rows = current_layout(path, name)
        (SNAP_DIR / f"{name}.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(f"recorded storage-layout/{name}.json ({len(rows)} variables)")
    return 0


def check() -> int:
    failed = False
    for path, name in CONTRACTS:
        snap_file = SNAP_DIR / f"{name}.json"
        if not snap_file.exists():
            print(f"MISSING snapshot {snap_file.name} (run with --update once)")
            failed = True
            continue
        snap = json.loads(snap_file.read_text())
        cur = current_layout(path, name)
        problems = []
        for i, old in enumerate(snap):
            if i >= len(cur):
                problems.append(f"  REMOVED  #{i} {old['label']} ({old['type']}) was at slot {old['slot']}")
            elif cur[i] != old:
                new = cur[i]
                problems.append(
                    f"  CHANGED  #{i} was {old['label']}: {old['type']} @slot {old['slot']}+{old['offset']}"
                    f"   now {new['label']}: {new['type']} @slot {new['slot']}+{new['offset']}"
                )
        if problems:
            failed = True
            print(f"FAIL {name}: storage layout is NOT append-only")
            print("\n".join(problems))
        else:
            extra = len(cur) - len(snap)
            print(f"ok   {name}: {len(snap)} recorded variables unchanged" + (f", {extra} appended" if extra else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(update() if "--update" in sys.argv[1:] else check())
