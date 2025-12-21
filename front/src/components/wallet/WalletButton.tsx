import { useState, useMemo } from 'preact/hooks';
import { lazy, Suspense } from 'preact/compat';
import { Button } from '@components/ui/Button';
import { useWallet } from '@lib/wallet';
import { LogOut, Copy } from 'lucide-react';
import { cn } from '@utils/cn';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@components/ui/Dialog';
import { CHAINS, getChainIcon } from '@sdk/eth';

// Lazy load WalletModal to avoid bundling WalletConnect on initial load
const WalletModal = lazy(() => import('./WalletModal').then(m => ({ default: m.WalletModal })));

interface WalletButtonProps {
    className?: string;
}

export function WalletButton({ className }: WalletButtonProps) {
    const [showWalletModal, setShowWalletModal] = useState(false);
    const [showAccountModal, setShowAccountModal] = useState(false);
    const { address, isConnected, disconnect, switchChain, chainId } = useWallet();

    // Convert CHAINS object to array format
    const supportedChains = useMemo(() =>
        Object.entries(CHAINS).map(([id, chain]) => ({
            id: Number(id),
            name: chain.name,
            icon: getChainIcon(Number(id)),
        })),
        []
    );

    const formatAddress = (addr: string) => {
        return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
    };

    const currentChain = supportedChains.find(c => c.id === chainId) || supportedChains[0];

    if (!isConnected || !address) {
        return (
            <>
                <Button
                    onClick={() => setShowWalletModal(true)}
                    variant="primary"
                    size="sm"
                    className={className}
                >
                    Connect
                </Button>
                {showWalletModal && (
                    <Suspense fallback={null}>
                        <WalletModal
                            isOpen={showWalletModal}
                            onClose={() => setShowWalletModal(false)}
                        />
                    </Suspense>
                )}
            </>
        );
    }

    return (
        <>
            <Button
                variant="primary"
                size="sm"
                className={className}
                onClick={() => setShowAccountModal(true)}
                leftIcon={<img src={currentChain.icon.replace('.svg', '-mono.svg')} alt={currentChain.name} className="w-4 h-4" />}
            >
                {formatAddress(address)}
            </Button>

            <Dialog open={showAccountModal} onOpenChange={setShowAccountModal}>
                <DialogContent className="max-w-sm">
                    <DialogHeader>
                        <DialogTitle>Account</DialogTitle>
                    </DialogHeader>

                    <div className="space-y-1">
                        <div className="px-2 py-1.5 text-xs font-semibold text-primary uppercase font-numeric">
                            Network
                        </div>

                        {supportedChains.map((chain) => (
                            <Button
                                key={chain.id}
                                variant="ghost"
                                size="sm"
                                className={cn(
                                    "w-full justify-start h-auto px-2 py-2",
                                    chainId === chain.id && "bg-primary/10 text-primary"
                                )}
                                onClick={() => {
                                    switchChain(chain.id);
                                }}
                                leftIcon={<img src={chain.icon} alt={chain.name} className="w-4 h-4 invert opacity-80" />}
                            >
                                {chain.name}
                            </Button>
                        ))}

                        <div className="h-px bg-border my-2" />

                        <Button
                            variant="ghost"
                            size="sm"
                            className="w-full justify-start h-auto px-2 py-2"
                            onClick={() => {
                                navigator.clipboard.writeText(address);
                            }}
                            leftIcon={<Copy className="w-4 h-4 text-primary" />}
                        >
                            Copy Address
                        </Button>

                        <Button
                            variant="ghost"
                            size="sm"
                            className="w-full justify-start h-auto px-2 py-2 hover:bg-red-500/10 text-red-400"
                            onClick={() => {
                                disconnect();
                                setShowAccountModal(false);
                            }}
                            leftIcon={<LogOut className="w-4 h-4" />}
                        >
                            Disconnect
                        </Button>
                    </div>
                </DialogContent>
            </Dialog>
        </>
    );
}
