import { useMemo, useEffect, useState } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import { BaseModal } from '@components/ui/BaseModal';
import { Checkbox } from '@components/ui/Checkbox';
import { Divider } from '@components/ui/Divider';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { EmptyState } from '@components/ui/EmptyState';
import { WalletItemButton } from '@components/ui/WalletItemButton';
import { ModalSection } from '@components/ui/ModalSection';
import { useWallet } from '@lib/wallet';
import { useWalletConnection } from '@hooks/useWalletConnection';
import {
    useInjectedWallets,
    getWalletDownloadUrl,
    getWalletIcon,
    getWalletTooltipName,
    type Wallet,
    WC_ICONS,
    DISCOVER_MOBILE,
    DISCOVER_DESKTOP,
    isMobile,
} from '@hooks/useInjectedWallets';
import { getName as getWalletName } from '@sdk/eth/wallets';
import { addNotification } from '@lib/notifications';
import { Icon } from '@components/ui/Icon';
import { Tooltip } from '@components/ui/Tooltip';
import { Button } from '@components/ui/Button';
import { useKeyboardNav } from '@hooks/useKeyboardNav';
import { legalRoutes } from '@/constants/navigation';

interface WalletModalProps {
    isOpen: boolean;
    onClose: () => void;
}

// type ModalView = 'list' | 'qr';

export function WalletModal({ isOpen, onClose }: WalletModalProps) {
    const { connectWithProvider } = useWallet();
    const detectedWallets = useInjectedWallets();
    const {
        agreedToTerms,
        connectingWallet,
        error,
        searchQuery,
        view,
        isLoadingWC,
        qrCodeUrl,
        wcUri: _wcUri,
        copied,
        setAgreedToTerms,
        setConnectingWallet,
        setError,
        setSearchQuery,
        setView: _setView,
        setIsLoadingWC,
        setQrCodeUrl,
        setWcUri,
        reset,
        resetSearch,
        handleBack,
        startWalletConnect,
        setWalletConnectError,
        copyUri,
    } = useWalletConnection();

    // Reset search when modal opens
    useEffect(() => {
        if (isOpen) resetSearch();
    }, [isOpen, resetSearch]);

    // Get platform-specific discover wallets
    const discoverWalletIds = isMobile() ? DISCOVER_MOBILE : DISCOVER_DESKTOP;
    const detectedIds = new Set(detectedWallets.map(w => w.id));

    // Filter discover wallets to exclude detected ones
    const discoverWallets = discoverWalletIds.filter(id => !detectedIds.has(id));

    // Filter wallets based on search
    const filteredDetected = useMemo(() => {
        if (!searchQuery) return detectedWallets;
        const query = searchQuery.toLowerCase();
        return detectedWallets.filter(w => w.name.toLowerCase().includes(query));
    }, [detectedWallets, searchQuery]);

    const filteredDiscover = useMemo(() => {
        if (!searchQuery) return discoverWallets;
        const query = searchQuery.toLowerCase();
        return discoverWallets.filter(id => getWalletName(id).toLowerCase().includes(query));
    }, [discoverWallets, searchQuery]);

    // Build flat list of all navigable items for keyboard navigation
    type NavItem =
        | { type: 'detected'; wallet: Wallet }
        | { type: 'walletconnect' }
        | { type: 'discover'; walletId: string };

    const navItems = useMemo<NavItem[]>(() => {
        const items: NavItem[] = [];

        // Add detected wallets
        filteredDetected.forEach(wallet => items.push({ type: 'detected', wallet }));

        // Add WalletConnect if visible
        if (!searchQuery || 'walletconnect'.includes(searchQuery.toLowerCase())) {
            items.push({ type: 'walletconnect' });
        }

        // Add discover wallets
        filteredDiscover.forEach(walletId => items.push({ type: 'discover', walletId }));

        return items;
    }, [filteredDetected, filteredDiscover, searchQuery]);

    // Keyboard navigation
    const { selectedIndex, handleKeyDown } = useKeyboardNav({
        items: navItems,
        onSelect: (item) => {
            if (!agreedToTerms) {
                setError('Please agree to the terms');
                return;
            }
            if (item.type === 'detected') {
                handleConnectDetected(item.wallet);
            } else if (item.type === 'walletconnect') {
                handleWalletConnect();
            } else if (item.type === 'discover') {
                handleDiscoverWallet(item.walletId);
            }
        },
        isEnabled: isOpen && view === 'list',
    });

    const handleConnectDetected = async (wallet: Wallet) => {
        if (!agreedToTerms) {
            setError('Please agree to the terms');
            return;
        }

        setConnectingWallet(wallet.id);
        setError('');

        try {
            await connectWithProvider(wallet.provider);
            onClose();
        } catch (e: unknown) {
            let errorMessage = 'Failed to connect wallet';
            if (typeof e === 'object' && e !== null && 'message' in e && typeof (e as Record<string, unknown>).message === 'string') {
                const msg = (e as Record<string, unknown>).message as string;
                if (msg.includes('User rejected') || (e as Record<string, unknown>).code === 4001) {
                    errorMessage = 'Connection cancelled';
                } else if ((e as Record<string, unknown>).code === 4100) {
                    errorMessage = 'Wallet unauthorized';
                } else if ((e as Record<string, unknown>).code === 4902) {
                    errorMessage = 'Chain disconnected or not added';
                } else if ((e as Record<string, unknown>).code === -32000 && msg.includes('cancelled')) {
                    errorMessage = 'Request cancelled';
                } else {
                    errorMessage = msg;
                }
            }
            setError(errorMessage);
        } finally {
            setConnectingWallet(null);
        }
    };

    const handleWalletConnect = async () => {
        if (!agreedToTerms) {
            setError('Please agree to the terms');
            return;
        }

        startWalletConnect();

        try {
            // Lazy load WalletConnect only when clicked
            const { connectWithWalletConnect, generateQRCode } = await import('@lib/walletconnect');

            await connectWithWalletConnect({
                onUri: async (uri) => {
                    setWcUri(uri);
                    const qr = await generateQRCode(uri);
                    setQrCodeUrl(qr);
                    setIsLoadingWC(false);
                },
                onConnected: () => {
                    addNotification('success', 'Connected via WalletConnect');
                    onClose();
                },
                onError: (err) => {
                    setWalletConnectError(err.message);
                },
            });
        } catch (e: unknown) {
            console.error('WalletConnect error:', e);
            if (typeof e === 'object' && e !== null && 'message' in e && typeof (e as Record<string, unknown>).message === 'string') {
                const msg = (e as Record<string, unknown>).message as string;
                if (msg.includes('User rejected') || msg.includes('cancelled')) {
                    setWalletConnectError('Connection cancelled');
                } else if (msg.includes('Project ID')) {
                    setWalletConnectError('WalletConnect not configured. Please contact support.');
                } else {
                    setWalletConnectError(msg);
                }
            } else {
                setWalletConnectError('Failed to connect with WalletConnect');
            }
        }
    };

    const handleCopyUri = async () => {
        const success = await copyUri();
        if (!success) {
            addNotification('error', 'Failed to copy');
        }
    };

    const handleDiscoverWallet = (walletId: string) => {
        const downloadUrl = getWalletDownloadUrl(walletId);
        const walletName = getWalletName(walletId);
        if (downloadUrl) {
            addNotification('info', `Download ${walletName} at ${downloadUrl}`);
            window.open(downloadUrl, '_blank', 'noopener,noreferrer');
        }
    };

    // Reset state when modal closes
    const handleClose = () => {
        reset();
        onClose();
    };

    return (
        <BaseModal
            isOpen={isOpen}
            onClose={(open) => !open && handleClose()}
            title={view === 'qr' ? 'Scan with Wallet' : 'Connect Wallet'}
            headerType={view === 'qr' ? 'title' : 'input'}
            placeholder="Search wallets..."
            searchValue={searchQuery}
            onSearchChange={setSearchQuery}
            onSearchKeyDown={view === 'list' ? handleKeyDown : undefined}
            maxWidth="sm:max-w-[375px]"
            headerRight={view === 'qr' ? (
                <button
                    onClick={handleBack}
                    className="p-1 hover:bg-bg-3 rounded transition-colors"
                >
                    <Icon name="arrow-left" className="w-4 h-4" />
                </button>
            ) : undefined}
            footerNav={view === 'list' ? (
                <KeyboardShortcutGroup
                    shortcuts={[
                        { keys: '↑↓', label: 'Navigate' },
                        { keys: 'Enter', label: 'Select' },
                        { keys: 'Esc', label: 'Close' },
                    ]}
                />
            ) : undefined}
            footerContent={view === 'list' ? (
                <p className="text-xs text-muted-foreground text-center">
                    Don't have a wallet?{' '}
                    <a
                        href="https://ethereum.org/en/wallets/find-wallet/"
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-primary/80 underline hover:text-primary"
                    >
                        Learn how to get one
                    </a>
                </p>
            ) : undefined}
        >
            <div className="flex flex-col">
                {error && (
                    <div className="bg-red-500/10 text-red-500 p-3 mx-4 mt-4 rounded-md text-sm">
                        {error}
                    </div>
                )}

                {view === 'list' ? (
                    <>
                        {/* ToS Checkbox - Sticky */}
                        <div className="sticky top-0 z-10 bg-bg-1">
                            <div className="px-4 py-4">
                                <div className="flex items-start space-x-3">
                                    <Checkbox
                                        id="terms"
                                        checked={agreedToTerms}
                                        onCheckedChange={(checked) => setAgreedToTerms(checked === true)}
                                    />
                                    <label
                                        htmlFor="terms"
                                        className="text-sm text-muted-foreground leading-relaxed cursor-pointer"
                                    >
                                        I agree to {' '}
                                        <a href={legalRoutes[0]?.path} className="text-primary/80 underline hover:text-primary">
                                            BTR's Terms of Service
                                        </a>{' '}
                                        {/* and{' '}
                                        <a href="#" className="text-primary/80 underline hover:text-primary">
                                            Privacy Policy
                                        </a> */}
                                    </label>
                                </div>
                            </div>
                            <Divider />
                        </div>

                        {/* Scrollable wallet sections */}
                        <div className="space-y-3">
                                {/* Detected wallets */}
                                {filteredDetected.length > 0 && (
                                    <ModalSection title="Installed">
                                        {filteredDetected.map((wallet, idx) => {
                                            const globalIdx = idx;
                                            const isHighlighted = selectedIndex === globalIdx;
                                            return (
                                                <WalletItemButton
                                                    key={wallet.id}
                                                    name={wallet.name}
                                                    icon={wallet.icon}
                                                    isConnecting={connectingWallet === wallet.id}
                                                    disabled={!agreedToTerms || connectingWallet !== null}
                                                    onClick={() => handleConnectDetected(wallet)}
                                                    variant="detected"
                                                    isHighlighted={isHighlighted}
                                                />
                                            );
                                        })}
                                    </ModalSection>
                                )}

                                {/* WalletConnect section - always show if no search or search matches */}
                                {(!searchQuery || 'walletconnect'.includes(searchQuery.toLowerCase())) && (
                                    <ModalSection title="WalletConnect">
                                        <WalletConnectButton
                                            disabled={!agreedToTerms || connectingWallet !== null}
                                            isLoading={isLoadingWC}
                                            onClick={handleWalletConnect}
                                            isHighlighted={selectedIndex === filteredDetected.length}
                                        />
                                    </ModalSection>
                                )}

                                {/* Discover section */}
                                {filteredDiscover.length > 0 && (
                                    <ModalSection title="Discover">
                                        {filteredDiscover.map((walletId, idx) => {
                                            const wcOffset = (!searchQuery || 'walletconnect'.includes(searchQuery.toLowerCase())) ? 1 : 0;
                                            const globalIdx = filteredDetected.length + wcOffset + idx;
                                            const isHighlighted = selectedIndex === globalIdx;
                                            const name = getWalletName(walletId);
                                            const icon = getWalletIcon(walletId);
                                            const downloadUrl = getWalletDownloadUrl(walletId);
                                            return (
                                                <WalletItemButton
                                                    key={walletId}
                                                    name={name}
                                                    icon={icon}
                                                    onClick={() => handleDiscoverWallet(walletId)}
                                                    variant="discover"
                                                    tooltip={downloadUrl || ''}
                                                    isHighlighted={isHighlighted}
                                                />
                                            );
                                        })}
                                    </ModalSection>
                                )}

                                {/* No results */}
                                {searchQuery && filteredDetected.length === 0 && filteredDiscover.length === 0 && !'walletconnect'.includes(searchQuery.toLowerCase()) && (
                                    <EmptyState
                                        query={searchQuery}
                                        message="No wallets found"
                                    />
                                )}
                        </div>
                    </>
                ) : (
                    /* QR Code View */
                    <div className="flex flex-col items-center space-y-4 px-4 py-4">
                            {isLoadingWC ? (
                                <div className="w-[280px] h-[280px] bg-bg-2 rounded-lg flex items-center justify-center">
                                    <div className="flex flex-col items-center gap-3">
                                        <div className="w-8 h-8 border-2 border-primary border-t-transparent rounded-full animate-spin" />
                                        <span className="text-sm text-muted-foreground">Generating QR code...</span>
                                    </div>
                                </div>
                            ) : qrCodeUrl ? (
                                <>
                                    <div className="bg-white p-2 rounded-lg">
                                        <img
                                            src={qrCodeUrl}
                                            alt="WalletConnect QR Code"
                                            className="w-[280px] h-[280px]"
                                        />
                                    </div>
                                    <p className="text-sm text-muted-foreground text-center max-w-[280px]">
                                        Scan this QR code with your mobile wallet to connect
                                    </p>
                                    <Button
                                        variant="outlined"
                                        size="sm"
                                        onClick={handleCopyUri}
                                        leftIcon={copied ? <Icon name="check-circle" className="w-4 h-4" /> : <Icon name="copy" className="w-4 h-4" />}
                                    >
                                        {copied ? 'Copied!' : 'Copy URI'}
                                    </Button>
                                </>
                            ) : (
                                <div className="w-[280px] h-[280px] bg-bg-2 rounded-lg flex items-center justify-center">
                                    <span className="text-sm text-muted-foreground">Failed to generate QR</span>
                                </div>
                            )}
                    </div>
                )}
            </div>
        </BaseModal>
    );
}

interface WalletConnectButtonProps {
    disabled: boolean;
    isLoading: boolean;
    onClick: () => void;
    isHighlighted?: boolean;
}

function WalletConnectButton({ disabled, isLoading, onClick, isHighlighted = false }: WalletConnectButtonProps) {
    return (
        <button
            className={`group w-full relative overflow-hidden border border-border disabled:opacity-50 disabled:cursor-not-allowed hover-primary transition-all duration-500 ease-in-out h-[130px] hover:h-[260px] ${
                isHighlighted ? 'bg-bg-3' : 'bg-bg-2'
            }`}
            onClick={onClick}
            disabled={disabled || isLoading}
        >
            {/* Icons grid background - 6 cols x 4 rows */}
            <div className={`p-3 transition-all duration-500 ease-in-out ${
                isLoading
                    ? 'opacity-20 blur-[2px]'
                    : 'opacity-40 blur-[1.5px] group-hover:blur-0 group-hover:opacity-100'
            }`}>
                <div className="grid grid-cols-6 gap-2">
                    {WC_ICONS.map((walletId) => (
                        <Tooltip key={walletId} content={getWalletTooltipName(walletId)} side="top">
                            <div className="aspect-square cursor-pointer">
                                <img
                                    src={getWalletIcon(walletId)}
                                    alt={getWalletName(walletId)}
                                    className="w-full h-full object-contain rounded-xs"
                                />
                            </div>
                        </Tooltip>
                    ))}
                </div>
            </div>

            {/* Overlay - fades out on hover to show button bg */}
            <div className={`absolute inset-0 bg-bg-2 pointer-events-none transition-opacity duration-500 ease-in-out ${
                isLoading ? 'opacity-70' : 'opacity-50 group-hover:opacity-0'
            }`} />

            {/* WalletConnect logo or loading spinner */}
            <div className={`absolute inset-0 flex items-center justify-center transition-opacity duration-500 ease-in-out pointer-events-none ${
                isLoading ? '' : 'group-hover:opacity-0'
            }`}>
                {isLoading ? (
                    <div className="flex items-center gap-3">
                        <div className="w-5 h-5 border-2 border-fg-1 border-t-transparent rounded-full animate-spin" />
                        <span className="text-fg-1 font-title text-sm">Loading WalletConnect...</span>
                    </div>
                ) : (
                    <img
                        src="/wallets/walletconnect-mono.svg"
                        alt="WalletConnect"
                        className="h-14"
                        style={{ filter: 'brightness(0) invert(1) opacity(0.9)' }}
                    />
                )}
            </div>
        </button>
    );
}
