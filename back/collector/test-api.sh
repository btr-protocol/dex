#!/bin/bash

# Test market data collector API

PORT=3001

echo "Starting collector server on port $PORT..."
PORT=$PORT bun src/server-main.ts > /tmp/collector.log 2>&1 &
COLLECTOR_PID=$!

# Wait for server to start
sleep 5

echo "=== Testing Collector API ==="
echo ""

echo "1. Server Info:"
curl -s http://localhost:$PORT/info | jq . || echo "Failed"

echo ""
echo "2. Historical Candles (ETHUSDT, 1m, limit=3):"
curl -s "http://localhost:$PORT/api/candles?symbol=ETHUSDT&timeframe=60&limit=3" | jq '.candles[] | {timestamp: .timestamp, open: .open, close: .close, high: .high}' || echo "Failed"

echo ""
echo "3. Current Price:"
curl -s "http://localhost:$PORT/api/price?symbol=agg:spot:ETHUSDT" | jq . || echo "Failed"

echo ""
echo "4. Health Check:"
curl -s http://localhost:$PORT/health

echo ""
echo "Stopping server..."
kill $COLLECTOR_PID 2>/dev/null
sleep 1

echo "✓ Tests complete"
