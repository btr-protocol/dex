#!/usr/bin/env bash
# Start Anvil with Ethereum mainnet fork and persistent state
set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Config
FORK_BLOCK=${FORK_BLOCK:-21000000}
STATE_FILE=${STATE_FILE:-/tmp/anvil-state}
PORT=${PORT:-8545}
CHAIN_ID=${CHAIN_ID:-1}

# Check for RPC URL
if [ -z "$ETH_RPC_URL" ]; then
    echo -e "${YELLOW}⚠️  ETH_RPC_URL not set. Using Alchemy default...${NC}"
    echo -e "${YELLOW}    Set it with: export ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY${NC}"
    exit 1
fi

echo -e "${GREEN}=== Starting Anvil with Mainnet Fork ===${NC}\n"
echo -e "${BLUE}Configuration:${NC}"
echo "  Fork Block:  $FORK_BLOCK"
echo "  State File:  $STATE_FILE"
echo "  Port:        $PORT"
echo "  Chain ID:    $CHAIN_ID"
echo "  RPC URL:     ${ETH_RPC_URL:0:50}..."
echo ""

# Create state directory if it doesn't exist
mkdir -p "$(dirname $STATE_FILE)"

# Clean old state if requested
if [ "$1" = "--clean" ]; then
    echo -e "${YELLOW}🗑️  Cleaning old state...${NC}"
    rm -f $STATE_FILE
fi

echo -e "${GREEN}🚀 Starting Anvil...${NC}\n"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}\n"

# Start Anvil
anvil \
    --fork-url "$ETH_RPC_URL" \
    --fork-block-number "$FORK_BLOCK" \
    --state "$STATE_FILE" \
    --state-interval 10 \
    --port "$PORT" \
    --chain-id "$CHAIN_ID" \
    --accounts 10 \
    --balance 10000 \
    --gas-limit 30000000 \
    --code-size-limit 50000 \
    --block-time 12
