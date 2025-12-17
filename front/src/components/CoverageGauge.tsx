interface CoverageGaugeProps {
    ratio: number | null; // 0 to 1, or null for empty state
}


export function CoverageGauge({ ratio }: CoverageGaugeProps) {
    // Map ratio to color using theme sentiment colors
    const getColor = (r: number) => {
        if (r >= 0.95) return `var(--fg-success)`; // green
        if (r >= 0.75) return `var(--warning)`; // yellow
        if (r >= 0.5) return `var(--primary)`; // orange
        return `var(--fg-error)`; // red
    };

    // Empty state
    if (ratio === null) {
        return (
            <div className="flex items-center gap-2 w-28">
                <div className="flex-1 h-1.5 bg-bg-3 rounded-full overflow-hidden" />
                <span className="text-xs font-numeric text-muted-foreground">--.-%</span>
            </div>
        );
    }

    const color = getColor(ratio);
    const percentage = Math.round(ratio * 100);

    return (
        <div className="flex items-center gap-2 w-28">
            <div className="flex-1 h-1.5 bg-bg-3 rounded-full overflow-hidden">
                <div
                    className="h-full rounded-full transition-all duration-300"
                    style={{
                        width: `${percentage}%`,
                        backgroundColor: color
                    }}
                />
            </div>
            <span className="text-xs font-numeric" style={{ color }}>
                {percentage}%
            </span>
        </div>
    );
}
