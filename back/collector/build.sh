#!/bin/bash
# Build and run the market data collector

set -e

IMAGE_NAME="btr-collector"
CONTAINER_NAME="btr-collector"

# Build
echo "Building $IMAGE_NAME..."
docker build -t $IMAGE_NAME .

# Stop existing container if running
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true

# Run with persistent data volume
echo "Starting $CONTAINER_NAME..."
docker run -d \
  --name $CONTAINER_NAME \
  -p 3000:3000 \
  -v $(pwd)/data:/app/data \
  --restart unless-stopped \
  $IMAGE_NAME

echo ""
echo "Collector started!"
echo "  API:       http://localhost:3000/info"
echo "  Prices:    http://localhost:3000/api/price?symbol=agg:spot:ETHUSDT"
echo "  Candles:   http://localhost:3000/api/candles?symbol=ETHUSDT&timeframe=60"
echo "  WebSocket: ws://localhost:3000/ws"
echo ""
echo "Logs: docker logs -f $CONTAINER_NAME"
