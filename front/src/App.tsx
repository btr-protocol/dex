import { useState } from 'react'
import { Wallet } from 'lucide-react'
import { useAccount, useConnect, useDisconnect } from 'wagmi'
import { Button } from '@components/ui/Button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@components/ui/Dialog'
import { Checkbox } from '@components/ui/Checkbox'
import PoolDashboard from '@/components/PoolDashboard'
import ShaperPage from '@/pages/ShaperPage'
import DocsPage from '@/pages/DocsPage'
import DisclaimerModal, { useDisclaimer } from '@/components/DisclaimerModal'
import Header from '@/components/layout/Header'
import Footer from '@/components/layout/Footer'

export default function App() {
  const { accepted: disclaimerAccepted, accept: acceptDisclaimer } = useDisclaimer()
  const [showWalletModal, setShowWalletModal] = useState(false)
  const [agreedToTerms, setAgreedToTerms] = useState(false)
  const [currentPage, setCurrentPage] = useState<'dashboard' | 'shaper' | 'docs'>('dashboard')
  const { address, isConnected } = useAccount()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()

  // Show disclaimer if not accepted
  if (!disclaimerAccepted) {
    return <DisclaimerModal onAccept={acceptDisclaimer} />;
  }

  const handleConnect = (connector: any) => {
    if (!agreedToTerms) return
    connect({ connector })
    setShowWalletModal(false)
  }

  return (
    <div className="min-h-screen bg-background text-foreground">
      <Header onNavigate={setCurrentPage} currentPage={currentPage} />

      {/* Main Content */}
      <main className="pt-14 pb-10 min-h-screen">
        <div className="container mx-auto px-4 py-8">
          {currentPage === 'dashboard' && (
            <div className="max-w-4xl mx-auto space-y-6">
              <div>
                <h2 className="text-3xl font-bold mb-2">Pool Dashboard</h2>
                <p className="text-muted-foreground">Monitor pool metrics in real-time</p>
              </div>

              {!isConnected && (
                <div className="bg-warning/10 border border-warning/20 rounded-lg p-4">
                  <p className="text-warning">Connect your wallet to interact with the pool</p>
                </div>
              )}

              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
                {['Total Value Locked', '24h Volume', 'Total Liabilities', 'Protocol Fees'].map((label) => (
                  <div key={label} className="bg-card border border-border rounded-lg p-4">
                    <div className="text-sm text-muted-foreground mb-1">{label}</div>
                    <div className="text-2xl font-bold numeric">$0.00</div>
                    <div className="text-xs text-muted-foreground mt-1">Across all assets</div>
                  </div>
                ))}
              </div>

              <PoolDashboard />
            </div>
          )}

          {currentPage === 'shaper' && (
            <div className="max-w-6xl mx-auto">
              <ShaperPage />
            </div>
          )}

          {currentPage === 'docs' && <DocsPage />}
        </div>
      </main>

      <Footer />

      {/* Wallet Modal */}
      <Dialog open={showWalletModal} onOpenChange={setShowWalletModal}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Connect Wallet</DialogTitle>
          </DialogHeader>

          <div className="space-y-4">
            <div className="flex items-start space-x-3">
              <Checkbox
                id="terms"
                checked={agreedToTerms}
                onCheckedChange={(checked) => setAgreedToTerms(checked === true)}
                className="mt-0.5"
              />
              <label htmlFor="terms" className="text-sm text-muted-foreground leading-relaxed cursor-pointer">
                I agree to the Terms of Service and Privacy Policy
              </label>
            </div>

            <div className="space-y-2">
              {connectors.map((connector) => (
                <Button
                  key={connector.id}
                  variant="outline"
                  className="w-full justify-start h-12"
                  onClick={() => handleConnect(connector)}
                  disabled={!agreedToTerms || isPending}
                >
                  <div className="flex items-center space-x-2">
                    <div className="w-8 h-8 rounded-sm bg-primary/10 flex items-center justify-center">
                      <Wallet className="w-5 h-5 text-primary" />
                    </div>
                    <span>{connector.name}</span>
                  </div>
                </Button>
              ))}
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
