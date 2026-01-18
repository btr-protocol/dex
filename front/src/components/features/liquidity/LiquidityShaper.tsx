import { useState, useEffect, useRef } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { Knot, Makima } from '@/utils/spline';
import { getColors } from '@/styles/theme';
import * as Chartist from 'chartist';
import { formatNumber, formatPercent } from '@utils/format';

const { computeMakimaSlopes, interpolateCurve, knotsToProfile, encodeProfile } = Makima;

const MAX_KNOTS = 32;
const DEFAULT_BREADTH = 100000; // 0.1% in bps with 1M precision
const MAX_BREADTH = 1000000;    // 1% in bps
const DEFAULT_VOL_KAPPA = 1000000; // 1x sensitivity

// Theme colors (derived from CSS custom properties)
const colors = getColors();
const GREEN = colors.green;

export function LiquidityShaper() {
  const [knots, setKnots] = useState<Knot[]>([
    { x: -50, y: 100 }, // Left edge at -50% breadth
    { x: 50, y: 100 },  // Right edge at +50% breadth
  ]);
  const [baseBreadth, setBaseBreadth] = useState(DEFAULT_BREADTH);
  const [maxBreadth, setMaxBreadth] = useState(MAX_BREADTH);
  const [volKappa, setVolKappa] = useState(DEFAULT_VOL_KAPPA);
  const [showEncoded, setShowEncoded] = useState(false);
  const chartRef = useRef<HTMLDivElement>(null);

  // Generate interpolated curve
  const interpolatedPoints = interpolateCurve(knots, 100);

  // Initialize and update Chartist chart
  useEffect(() => {
    if (!chartRef.current) return;

    const xValues = interpolatedPoints.map(p => p.x);
    const curveData = interpolatedPoints.map(p => p.y);

    const data: Chartist.LineChartData = {
      labels: xValues.map(x => formatNumber(x, 0)),
      series: [
        { name: 'Curve', data: curveData.map((y, i) => ({ x: xValues[i], y })) },
        { name: 'Knots', data: knots.map(k => ({ x: k.x, y: k.y })) },
      ],
    };

    const options: Chartist.LineChartOptions = {
      fullWidth: true,
      height: 384,
      chartPadding: { top: 20, right: 20, bottom: 40, left: 50 },
      axisX: {
        divisor: 5,
        low: -100,
        high: 100,
      },
      axisY: {
        divisor: 5,
        low: 0,
        high: 255,
      },
      showLine: true,
      showPoint: true,
      showArea: true,
      lineSmooth: Chartist.Interpolation.cardinal(),
    };

    // Clear previous chart
    chartRef.current.innerHTML = '';

    // Create new chart - access Line through the default export
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ChartistLib = (Chartist as any).default || Chartist;
    const chart = new (ChartistLib as any).Line(chartRef.current, data, options);

    // Handle click to add knots
    chart.on('created', () => {
      const svg = chartRef.current?.querySelector('svg');
      if (!svg) return;

      svg.addEventListener('click', (e: MouseEvent) => {
        const rect = svg.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;

        // Simple pixel-to-data conversion
        // This is approximate - Chartist doesn't expose scale directly
        const padding = 50;
        const chartWidth = rect.width - padding - 20;
        const chartHeight = rect.height - 40 - 20;

        const dataX = ((x - padding) / chartWidth) * 200 - 100;
        const dataY = 255 - ((y - 20) / chartHeight) * 255;

        if (dataX >= -100 && dataX <= 100 && dataY >= 0 && dataY <= 255 && knots.length < MAX_KNOTS) {
          const newKnot: Knot = {
            x: Math.round(dataX * 10) / 10,
            y: Math.round(dataY),
          };
          setKnots([...knots, newKnot]);
        }
      });
    });
  }, [interpolatedPoints, knots]);

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
        <div ref={chartRef} className="ct-chart h-96" style={{ color: GREEN }}></div>
        <div className="flex items-center justify-between mt-4 text-sm text-gray-400">
          <span>{knots.length} / {MAX_KNOTS} knots</span>
          <div className="flex gap-2">
            <Button variant="outlined" size="sm" onClick={handleReset}>
              Reset
            </Button>
            <Button
              variant="outlined"
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
            onChange={(e) => setBaseBreadth(Number((e.target as HTMLInputElement).value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="100000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {formatPercent(baseBreadth / 10000, 2)}% base breadth when vol=0
          </p>
        </div>

        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <label className="block text-sm font-medium mb-2">Max Breadth (bps)</label>
          <input
            type="number"
            value={maxBreadth}
            onChange={(e) => setMaxBreadth(Number((e.target as HTMLInputElement).value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="1000000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {formatPercent(maxBreadth / 10000, 2)}% maximum breadth cap
          </p>
        </div>

        <div className="bg-gray-900 rounded-lg border border-gray-700 p-4">
          <label className="block text-sm font-medium mb-2">Volatility Kappa (1e6)</label>
          <input
            type="number"
            value={volKappa}
            onChange={(e) => setVolKappa(Number((e.target as HTMLInputElement).value))}
            className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-sm"
            placeholder="1000000"
          />
          <p className="text-xs text-gray-500 mt-1">
            {formatNumber(volKappa / 1000000, 1)}x volatility sensitivity
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
              <div className="font-mono">{formatNumber(knot.x, 1)}</div>
              <div className="font-mono">{formatNumber(knot.y, 1)}</div>
              <div className="font-mono text-xs">{slopes[index] !== undefined ? formatNumber(slopes[index], 0) : 'N/A'}</div>
              <div>
                <Button
                  variant="outlined"
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
              variant="outlined"
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
