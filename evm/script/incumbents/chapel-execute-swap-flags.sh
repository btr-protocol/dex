#!/usr/bin/env bash
# Execute queued SWAP|LIABILITY_SWAP risk flags on Chapel BTR pools, then smoke USDC→USDT.
# Queued 2026-07-10 ~21:18–21:21 UTC via Admin.requestUpdateRiskConfig (deployed Admin uses
# prod LOW_TIMELOCK = 1 day — bytecode predates shared govDelay chapel shortcut).
# ETA: 2026-07-11 ~21:18–21:21 UTC. Run after that window.
#
# Usage: cd dex/evm && source .env.chapel && ./script/incumbents/chapel-execute-swap-flags.sh
set -euo pipefail
RPC="${CHAPEL_RPC:-https://bsc-testnet.drpc.org}"
ADMIN=0x35c625c07ed4a9123ab863f6e8722c9210c808A3
STABLE=0x029EdAb049776633A9A7B49F87C5c97De5164ccE
VOL=0xEaB818235028bE378c92115099fF206EBb11B621
USDC=0x6dF80a290E0585dad752c25f2808E83b5624290d
USDT=0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64
GAS=100000000
PK="${DEPLOYER_PK:?set DEPLOYER_PK}"
SIG='executeUpdateRiskConfig(address,address)'

exec_one() {
  local pool=$1 name=$2 tok=$3
  echo "EXECUTE $name on $pool"
  cast send "$ADMIN" "$SIG" "$pool" "$tok" \
    --private-key "$PK" --rpc-url "$RPC" --gas-price "$GAS" --legacy --timeout 120 \
    | grep -E 'transactionHash|status|Error|Revert' | head -5
  cast call "$pool" "getRiskFlags(address)(uint16)" "$tok" --rpc-url "$RPC"
}

echo "=== STABLE ==="
exec_one "$STABLE" USDC "$USDC"
exec_one "$STABLE" USDT "$USDT"
exec_one "$STABLE" USD1 0xC28bE4D407096E771F932c202F13D866B4d6BA07
exec_one "$STABLE" USDE 0xebF751546832ec77a039083E9FDd8158B21c0172
exec_one "$STABLE" FDUSD 0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc

echo "=== VOLATILE ==="
exec_one "$VOL" USDC "$USDC"
exec_one "$VOL" USDT "$USDT"
exec_one "$VOL" BTCB 0xd719319e853670ac938e426fbdB70CFdb34c11Fa
exec_one "$VOL" ETH 0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189
exec_one "$VOL" WBNB 0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D
exec_one "$VOL" CAKE 0xa7E62dd82789346bEb48a80227B5d926c6403400
exec_one "$VOL" XAUT 0xd384aC4696FA230c9049F6534Fc35aC3af586073

echo "=== smoke swap 1 USDC → USDT (stable) ==="
AMT=1000000000000000000
cast send "$USDC" "approve(address,uint256)" "$STABLE" "$AMT" \
  --private-key "$PK" --rpc-url "$RPC" --gas-price "$GAS" --legacy --timeout 120 \
  | grep -E 'transactionHash|status' | head -3
# minOut=0 for smoke; recipient=deployer
DEP=$(cast wallet address --private-key "$PK")
cast send "$STABLE" "swap(address,address,uint256,uint256,address)" \
  "$USDC" "$USDT" "$AMT" 0 "$DEP" \
  --private-key "$PK" --rpc-url "$RPC" --gas-price "$GAS" --legacy --timeout 120 \
  | grep -E 'transactionHash|status|Error|Revert' | head -8

echo DONE
