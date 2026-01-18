import { useState, useEffect } from 'preact/hooks';
import type { DrawingToolsPrimitive } from '../DrawingTools';
import { formatVerticalLineTime } from '@sdk/utils/format';

interface VerticalLineOverlayProps {
  drawingTools: DrawingToolsPrimitive | null;
  chartRef: { current: any };
  height: number;
}

export function VerticalLineOverlay({
  drawingTools,
  chartRef,
  height,
}: VerticalLineOverlayProps) {
  const [lines, setLines] = useState<any[]>([]);

  useEffect(() => {
    if (!drawingTools || !chartRef.current) return;

    const updateLines = () => {
      setLines(drawingTools.getVerticalLines());
    };

    updateLines();

    const timeScale = chartRef.current.timeScale();
    timeScale.subscribeVisibleLogicalRangeChange(updateLines);

    const interval = setInterval(updateLines, 100);

    return () => {
      timeScale.unsubscribeVisibleLogicalRangeChange(updateLines);
      clearInterval(interval);
    };
  }, [drawingTools, chartRef]);

  if (lines.length === 0) return null;

  const timeAxisHeight = 28;
  const chartHeight = height - timeAxisHeight;

  return (
    <div
      className="absolute inset-0 pointer-events-none"
      style={{ zIndex: 2, bottom: timeAxisHeight }}
    >
      {lines.map(line => {
        const dashStyle = line.isTemp || line.lineStyle === 'dashed'
          ? `${line.lineWidth * 4}px ${line.lineWidth * 2}px`
          : line.lineStyle === 'dotted'
          ? `${line.lineWidth}px ${line.lineWidth * 2}px`
          : 'none';

        const timeLabel = line.time ? formatVerticalLineTime(line.time) : '';

        return (
          <div key={line.id}>
            <div
              className="absolute top-0"
              style={{
                left: line.x,
                height: chartHeight,
                transform: 'translateX(-50%)',
              }}
            >
              <div
                style={{
                  position: 'absolute',
                  left: '50%',
                  transform: 'translateX(-50%)',
                  width: line.lineWidth,
                  height: '100%',
                  backgroundColor: dashStyle === 'none' ? line.color : undefined,
                  backgroundImage: dashStyle !== 'none'
                    ? `repeating-linear-gradient(to bottom, ${line.color}, ${line.color} ${line.lineWidth * 4}px, transparent ${line.lineWidth * 4}px, transparent ${line.lineWidth * 6}px)`
                    : undefined,
                }}
              />
              {timeLabel && !line.isTemp && (
                <div
                  style={{
                    position: 'absolute',
                    bottom: 10,
                    left: 8,
                    transform: 'rotate(-90deg)',
                    transformOrigin: 'bottom left',
                    lineHeight: '13px',
                    fontSize: '11px',
                    fontFamily: 'var(--font-numbers)',
                    fontVariantNumeric: 'tabular-nums',
                    whiteSpace: 'nowrap',
                    backgroundColor: line.color,
                    color: 'white',
                    padding: '2px 4px',
                    borderRadius: '2px',
                  }}
                >
                  {timeLabel}
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
