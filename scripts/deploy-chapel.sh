#!/usr/bin/env bash
# Chapel one-shot: TestnetDeploy → propagate → IncumbentsDeploy
# Usage:
#   1. Fund DEPLOYER with ≥0.3 tBNB (BSC Chapel faucet)
#   2. cd dex && source evm/.env.chapel   # or export DEPLOYER_PK=0x...
#   3. ./scripts/deploy-chapel.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/evm"

if [[ -f .env.chapel ]]; then
  # shellcheck disable=SC1091
  set -a; source .env.chapel; set +a
fi
: "${DEPLOYER_PK:?set DEPLOYER_PK (or create evm/.env.chapel)}"

ADDR="$(cast wallet address --private-key "$DEPLOYER_PK")"
BAL="$(cast balance "$ADDR" --rpc-url chapel)"
echo "Deployer: $ADDR"
echo "Balance:  $BAL wei"
if [[ "$BAL" == "0" ]]; then
  echo "ERROR: fund $ADDR with ≥0.3 tBNB on Chapel, then re-run."
  echo "Faucet: https://www.bnbchain.org/en/testnet-faucet"
  exit 1
fi

export DEPLOY_OUT="${DEPLOY_OUT:-deployments/97.deploy.json}"
export INCUMBENTS_OUT="${INCUMBENTS_OUT:-deployments/97.incumbents.json}"
export DEPLOY_JSON="$DEPLOY_OUT"

# Pick first responsive Chapel RPC (override with CHAPEL_RPC=...)
if [[ -z "${CHAPEL_RPC:-}" ]]; then
  for cand in \
    https://bsc-testnet.drpc.org \
    https://data-seed-prebsc-2-s1.bnbchain.org:8545 \
    https://data-seed-prebsc-1-s2.bnbchain.org:8545 \
    https://data-seed-prebsc-1-s1.binance.org:8545
  do
    if cast block-number --rpc-url "$cand" >/dev/null 2>&1; then
      CHAPEL_RPC="$cand"
      break
    fi
  done
fi
: "${CHAPEL_RPC:?no responsive Chapel RPC}"
RPC="$CHAPEL_RPC"
echo "RPC: $RPC"

echo "==> TestnetDeploy (chapel)"
forge script script/TestnetDeploy.s.sol:TestnetDeploy \
  --sig deployTestnet \
  --rpc-url "$RPC" \
  --broadcast \
  --skip-simulation \
  -vv

if [[ -f scripts/propagate-deploy.ts ]]; then
  echo "==> propagate-deploy 97"
  bun scripts/propagate-deploy.ts 97 || true
fi

if [[ -f "$DEPLOY_OUT" ]]; then
  export USDC; USDC="$(jq -r .usdc "$DEPLOY_OUT")"
  export USDT; USDT="$(jq -r .usdt "$DEPLOY_OUT")"
  export USD1; USD1="$(jq -r .usd1 "$DEPLOY_OUT")"
  export USDE; USDE="$(jq -r .usde "$DEPLOY_OUT")"
  export FDUSD; FDUSD="$(jq -r .fdusd "$DEPLOY_OUT")"
fi

echo "==> IncumbentsDeploy (chapel)"
forge script script/incumbents/IncumbentsDeploy.s.sol:IncumbentsDeploy \
  --sig deployIncumbents \
  --rpc-url "$RPC" \
  --broadcast \
  --skip-simulation \
  -vv

echo "Done."
echo "  $DEPLOY_OUT"
echo "  $INCUMBENTS_OUT"
