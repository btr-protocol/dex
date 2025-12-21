import { Popover } from '@components/ui/Popover';
import type { HealthStatus } from '@/hooks/useHealthMonitor';

interface HealthPopoverProps {
  api: HealthStatus;
  static: HealthStatus;
  rpc: HealthStatus;
  chainName?: string;
  children: preact.ComponentChildren;
}

function StatusBeacon({ status }: { status: 'healthy' | 'degraded' | 'down' }) {
  const color = status === 'healthy' ? 'var(--green)' : status === 'degraded' ? 'var(--yellow)' : 'var(--red)';

  return (
    <div className="relative w-2 h-2 shrink-0">
      {/* Pulsing animation */}
      <div
        className="absolute inset-0 rounded-full animate-ping opacity-75"
        style={{ backgroundColor: color }}
      />
      {/* Static dot */}
      <div
        className="absolute inset-0 rounded-full"
        style={{ backgroundColor: color }}
      />
    </div>
  );
}

function getStatusColor(status: 'healthy' | 'degraded' | 'down'): string {
  return status === 'healthy' ? 'var(--green)' : status === 'degraded' ? 'var(--yellow)' : 'var(--red)';
}

function HealthRow({ label, status }: { label: string; status: HealthStatus }) {
  const color = getStatusColor(status.status);

  return (
    <div className="flex items-center justify-between gap-3 py-0.5">
      <span className="text-muted-foreground text-xs">{label}</span>
      <div className="flex items-center gap-1.5">
        <StatusBeacon status={status.status} />
        <span
          className="text-xs font-mono w-10 text-right"
          style={{ color }}
        >
          {status.latency !== null ? `${status.latency}ms` : '—'}
        </span>
      </div>
    </div>
  );
}

export function HealthPopover({ api, static: staticHealth, rpc, chainName, children }: HealthPopoverProps) {
  return (
    <Popover
      side="top"
      content={
        <div className="w-44">
          <div className="text-sm font-medium text-foreground pb-1.5 mb-1.5 border-b border-border">
            System Status
          </div>
          <div className="space-y-1">
            <HealthRow label="API" status={api} />
            <HealthRow label="CDN" status={staticHealth} />
            <HealthRow label={`RPC${chainName ? ` (${chainName})` : ''}`} status={rpc} />
          </div>
        </div>
      }
    >
      {children}
    </Popover>
  );
}
