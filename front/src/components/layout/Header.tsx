import { Bell, Settings } from 'lucide-react';
import { useAccount, useDisconnect } from 'wagmi';
import { Button } from '@components/ui/Button';

interface HeaderProps {
  onNavigate: (page: string) => void;
  currentPage: string;
}

export default function Header({ onNavigate, currentPage }: HeaderProps) {
  const { address, isConnected } = useAccount();
  const { disconnect } = useDisconnect();

  return (
    <header className="fixed top-0 w-full h-14 flex items-center z-50">
      <nav className="max-w-7xl h-full mx-auto flex items-center justify-between px-4 border border-t-0 rounded-b-lg backdrop-blur-md bg-background/80 border-border">
        {/* Logo & Nav */}
        <div className="flex items-center h-full gap-6">
          <div
            className="text-2xl font-black tracking-tight cursor-pointer"
            onClick={() => onNavigate('dashboard')}
          >
            <span className="text-white">BTR</span>
          </div>

          <nav className="flex gap-4">
            <button
              onClick={() => onNavigate('dashboard')}
              className={`text-sm font-medium transition-colors ${
                currentPage === 'dashboard' ? 'text-primary' : 'text-gray-400 hover:text-white'
              }`}
            >
              Dashboard
            </button>
            <button
              onClick={() => onNavigate('shaper')}
              className={`text-sm font-medium transition-colors ${
                currentPage === 'shaper' ? 'text-primary' : 'text-gray-400 hover:text-white'
              }`}
            >
              Shaper
            </button>
            <button
              onClick={() => onNavigate('docs')}
              className={`text-sm font-medium transition-colors ${
                currentPage === 'docs' ? 'text-primary' : 'text-gray-400 hover:text-white'
              }`}
            >
              Docs
            </button>
          </nav>
        </div>

        {/* Actions */}
        <div className="flex items-center gap-2">
          <div className="flex border border-border rounded-lg">
            <Button variant="ghost" size="sm" className="rounded-r-none border-r border-border">
              <Bell className="w-4 h-4" />
            </Button>
            <Button variant="ghost" size="sm" className="rounded-l-none">
              <Settings className="w-4 h-4" />
            </Button>
          </div>

          {isConnected ? (
            <Button onClick={() => disconnect()} variant="outline" size="sm">
              {address?.slice(0, 6)}...{address?.slice(-4)}
            </Button>
          ) : (
            <Button variant="primary" size="sm">
              Connect
            </Button>
          )}
        </div>
      </nav>
    </header>
  );
}
