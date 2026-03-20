import { Tooltip } from '@components/ui/FloatingPanel';

interface HeroMetricProps {
  label: string;
  value: string;
  tooltip?: string;
  emphasized?: boolean;
  align?: 'left' | 'right';
}

export function HeroMetric({
  label,
  value,
  tooltip,
  emphasized = false,
  align = 'left',
}: HeroMetricProps) {
  const alignClass = align === 'right' ? 'text-right' : 'text-left';
  const content = (
    <div className={alignClass}>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className={`font-numeric ${emphasized ? 'text-xl font-bold text-primary' : 'text-base font-semibold text-foreground'}`}>
        {value}
      </div>
    </div>
  );

  if (tooltip) {
    return (
      <Tooltip content={tooltip} side="bottom">
        {content}
      </Tooltip>
    );
  }

  return content;
}
