import { useRef } from 'preact/hooks';
import { ComponentChildren } from 'preact';

interface ChartContainerProps {
  height: number;
  width?: string | number;
  children: ComponentChildren;
  loading?: boolean;
  error?: string | null;
  onPointerDown?: (e: any) => void;
  onPointerMove?: (e: any) => void;
  onPointerUp?: (e: any) => void;
  cursor?: string;
  displayBase: string;
  displayQuote: string;
}

export function ChartContainer({
  height,
  width = '100%',
  children,
  loading,
  error,
  onPointerDown,
  onPointerMove,
  onPointerUp,
  cursor,
  displayBase,
  displayQuote,
}: ChartContainerProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  return (
    <div className="relative flex-1">
      {/* Watermark */}
      <div
        className="absolute inset-0 flex items-center justify-center pointer-events-none"
        style={{ height: height - 28, zIndex: 0 }}
      >
        <div className="font-title font-bold text-fg-3 opacity-10" style={{ fontSize: '5rem' }}>
          {displayBase}/{displayQuote}
        </div>
      </div>

      {/* Loading/Error */}
      {loading && (
        <div className="absolute inset-0 flex items-center justify-center bg-bg-1/80 z-20">
          <div className="text-muted-foreground text-sm">Loading chart...</div>
        </div>
      )}
      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-bg-1/80 z-20">
          <div className="text-red-400 text-sm">Error: {error}</div>
        </div>
      )}

      {/* Main Chart Area */}
      <div
        ref={containerRef}
        className="relative"
        style={{ height, width, zIndex: 1, cursor }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerLeave={onPointerUp}
      >
        {children}
      </div>
    </div>
  );
}