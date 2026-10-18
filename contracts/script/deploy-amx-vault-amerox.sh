#!/usr/bin/env bash
# Deploys AmxVault (behind a proxy, owned by a timelock) to Amero X with the settings that chain
# needs. Runs `forge script script/DeployAmxVault.s.sol` with everything else passed through, so
# add --rpc-url, --broadcast, etc. yourself (omit --broadcast for a dry run).
#
#   FOUNDRY_PROFILE=amerox  evm_version = london: Amero X has no PUSH0 / MCOPY / transient storage
#   --legacy               Amero X rejects EIP-1559 transactions
#   --skip ...             leave out the repo files that need a newer EVM (they import OZ code
#                          using MCOPY); none of them are part of the vault deployment
#
# After broadcasting, confirm each transaction from its receipt `status` (cast receipt <hash>):
# forge cannot parse this chain's receipts and may report an error even when it succeeded.
set -euo pipefail
cd "$(dirname "$0")/.."

FOUNDRY_PROFILE=amerox exec forge script script/DeployAmxVault.s.sol \
    --legacy \
    --skip test --skip MockERC20 --skip LimitOrder --skip DeployAll --skip DeployAmxVaultTestERC20 --skip DeployTokens \
    "$@"
