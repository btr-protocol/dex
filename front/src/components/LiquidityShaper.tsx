import { useState, useEffect, useRef } from 'react';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  ChartOptions,
} from 'chart.js';
import { Line } from 'react-chartjs-2';
import { Button } from '@components/ui/Button';
import {
  type Knot,
  computeMakimaSlopes,
  interpolateCurve,
  knotsToProfile,
  encodeProfile,
} from '@/utils/makima';
import { BTR_CHART_COLORS } from '@/styles/theme';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend);

const MAX_KNOTS = 32;
const DEFAULT_BREADTH = 100000; // 0.1% in bps with 1M precision
const MAX_BREADTH = 1000000;    // 1% in bps
const DEFAULT_VOL_KAPPA = 1000000; // 1x sensitivity

// Theme colors
const GREEN = BTR_CHART_COLORS[1]; // #00cc7a
const RED = BTR_CHART_COLORS[3];   // #ff4242

export default function LiquidityShaper() {
  const [knots, setKnots] = useState<Knot[]>([
    { x: -50, y: 100 }, // Left edge at -50% breadth
    { x: 50, y: 100 },  // Right edge at +50% breadth
  ]);
  const [selectedKnot, setSelectedKnot] = useState<number | null>(null);
  const [isDragging, setIsDragging] = useState(false);
  const [baseBreadth, setBaseBreadth] = useState(DEFAULT_BREADTH);
  const [maxBreadth, setMaxBreadth] = useState(MAX_BREADTH);
  const [volKappa, setVolKappa] = useState(DEFAULT_VOL_KAPPA);
  const [showEncoded, setShowEncoded] = useState(false);
  const chartRef = useRef<ChartJS<'line'>>(null);

  // Generate interpolated curve
  const interpolatedPoints = interpolateCurve(knots, 100);

  // Chart data
  const chartData = {
    labels: interpolatedPoints.map(p => p.x.toFixed(1)),
    datasets: [
      {
        label: 'Liquidity Curve (Makima Interpolation)',
        data: interpolatedPoints.map(p => p.y),
        borderColor: GREEN,
        backgroundColor: `${GREEN}20`,
        borderWidth: 2,
        pointRadius: 0,
        fill: true,
      },
      {
        label: 'Knots',
        data: knots.map((k, _i) => ({
          x: k.x,
          y: k.y,
        })),
        borderColor: RED,
        backgroundColor: RED,
        pointRadius: 8,
        pointHoverRadius: 10,
        showLine: false,
      },
    ],
  };

  const chartOptions: ChartOptions<'line'> = {
    responsive: true,
    maintainAspectRatio: false,
    interaction: {
      mode: 'nearest',
      axis: 'xy',
      intersect: false,
    },
    plugins: {
      legend: {
        display: true,
        labels: {
          color: '#9ca3af',
        },
      },
      tooltip: {
        callbacks: {
          label: (context) => {
            if (context.datasetIndex === 1) {
              const knot = knots[context.dataIndex];
              return `Knot: x=${knot.x.toFixed(1)}%, y=${knot.y.toFixed(1)}`;
            }
            return `y=${context.parsed.y?.toFixed(2) ?? '--'}`;
          },
        },
      },
    },
    scales: {
      x: {
        type: 'linear',
        title: {
          display: true,
          text: 'Price Offset (% of breadth)',
          color: '#9ca3af',
        },
        grid: {
          color: 'rgba(75, 85, 99, 0.3)',
        },
        ticks: {
          color: '#9ca3af',
        },
        min: -100,
        max: 100,
      },
      y: {
        title: {
          display: true,
          text: 'Liquidity Weight',
          color: '#9ca3af',
        },
        grid: {
          color: 'rgba(75, 85, 99, 0.3)',
        },
        ticks: {
          color: '#9ca3af',
        },
        min: 0,
        max: 255,
      },
    },
    onClick: (event, elements, chart) => {
      // Add knot on click if not clicking an existing point
      if (elements.length === 0 && knots.length < MAX_KNOTS) {
        // @ts-ignore - ChartJS.helpers types are incomplete
        const canvasPosition = ChartJS.helpers.getRelativePosition(event, chart);
        const dataX = chart.scales.x.getValueForPixel(canvasPosition.x);
        const dataY = chart.scales.y.getValueForPixel(canvasPosition.y);

        if (dataX !== undefined && dataY !== undefined) {
          const newKnot: Knot = {
            x: Math.max(-100, Math.min(100, dataX)),
            y: Math.max(0, Math.min(255, dataY)),
          };
          setKnots([...knots, newKnot]);
        }
      } else if (elements.length > 0 && elements[0].datasetIndex === 1) {
        setSelectedKnot(elements[0].index);
      }
    },
  };

  // Handle knot dragging
  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;

    const handleMouseMove = (event: MouseEvent) => {
      if (!isDragging || selectedKnot === null) return;

      // @ts-ignore - ChartJS.helpers types are incomplete
      const canvasPosition = ChartJS.helpers.getRelativePosition(event, chart);
      const dataX = chart.scales.x.getValueForPixel(canvasPosition.x);
      const dataY = chart.scales.y.getValueForPixel(canvasPosition.y);

      if (dataX !== undefined && dataY !== undefined) {
        setKnots(prev => {
          const updated = [...prev];
          updated[selectedKnot] = {
            x: Math.max(-100, Math.min(100, dataX)),
            y: Math.max(0, Math.min(255, dataY)),
          };
          return updated;
        });
      }
    };

    const handleMouseUp = () => {
      setIsDragging(false);
      setSelectedKnot(null);
    };

    if (isDragging) {
      window.addEventListener('mousemove', handleMouseMove);
      window.addEventListener('mouseup', handleMouseUp);
    }

    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isDragging, selectedKnot]);

  const handleRemoveKnot = (index: number) => {
    if (knots.length > 2) {
      setKnots(knots.filter((_, i) => i !== index));
    }
  };

  const handleReset = () => {
    setKnots([
      { x: -50, y: 100 },
      { x: 50, y: 100 },
    ]);
  };

  const profile = knotsToProfile(knots, baseBreadth, maxBreadth, volKappa);
  const slopes = computeMakimaSlopes(knots);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-bold mb-2">Liquidity Shaper</h2>
        <p className="text-gray-400 text-sm">
          Design a custom liquidity distribution using Makima interpolation. Click to add knots, drag to move them.
        </p>
      </div>

      {/* Chart */}
      <div className="bg-gray-900 rounded-lg border border-gray-700 p-6">
        <div className="h-96">
          <Line ref={chartRef} data={chartData} options={chartOptions} />
        </div>
        <div className="flex items-center justify-between mt-4 text-sm text-gray-400">
          <span>{knots.length} / {MAX_KNOTS} knots</span>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={handleReset}>
              Reset
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => setShowEncoded(!showEncoded)}
            >
              {showEncoded ? 'Hide' : 'Show'} Encoded
            </Button>
          </div>
        </div>
      </div>

      {/* Configuration Parameters */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <label className="block text-sm font-medium mb-2">Base Breadth (bps)</label>
          <input
            type="number"
            value={baseBreadth}
            onChange={(e) => setBaseBreadth(Number(e.target.value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="100000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {(baseBreadth / 10000).toFixed(2)}% base breadth when vol=0
          </p>
        </div>

        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <label className="block text-sm font-medium mb-2">Max Breadth (bps)</label>
          <input
            type="number"
            value={maxBreadth}
            onChange={(e) => setMaxBreadth(Number(e.target.value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="1000000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {(maxBreadth / 10000).toFixed(2)}% maximum breadth cap
          </p>
        </div>

        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <label className="block text-sm font-medium mb-2">Volatility Kappa (1e6)</label>
          <input
            type="number"
            value={volKappa}
            onChange={(e) => setVolKappa(Number(e.target.value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="1000000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {(volKappa / 1000000).toFixed(1)}x volatility sensitivity
          </p>
        </div>
      </div>

      {/* Knot List */}
      <div className="bg-gray-900 rounded-lg border border-gray-700 overflow-hidden">
        <div className="px-4 py-3 border-b border-gray-700">
          <h3 className="font-semibold">Knots & Parameters</h3>
        </div>
        <div className="p-4">
          <div className="grid grid-cols-4 gap-2 text-sm font-medium text-gray-400 mb-2">
            <div>Offset (%)</div>
            <div>Weight</div>
            <div>Slope (×1e9)</div>
            <div>Actions</div>
          </div>
          {knots.map((knot, index) => (
            <div key={index} className="grid grid-cols-4 gap-2 text-sm mb-2">
              <div className="font-mono">{knot.x.toFixed(1)}</div>
              <div className="font-mono">{knot.y.toFixed(1)}</div>
              <div className="font-mono text-xs">{slopes[index]?.toFixed(0) || 'N/A'}</div>
              <div>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handleRemoveKnot(index)}
                  disabled={knots.length <= 2}
                  className="text-xs"
                >
                  Remove
                </Button>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Profile Summary */}
      <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
        <h3 className="font-semibold mb-3">Profile Summary</h3>
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span className="text-gray-400">Weights (sum={profile.weights.reduce((a, b) => a + b, 0)}):</span>
            <div className="font-mono text-xs mt-1">[{profile.weights.join(', ')}]</div>
          </div>
          <div>
            <span className="text-gray-400">End Offsets:</span>
            <div className="font-mono text-xs mt-1">[{profile.endOffsets.join(', ')}]</div>
          </div>
          <div className="col-span-2">
            <span className="text-gray-400">Slopes (scaled ×1e9):</span>
            <div className="font-mono text-xs mt-1 break-all">[{profile.slopes.join(', ')}]</div>
          </div>
        </div>
      </div>

      {/* Encoded Output */}
      {showEncoded && (
        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <div className="flex items-center justify-between mb-2">
            <h3 className="font-semibold">Encoded for Contract</h3>
            <Button
              variant="outline"
              size="sm"
              onClick={() => navigator.clipboard.writeText(encodeProfile(profile))}
            >
              Copy
            </Button>
          </div>
          <pre className="text-xs font-mono bg-gray-800 p-4 rounded overflow-x-auto">
            {encodeProfile(profile)}
          </pre>
        </div>
      )}
    </div>
  );
}
