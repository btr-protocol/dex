import { useEffect, useRef } from 'preact/hooks';
import { LineChart } from 'chartist';

interface SparklineProps {
  data: number[];
  width?: number;
  height?: number;
  color?: string;
  className?: string;
}

export function SimpleSparkline({
  data,
  width = 120,
  height = 40,
  color = '#10b981',
  className = '',
}: SparklineProps) {
  const chartRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!chartRef.current || data.length < 2) return;

    // Prepare chart data
    const chartData = {
      labels: data.map((_, i) => i.toString()),
      series: [data],
    };

    const options = {
      width,
      height,
      fullWidth: false,
      chartPadding: 0,
      showLine: true,
      showPoint: false,
      showArea: true,
    };

    // Clear previous chart
    chartRef.current.innerHTML = '';

    // Create new chart using LineChart
    new LineChart(chartRef.current, chartData, options);

    // Style the chart to match color and hide axes
    const styleId = Math.random().toString(36).substr(2, 9);
    const style = document.createElement('style');
    style.textContent = `
      .sparkline-chart-${styleId} .ct-line {
        stroke: ${color};
        stroke-width: 2px;
      }
      .sparkline-chart-${styleId} .ct-area {
        fill: ${color}20;
      }
      .sparkline-chart-${styleId} .ct-axis {
        display: none;
      }
      .sparkline-chart-${styleId} .ct-labels {
        display: none;
      }
    `;
    document.head.appendChild(style);
    chartRef.current.classList.add(`sparkline-chart-${styleId}`);

    return () => {
      style.remove();
    };
  }, [data, width, height, color]);

  return <div ref={chartRef} className={`ct-chart ${className}`} style={{ width, height }} />;
}
