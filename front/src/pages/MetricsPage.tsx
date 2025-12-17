export default function MetricsPage() {
    return (
        <div className="max-w-6xl mx-auto mt-8">
            <h2 className="text-2xl font-bold mb-6">Pool Metrics</h2>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
                {[
                    { label: 'Total Value Locked', value: '$12.5M', change: '+2.4%' },
                    { label: '24h Volume', value: '$4.2M', change: '+12.1%' },
                    { label: 'Total Fees (24h)', value: '$12.4k', change: '+5.3%' },
                ].map((metric) => (
                    <div key={metric.label} className="bg-card border border-border rounded-xl p-6">
                        <div className="text-sm text-muted-foreground mb-2">{metric.label}</div>
                        <div className="text-3xl font-bold mb-1">{metric.value}</div>
                        <div className="text-sm text-green-500 font-medium">{metric.change}</div>
                    </div>
                ))}
            </div>

            <div className="bg-card border border-border rounded-xl p-6 h-96 flex items-center justify-center text-muted-foreground">
                Volume Chart Placeholder
            </div>
        </div>
    );
}
