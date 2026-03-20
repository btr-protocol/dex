/**
 * HealthStore - Signal-based health monitoring state management
 * Replaces 1 complex useState object in useHealthMonitor.ts
 * Enables fine-grained updates (each endpoint updates independently)
 */
import { signal, computed } from '@preact/signals';

export interface HealthStatus {
  latency: number | null;
  status: 'healthy' | 'degraded' | 'down';
}

export class HealthStore {
  // Individual health status signals (fine-grained reactivity)
  public api = signal<HealthStatus>({
    latency: null,
    status: 'down',
  });

  public static = signal<HealthStatus>({
    latency: null,
    status: 'down',
  });

  public rpc = signal<HealthStatus>({
    latency: null,
    status: 'down',
  });

  // Computed: overall system health (worst status wins)
  public overallStatus = computed(() => {
    const statuses = [
      this.api.value.status,
      this.static.value.status,
      this.rpc.value.status,
    ];

    if (statuses.includes('down')) return 'down';
    if (statuses.includes('degraded')) return 'degraded';
    return 'healthy';
  });

  // Computed: average latency (excluding null/down services)
  public averageLatency = computed(() => {
    const latencies = [
      this.api.value.latency,
      this.static.value.latency,
      this.rpc.value.latency,
    ].filter((l): l is number => l !== null);

    if (latencies.length === 0) return null;

    return Math.round(
      latencies.reduce((sum, l) => sum + l, 0) / latencies.length
    );
  });

  // Computed: is all healthy
  public isAllHealthy = computed(() =>
    this.overallStatus.value === 'healthy'
  );

  // Computed: has any degraded
  public hasAnyDegraded = computed(() =>
    this.overallStatus.value === 'degraded'
  );

  // Computed: has any down
  public hasAnyDown = computed(() =>
    this.overallStatus.value === 'down'
  );

  /**
   * Update API health status
   */
  public setApiHealth(health: HealthStatus) {
    this.api.value = health;
  }

  /**
   * Update static files health status
   */
  public setStaticHealth(health: HealthStatus) {
    this.static.value = health;
  }

  /**
   * Update RPC health status
   */
  public setRpcHealth(health: HealthStatus) {
    this.rpc.value = health;
  }

  /**
   * Reset all health statuses to down
   */
  public reset() {
    const downStatus: HealthStatus = { latency: null, status: 'down' };
    this.api.value = downStatus;
    this.static.value = downStatus;
    this.rpc.value = downStatus;
  }

  /**
   * Get health state as object (for backward compatibility)
   */
  public getState() {
    return {
      api: this.api.value,
      static: this.static.value,
      rpc: this.rpc.value,
    };
  }
}

// Singleton instance for global health monitoring
export const healthStore = new HealthStore();
