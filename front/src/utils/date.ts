// Re-export date/time formatting from SDK
export {
  formatTime,
  formatDayHeader,
  formatVerticalLineTime,
  TIME_FORMATS,
} from '@sdk/utils/format';

// Keep formatTimeAgo in front (it's front-specific)
export function formatTimeAgo(timestamp: number): string {
  const seconds = Math.floor((Date.now() - timestamp) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
  return new Date(timestamp).toLocaleDateString();
}
