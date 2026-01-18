export interface WSMessage {
  type: string;
  data?: any;
  done?: boolean;
}

export function sendWs(ws: WebSocket, type: string, data?: any, done?: boolean): void {
  ws.send(JSON.stringify({ type, data, done }));
}
