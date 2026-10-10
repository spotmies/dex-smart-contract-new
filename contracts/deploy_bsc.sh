#!/bin/bash

# BSC Deployment and Verification Script
# Usage: ./deploy_bsc.sh <network>
# Example: ./deploy_bsc.sh testnet

NETWORK=$1

if [ "$NETWORK" == "mainnet" ]; then
    RPC_URL="https://bsc-dataseed.binance.org/"
    CHAIN_ID=56
    USDC_ADDRESS="0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d"
    echo "Deploying to BSC Mainnet..."
elif [ "$NETWORK" == "testnet" ]; then
    RPC_URL="https://data-seed-prebsc-1-s1.binance.org:8545/"
    CHAIN_ID=97
    # For testnet, you might need to deploy a mock USDC first or use an existing one
    USDC_ADDRESS=${USDC_ADDRESS:-""}
    echo "Deploying to BSC Testnet..."
else
    echo "Please specify network: mainnet or testnet"
    echo "Usage: ./deploy_bsc.sh <mainnet|testnet>"
    exit 1
fi

# Load variables from .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY is not set in .env"
    exit 1
fi

# Market and Vault are upgradeable (beacon proxies). Someone must own the right to upgrade them,
# and it must never default to the deployer key. See script/lib/UpgradeAuthority.sol.
if [ -z "$UPGRADE_ADMIN" ] && [ -z "$UPGRADE_TIMELOCK_DELAY" ] && [ "$ALLOW_DEPLOYER_UPGRADE_ADMIN" != "true" ]; then
    echo "Error: upgrade authority is not configured. Set ONE of:"
    echo "  UPGRADE_ADMIN=<address>          an existing Safe / timelock that will own the beacons"
    echo "  UPGRADE_TIMELOCK_DELAY=<secs>    deploy a TimelockController (e.g. 172800 = 48h);"
    echo "                                   UPGRADE_PROPOSER=<address> may propose/execute (default: deployer)"
    echo "  ALLOW_DEPLOYER_UPGRADE_ADMIN=true   TESTNET ONLY: makes the deployer key the upgrade owner"
    exit 1
fi

if [ -z "$USDC_ADDRESS" ]; then
    echo "Error: USDC_ADDRESS is not set. For testnet, please set it in your .env or as an environment variable."
    exit 1
fi

if [ -z "$BSCSCAN_API_KEY" ]; then
    echo "Warning: BSCSCAN_API_KEY is not set. Contract verification will be skipped."
    VERIFY_FLAG=""
else
    VERIFY_FLAG="--verify --etherscan-api-key $BSCSCAN_API_KEY"
fi

# Run deployment
forge script script/DeployNewPerpBSC.s.sol:DeployNewPerpBSC \
    --rpc-url $RPC_URL \
    --broadcast \
    $VERIFY_FLAG \
    --optimizer-runs 200 \
    -vvvv

echo "Deployment finished!"
