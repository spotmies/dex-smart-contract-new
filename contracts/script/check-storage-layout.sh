#!/usr/bin/env bash
# Guards the one rule that, if broken, silently corrupts live funds' bookkeeping after an upgrade:
# storage must be APPEND-ONLY. Run it before every upgrade, and wire it into CI.
#
#   script/check-storage-layout.sh            verify the current source against the snapshots
#   script/check-storage-layout.sh --update   re-record snapshots AFTER an upgrade has shipped
#
# Passing means every variable in the snapshot is still at the same slot/offset with the same
# type; new variables APPENDED after the last one are allowed (and are what an upgrade adds).
# Failing means a variable was moved, removed, retyped, or inserted above an existing one.
exec python3 "$(dirname "$0")/check-storage-layout.py" "$@"
