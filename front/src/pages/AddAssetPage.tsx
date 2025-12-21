import { useState } from 'preact/hooks';
import { ArrowLeft, Check } from 'lucide-react';
import { Button } from '@components/ui/Button';
import { Input } from '@components/ui/Input';
import { Stepper, type Step } from '@components/ui/Stepper';
import { useRouter } from '@lib/router';
import LiquidityShaper from '@components/LiquidityShaper';
import ParameterShaper from '@components/ParameterShaper';
import { ROUTES } from '@/constants/navigation';

const STEPS: Step[] = [
    { label: 'General Info', description: 'Token details' },
    { label: 'Oracle Config', description: 'Price feeds' },
    { label: 'Risk Parameters', description: 'Safety settings' },
    { label: 'Liquidity Profile', description: 'Distribution curve' },
];

export default function AddAssetPage() {
    const { navigate } = useRouter();
    const [activeTab, setActiveTab] = useState(0);

    // Form State
    const [tokenAddress, setTokenAddress] = useState('');
    const [decimals, setDecimals] = useState('18');
    const [minFee, setMinFee] = useState('0.3');
    const [initialPrice, setInitialPrice] = useState('');

    const [oraclePrimary, setOraclePrimary] = useState('');
    const [oracleSecondary, setOracleSecondary] = useState('');
    const [feedId, setFeedId] = useState('');

    const [gamma, setGamma] = useState(1.0);
    const [vega, setVega] = useState(1.0);
    const [lambda, setLambda] = useState(1.0);
    const [coverageFloor, setCoverageFloor] = useState('0.1');
    const [decayStart, setDecayStart] = useState('0.5');

    const handleSubmit = () => {
        console.log('Submitting Proposal...');
    };

    return (
        <div className="container mx-auto mt-8 px-6 max-w-4xl pb-20">
            <div className="flex items-center gap-4 mb-8">
                <Button variant="ghost" size="sm" onClick={() => navigate(ROUTES.EARN)} className="w-10 h-10 p-0">
                    <ArrowLeft className="w-5 h-5" />
                </Button>
                <div>
                    <h1 className="text-3xl font-bold text-foreground">Add New Asset</h1>
                    <p className="text-muted-foreground">Configure and propose a new asset for the liquidity pool.</p>
                </div>
            </div>

            {/* Horizontal Stepper */}
            <div className="mb-8">
                <Stepper steps={STEPS} currentStep={activeTab} orientation="horizontal" />
            </div>

            {/* Content Area */}
            <div className="w-full mx-auto">
                    <div className="bg-bg-1 border border-border rounded-2xl p-8 shadow-sm min-h-[600px]">

                        {/* General Info */}
                        {activeTab === 0 && (
                            <div className="space-y-6 animate-in fade-in slide-in-from-right-4 duration-300">
                                <h2 className="text-xl font-bold border-b border-border pb-4">General Information</h2>
                                <div className="grid grid-cols-2 gap-6">
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Token Address</label>
                                        <Input
                                            type="text"
                                            placeholder="0x..."
                                            value={tokenAddress}
                                            onChange={(e: Event) => setTokenAddress((e.target as HTMLInputElement).value)}
                                            variant="address"
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Decimals</label>
                                        <Input
                                            type="number"
                                            value={decimals}
                                            onChange={(e: Event) => setDecimals((e.target as HTMLInputElement).value)}
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Minimum Fee (%)</label>
                                        <Input
                                            type="number"
                                            value={minFee}
                                            onChange={(e: Event) => setMinFee((e.target as HTMLInputElement).value)}
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Initial Price ($)</label>
                                        <Input
                                            type="number"
                                            placeholder="0.00"
                                            value={initialPrice}
                                            onChange={(e: Event) => setInitialPrice((e.target as HTMLInputElement).value)}
                                        />
                                    </div>
                                </div>
                            </div>
                        )}

                        {/* Oracle Config */}
                        {activeTab === 1 && (
                            <div className="space-y-6 animate-in fade-in slide-in-from-right-4 duration-300">
                                <h2 className="text-xl font-bold border-b border-border pb-4">Oracle Configuration</h2>
                                <div className="space-y-4">
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Primary Oracle Address</label>
                                        <Input
                                            type="text"
                                            placeholder="0x..."
                                            value={oraclePrimary}
                                            onChange={(e: Event) => setOraclePrimary((e.target as HTMLInputElement).value)}
                                            variant="address"
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Secondary Oracle Address (Optional)</label>
                                        <Input
                                            type="text"
                                            placeholder="0x..."
                                            value={oracleSecondary}
                                            onChange={(e: Event) => setOracleSecondary((e.target as HTMLInputElement).value)}
                                            variant="address"
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Feed ID (Bytes32)</label>
                                        <Input
                                            type="text"
                                            placeholder="0x..."
                                            value={feedId}
                                            onChange={(e: Event) => setFeedId((e.target as HTMLInputElement).value)}
                                            variant="address"
                                        />
                                    </div>
                                </div>
                            </div>
                        )}

                        {/* Risk Parameters */}
                        {activeTab === 2 && (
                            <div className="space-y-8 animate-in fade-in slide-in-from-right-4 duration-300">
                                <h2 className="text-xl font-bold border-b border-border pb-4">Risk Parameters</h2>

                                <div className="grid grid-cols-2 gap-6 mb-6">
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Coverage Floor</label>
                                        <Input
                                            type="number"
                                            value={coverageFloor}
                                            onChange={(e: Event) => setCoverageFloor((e.target as HTMLInputElement).value)}
                                        />
                                    </div>
                                    <div className="space-y-2">
                                        <label className="text-sm font-medium text-muted-foreground">Decay Start</label>
                                        <Input
                                            type="number"
                                            value={decayStart}
                                            onChange={(e: Event) => setDecayStart((e.target as HTMLInputElement).value)}
                                        />
                                    </div>
                                </div>

                                <div className="space-y-8">
                                    <ParameterShaper
                                        type="gamma"
                                        label="Gamma (Volatility Sensitivity)"
                                        description="Controls how quickly liquidity adapts to price changes."
                                        value={gamma}
                                        onChange={setGamma}
                                        min={0.1}
                                        max={5.0}
                                        step={0.1}
                                    />
                                    <ParameterShaper
                                        type="vega"
                                        label="Vega (Volume Sensitivity)"
                                        description="Adjusts fees based on trading volume."
                                        value={vega}
                                        onChange={setVega}
                                        min={0.1}
                                        max={5.0}
                                        step={0.1}
                                    />
                                    <ParameterShaper
                                        type="lambda"
                                        label="Lambda (Fee Sensitivity)"
                                        description="Base fee multiplier."
                                        value={lambda}
                                        onChange={setLambda}
                                        min={0.1}
                                        max={5.0}
                                        step={0.1}
                                    />
                                </div>
                            </div>
                        )}

                        {/* Liquidity Profile */}
                        {activeTab === 3 && (
                            <div className="space-y-6 animate-in fade-in slide-in-from-right-4 duration-300">
                                <h2 className="text-xl font-bold border-b border-border pb-4">Liquidity Profile</h2>
                                <p className="text-sm text-muted-foreground mb-4">
                                    Shape the liquidity distribution curve. Drag knots to adjust weights.
                                </p>
                                <div className="bg-bg-2 rounded-xl p-4 border border-border">
                                    <LiquidityShaper />
                                </div>
                            </div>
                        )}

                        {/* Action Buttons */}
                        <div className="mt-8 pt-6 border-t border-border flex justify-between gap-4">
                            <div className="flex gap-2">
                                {activeTab > 0 && (
                                    <Button styleVariant="outlined" onClick={() => setActiveTab(activeTab - 1)}>
                                        Previous
                                    </Button>
                                )}
                            </div>
                            <div className="flex gap-2">
                                <Button styleVariant="outlined" onClick={() => navigate(ROUTES.EARN)}>Cancel</Button>
                                {activeTab < STEPS.length - 1 ? (
                                    <Button variant="primary" onClick={() => setActiveTab(activeTab + 1)}>
                                        Next
                                    </Button>
                                ) : (
                                    <Button variant="primary" onClick={handleSubmit} leftIcon={<Check className="w-4 h-4" />}>
                                        Submit Proposal
                                    </Button>
                                )}
                            </div>
                        </div>

                    </div>
                </div>
        </div>
    );
}
