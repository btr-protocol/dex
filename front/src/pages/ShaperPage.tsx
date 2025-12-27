import { LiquidityShaper } from '@components/features/liquidity';

export function ShaperPage() {
  return (
    <div className="min-h-screen bg-background">
      <div className="container mx-auto px-4 py-8">
        <div className="max-w-6xl mx-auto">
          <LiquidityShaper />
        </div>
      </div>
    </div>
  );
}
