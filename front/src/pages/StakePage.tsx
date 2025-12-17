import { useState } from 'preact/hooks';
import { Info, HelpCircle } from 'lucide-react';
import { Button } from '@components/ui/Button';
import { Badge } from '@components/ui/Badge';
import { Input } from '@components/ui/Input';
import { MaskIcon } from '@components/ui/MaskIcon';
import { useWallet } from '@lib/wallet';
import PageContainer from '@components/layout/PageContainer';

export default function StakePage() {
    const { isConnected, connect } = useWallet();
    const [activeTab, setActiveTab] = useState<'stake' | 'unstake'>('stake');
    const [amount, setAmount] = useState('');

    // Mock data
    const stakedAmount = '6.529m';
    const buybacks24h = '44.82k';
    const apr = '219.92%';
    const exchangeRate = '1 xBTR ≈ 1.2344 BTR';
    const userBalance = '1,234.56';
    const receiveAmount = amount ? (parseFloat(amount) * 1.2344).toFixed(2) : '0';

    return (
        <PageContainer title="Stake">
            <div className="max-w-2xl mx-auto">
                {/* Info Banner */}
                <div className="bg-bg-1 border border-border rounded-lg p-4 mb-6">
                    <div className="flex items-start gap-3">
                        <Info className="w-5 h-5 text-primary shrink-0 mt-0.5" />
                        <div>
                            <h3 className="text-sm font-semibold text-foreground mb-1">
                                Earn Yield on your $BTR
                            </h3>
                            <p className="text-sm text-muted-foreground">
                                Liquid stake your BTR to receive sBTR and earn a share of protocol fee rewards.
                            </p>
                            <div className="flex gap-4 mt-3">
                                <Button variant="ghost" size="sm" className="text-primary hover:text-primary/80 h-auto p-0">
                                    Stake Now
                                </Button>
                                <Button
                                    variant="ghost"
                                    size="sm"
                                    className="h-auto p-0"
                                    rightIcon={
                                        <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                                        </svg>
                                    }
                                >
                                    Read the Announcement
                                </Button>
                            </div>
                        </div>
                    </div>
                </div>

                {/* Stats Box */}
                <div className="bg-bg-1 border border-border rounded-lg p-4 mb-6">
                    <div className="flex items-center justify-between mb-4">
                        <h3 className="text-sm font-semibold text-foreground">sBTR Earning</h3>
                        <Badge variant="positive" className="gap-1.5">
                            <Info className="w-3 h-3" />
                            <span className="font-numeric">{apr} APR</span>
                        </Badge>
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                        <div>
                            <div className="text-sm text-muted-foreground mb-1">Staked BTR</div>
                            <div className="text-2xl font-bold font-numeric text-foreground">{stakedAmount}</div>
                        </div>
                        <div>
                            <div className="text-sm text-muted-foreground mb-1 flex items-center gap-1">
                                24h Buybacks
                                <HelpCircle className="w-3 h-3" />
                            </div>
                            <div className="flex items-center gap-1.5">
                                <div className="text-2xl font-bold font-numeric text-foreground">{buybacks24h}</div>
                                <MaskIcon src="/tokens/btr.svg" size="md" color="var(--primary)" aria-label="BTR" />
                            </div>
                        </div>
                    </div>
                </div>

                {/* Staking Form */}
                <div className="bg-bg-1 border border-border rounded-lg p-4">
                    {/* Tabs */}
                    <div className="flex mb-4">
                        <Button
                            onClick={() => setActiveTab('stake')}
                            variant="ghost"
                            size="sm"
                            className={`flex-1 h-auto py-2 border-b-2 rounded-none ${
                                activeTab === 'stake'
                                    ? 'border-primary text-foreground'
                                    : 'border-transparent text-muted-foreground hover:text-foreground'
                            }`}
                        >
                            Stake
                        </Button>
                        <Button
                            onClick={() => setActiveTab('unstake')}
                            variant="ghost"
                            size="sm"
                            className={`flex-1 h-auto py-2 border-b-2 rounded-none ${
                                activeTab === 'unstake'
                                    ? 'border-primary text-foreground'
                                    : 'border-transparent text-muted-foreground hover:text-foreground'
                            }`}
                        >
                            Unstake
                        </Button>
                    </div>

                    {/* Amount Input */}
                    <div className="bg-bg-2 border border-border rounded-md p-4 mb-3">
                        <div className="flex justify-between items-center mb-2">
                            <span className="text-sm text-muted-foreground">Amount</span>
                            <Button
                                variant="ghost"
                                size="xs"
                                className="h-auto p-0 text-xs font-numeric"
                            >
                                Balance: {userBalance}
                            </Button>
                        </div>
                        <div className="flex items-center gap-3">
                            <Input
                                variant="amount"
                                type="text"
                                placeholder="0"
                                value={amount}
                                onChange={(e) => setAmount(e.target.value)}
                                className="flex-1"
                            />
                            <div className="flex items-center gap-2 bg-bg-3 rounded-sm px-3 py-2">
                                <MaskIcon
                                    src={activeTab === 'stake' ? '/tokens/btr.svg' : '/tokens/sbtr.svg'}
                                    size="lg"
                                    color="var(--primary)"
                                    aria-label={activeTab === 'stake' ? 'BTR' : 'sBTR'}
                                />
                                <span className="font-semibold text-foreground">
                                    {activeTab === 'stake' ? 'BTR' : 'sBTR'}
                                </span>
                            </div>
                        </div>
                    </div>

                    {/* Receive Info */}
                    <div className="bg-bg-2 border border-border rounded-md p-4 mb-3">
                        <div className="flex justify-between items-center">
                            <span className="text-sm text-muted-foreground">You Receive ~</span>
                            <div className="flex items-center gap-2">
                                <MaskIcon
                                    src={activeTab === 'stake' ? '/tokens/sbtr.svg' : '/tokens/btr.svg'}
                                    size="md"
                                    color="var(--fg-1)"
                                    aria-label={activeTab === 'stake' ? 'sBTR' : 'BTR'}
                                />
                                <span className="text-lg font-bold font-numeric text-foreground">{receiveAmount}</span>
                                <span className="text-sm text-muted-foreground">{activeTab === 'stake' ? 'sBTR' : 'BTR'}</span>
                            </div>
                        </div>
                        <div className="flex items-center justify-end gap-1 mt-2">
                            <Button
                                variant="ghost"
                                size="xs"
                                className="h-auto p-0 text-xs"
                                rightIcon={
                                    <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                                    </svg>
                                }
                            >
                                <span className="font-numeric">Staking Exchange Rate</span>
                                <span className="font-numeric ml-1">{exchangeRate}</span>
                            </Button>
                        </div>
                    </div>

                    {/* Action Button */}
                    <Button
                        className="w-full h-12 text-base font-semibold rounded-sm"
                        onClick={() => !isConnected && connect()}
                        variant={!isConnected || amount ? 'primary' : 'default'}
                        disabled={isConnected && !amount}
                    >
                        {!isConnected ? 'Connect Wallet' : !amount ? 'Enter an amount' : activeTab === 'stake' ? 'Stake' : 'Unstake'}
                    </Button>
                </div>

                {/* Pending Cooldowns */}
                <div className="bg-bg-1 border border-border rounded-lg p-4 mt-6">
                    <div className="flex items-center justify-between mb-3">
                        <h3 className="text-sm font-semibold text-foreground">Pending Cooldowns</h3>
                        <HelpCircle className="w-4 h-4 text-muted-foreground" />
                    </div>
                    <p className="text-sm text-muted-foreground">
                        You don't have any pending cooldowns.
                    </p>
                </div>

                {/* FAQs */}
                <div className="bg-bg-1 border border-border rounded-lg p-4 mt-6">
                    <div className="flex items-center justify-between mb-3">
                        <h3 className="text-sm font-semibold text-foreground">FAQs</h3>
                        <Button
                            variant="ghost"
                            size="sm"
                            className="text-primary hover:text-primary/80 h-auto p-0"
                            rightIcon={
                                <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                                </svg>
                            }
                        >
                            Staking Guide
                        </Button>
                    </div>
                    <div className="space-y-2">
                        {[
                            'What is sBTR?',
                            'How do I earn rewards?',
                            'Why is APR shown in BTR terms?',
                            'Can I use sBTR in DeFi?',
                            'Are my tokens safe?',
                            'What risks should I know about?',
                            'Can sBTR holders vote on governance proposals?',
                        ].map((question, i) => (
                            <Button
                                key={i}
                                variant="ghost"
                                size="sm"
                                className="w-full text-left justify-between h-auto py-2 border-b border-border last:border-b-0 rounded-none"
                                rightIcon={
                                    <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                                    </svg>
                                }
                            >
                                <span>{question}</span>
                            </Button>
                        ))}
                    </div>
                </div>
            </div>
        </PageContainer>
    );
}
