#!/usr/bin/env bash
# Sequential Chapel coverage deploy (one tx at a time — avoids forge multi-tx nonce races).
# Usage: cd dex/evm && source .env.chapel && ./script/incumbents/chapel-coverage-cast.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${DEPLOYER_PK:?}"
RPC="${RPC_URL:-https://bsc-testnet-rpc.publicnode.com}"
GP=100000000
ADDR=$(cast wallet address --private-key "$DEPLOYER_PK")
send() { cast send --private-key "$DEPLOYER_PK" --rpc-url "$RPC" --gas-price "$GP" --legacy "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }
sleep_r() { sleep 0.4; }

USDC=0x6dF80a290E0585dad752c25f2808E83b5624290d
USDT=0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64
BTCB=0xd719319e853670ac938e426fbdB70CFdb34c11Fa
ETH=0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189
WBNB=0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D
XAUT=0xd384aC4696FA230c9049F6534Fc35aC3af586073
FAUCET=0x6a901982CE6cD2561F677217e012A33b8a88EF27
UNIV2=0xD2F5488f1930Df661eceCbD4B122Ef767B6C92D4
RANGE_FAC=0x0f03EB0F1282594B3AE3A636fc835EEe8575765F
SEED=10000000000000000000000 # 10k ether
CURVE_A=100
CURVE_FEE=30000000 # 30 bps in 1e10
RANGE_FEE=3010
PX_BTCB=64300000000000000000000 # 64300e18
RANGE_BPS=1000

echo "Deployer $ADDR nonce=$(cast nonce "$ADDR" --rpc-url "$RPC") bal=$(cast balance "$ADDR" --rpc-url "$RPC")"

mint() {
  local tok=$1 amt=$2
  echo "mint $tok $amt"
  send "$tok" "mint(address,uint256)" "$ADDR" "$amt"
  sleep_r
}

echo "== mint inventory =="
for t in $USDC $USDT $BTCB $ETH $WBNB $XAUT; do
  mint "$t" $((40 * 10**22)) 2>/dev/null || mint "$t" 400000000000000000000000
done

# ── CurveStableSwap create via forge create ──────────────────────────────────
deploy_curve3() {
  local name=$1 c0=$2 c1=$3 c2=$4
  echo "== Curve $name =="
  # Encode constructor: address[] coins, uint256 A, uint256 fee
  # Use forge create with constructor args
  OUT=$(forge create src/incumbents/curve/CurveStableSwap.sol:CurveStableSwap \
    --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --gas-price "$GP" --legacy \
    --constructor-args "[$c0,$c1,$c2]" "$CURVE_A" "$CURVE_FEE" 2>&1)
  echo "$OUT" | tail -5
  POOL=$(echo "$OUT" | grep -oE 'Deployed to: 0x[0-9a-fA-F]+' | awk '{print $3}')
  if [[ -z "$POOL" ]]; then
    echo "FAIL deploy $name"; echo "$OUT"; exit 1
  fi
  echo "pool=$POOL"
  send "$c0" "approve(address,uint256)" "$POOL" "$SEED"; sleep_r
  send "$c1" "approve(address,uint256)" "$POOL" "$SEED"; sleep_r
  send "$c2" "approve(address,uint256)" "$POOL" "$SEED"; sleep_r
  # add_liquidity(uint256[] amounts, uint256 minMint)
  send "$POOL" "add_liquidity(uint256[],uint256)" "[$SEED,$SEED,$SEED]" 0
  sleep_r
  echo "$name=$POOL"
  eval "${name}=$POOL"
}

deploy_curve3 CURVE_USDT_BNB_BTCB "$USDT" "$WBNB" "$BTCB"
deploy_curve3 CURVE_USDC_ETH_BTCB "$USDC" "$ETH" "$BTCB"

# ── UniV2 pairs ──────────────────────────────────────────────────────────────
seed_univ2() {
  local a=$1 b=$2 label=$3
  echo "== UniV2 $label =="
  PAIR=$(call "$UNIV2" "getPair(address,address)(address)" "$a" "$b")
  if [[ "$PAIR" == "0x0000000000000000000000000000000000000000" ]]; then
    send "$UNIV2" "createPair(address,address)" "$a" "$b"
    sleep_r
    PAIR=$(call "$UNIV2" "getPair(address,address)(address)" "$a" "$b")
  fi
  echo "pair=$PAIR"
  T0=$(call "$PAIR" "token0()(address)")
  T1=$(call "$PAIR" "token1()(address)")
  # strip [addr] formatting
  T0=${T0%% *}
  T1=${T1%% *}
  PAIR=${PAIR%% *}
  R=$(call "$PAIR" "getReserves()(uint112,uint112,uint32)")
  echo "reserves raw: $R"
  # Always top to SEED/SEED for empty or short — transfer SEED of each if r0/r1 low
  # Simplest: if either reserve < SEED, transfer enough to reach SEED on both for first mint
  R0=$(echo "$R" | head -1 | awk '{print $1}')
  # cast may print multi-line; use --json
  R0=$(cast call "$PAIR" "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC" | head -1 | tr -d '[]' | awk '{print $1}')
  # Fallback: just transfer SEED of each token and mint (works for empty; for non-empty adds liquidity)
  BAL0=$(cast call "$T0" "balanceOf(address)(uint256)" "$PAIR" --rpc-url "$RPC" | awk '{print $1}')
  BAL1=$(cast call "$T1" "balanceOf(address)(uint256)" "$PAIR" --rpc-url "$RPC" | awk '{print $1}')
  NEED0=$SEED
  NEED1=$SEED
  # if already >= SEED skip
  if [[ "$BAL0" -ge "$SEED" ]] 2>/dev/null && [[ "$BAL1" -ge "$SEED" ]] 2>/dev/null; then
    echo "already ≥10k"
    eval "UNI_${label}=$PAIR"
    return
  fi
  # For empty pair send SEED each; for partial, send gap
  python3 - <<PY
bal0=int("$BAL0".split()[0] if " " in "$BAL0" else "$BAL0".replace("[","").split()[0] if False else 0)
PY
  # Use cast to transfer SEED of each (overshoot ok for empty)
  send "$T0" "transfer(address,uint256)" "$PAIR" "$SEED"; sleep_r
  send "$T1" "transfer(address,uint256)" "$PAIR" "$SEED"; sleep_r
  send "$PAIR" "mint(address)" "$ADDR"
  sleep_r
  eval "UNI_${label}=$PAIR"
  echo "UNI_$label=$PAIR"
}

seed_univ2 "$BTCB" "$USDC" BTCB_USDC
seed_univ2 "$ETH" "$USDC" ETH_USDC
seed_univ2 "$WBNB" "$USDC" WBNB_USDC
seed_univ2 "$XAUT" "$USDC" XAUT_USDC
seed_univ2 "$BTCB" "$USDT" BTCB_USDT
seed_univ2 "$ETH" "$USDT" ETH_USDT
seed_univ2 "$WBNB" "$USDT" WBNB_USDT
seed_univ2 "$XAUT" "$USDT" XAUT_USDT

# ── RangeCL BTCB/USDC fee 3010 ───────────────────────────────────────────────
echo "== RangeCL BTCB/USDC fee=$RANGE_FEE =="
EXISTING=$(call "$RANGE_FAC" "getPool(address,address,uint24)(address)" "$BTCB" "$USDC" "$RANGE_FEE")
EXISTING=${EXISTING%% *}
if [[ "$EXISTING" == "0x0000000000000000000000000000000000000000" ]]; then
  send "$RANGE_FAC" "createPool(address,address,uint24)" "$BTCB" "$USDC" "$RANGE_FEE"
  sleep_r
fi
RANGE_BTCB=$(call "$RANGE_FAC" "getPool(address,address,uint24)(address)" "$BTCB" "$USDC" "$RANGE_FEE")
RANGE_BTCB=${RANGE_BTCB%% *}
echo "rangeBtcbUsdc=$RANGE_BTCB"
T0=$(call "$RANGE_BTCB" "token0()(address)"); T0=${T0%% *}
# price token1/token0
if [[ "${T0,,}" == "${BTCB,,}" ]]; then
  PRICE=$PX_BTCB
else
  # 1e36 / PX_BTCB
  PRICE=$(python3 -c "print(10**36 // $PX_BTCB)")
fi
SP=$(call "$RANGE_BTCB" "sqrtPriceX96()(uint160)" 2>/dev/null || echo 0)
SP=${SP%% *}
if [[ "$SP" == "0" || "$SP" == "0x0" || -z "$SP" ]]; then
  send "$BTCB" "approve(address,uint256)" "$RANGE_BTCB" "$SEED"; sleep_r
  send "$USDC" "approve(address,uint256)" "$RANGE_BTCB" "$SEED"; sleep_r
  if [[ "${T0,,}" == "${BTCB,,}" ]]; then
    A0=$SEED; A1=$SEED
  else
    A0=$SEED; A1=$SEED
  fi
  send "$RANGE_BTCB" "seed(uint256,uint256,uint256,uint256)" "$PRICE" "$RANGE_BPS" "$A0" "$A1"
  sleep_r
fi
# Ensure ERC20 balances ≥ SEED
for tok in $BTCB $USDC; do
  BAL=$(cast call "$tok" "balanceOf(address)(uint256)" "$RANGE_BTCB" --rpc-url "$RPC" | awk '{print $1}')
  echo "bal $tok = $BAL"
  python3 -c "import sys; sys.exit(0 if int('$BAL'.split()[0]) >= $SEED else 1)" 2>/dev/null || {
    GAP=$(python3 -c "print($SEED - int('$BAL'.split()[0]))")
    echo "top-up $tok gap=$GAP"
    send "$tok" "transfer(address,uint256)" "$RANGE_BTCB" "$GAP"
    sleep_r
  }
done

# ── XAUT faucet ──────────────────────────────────────────────────────────────
echo "== XAUT faucet =="
send "$FAUCET" "setCap(address,uint256)" "$XAUT" 1000000000000000000; sleep_r # 1 ether/day
send "$XAUT" "approve(address,uint256)" "$FAUCET" 1000000000000000000000; sleep_r
send "$FAUCET" "fund(address,uint256)" "$XAUT" 1000000000000000000000; sleep_r

# ── Persist ──────────────────────────────────────────────────────────────────
OUT=deployments/97.coverage.json
python3 - <<PY
import json
d={
  "chainId": 97,
  "curveUsdtBnbBtcb": "$CURVE_USDT_BNB_BTCB",
  "curveUsdcEthBtcb": "$CURVE_USDC_ETH_BTCB",
  "uniBtcbUsdc": "$UNI_BTCB_USDC",
  "uniEthUsdc": "$UNI_ETH_USDC",
  "uniWbnbUsdc": "$UNI_WBNB_USDC",
  "uniXautUsdc": "$UNI_XAUT_USDC",
  "uniBtcbUsdt": "$UNI_BTCB_USDT",
  "uniEthUsdt": "$UNI_ETH_USDT",
  "uniWbnbUsdt": "$UNI_WBNB_USDT",
  "uniXautUsdt": "$UNI_XAUT_USDT",
  "rangeBtcbUsdc": "$RANGE_BTCB",
  "uniV2Factory": "$UNIV2",
  "rangeFeeBtcb": $RANGE_FEE,
}
json.dump(d, open("$OUT","w"), indent=2)
print("wrote", "$OUT", json.dumps(d, indent=2))
PY

echo "DONE nonce=$(cast nonce "$ADDR" --rpc-url "$RPC")"
