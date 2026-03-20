import { useState, useEffect } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { Input } from '@components/ui/Input';
import { Card, CardHeader, CardTitle, CardContent, CardFooter } from '@components/ui/Card';
import { Icon } from '@components/ui/Icon';
import { Badge } from '@components/ui/Badge';
import { useAuth } from '@lib/auth';
import { useRouter } from '@lib/router';
import { ROUTES } from '@/constants/navigation';
import {
  listUsers,
  grantInvite,
  banUser,
  setInviteCount,
  setCoopArb,
  setCanUseAgents,
  revokeInvite,
  type User,
} from '@lib/auth';
import { addNotification } from '@lib/notifications';

type Tab = 'users' | 'invites';

export function AdminPage() {
  const { user } = useAuth();
  const { navigate } = useRouter();
  const [activeTab, setActiveTab] = useState<Tab>('users');
  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  // Invite management state
  const [inviteAddress, setInviteAddress] = useState('');
  const [inviteCode, setInviteCode] = useState('');
  const [isGrantingInvite, setIsGrantingInvite] = useState(false);

  // Check if user is admin
  useEffect(() => {
    if (user && user.role !== 'admin') {
      navigate(ROUTES.HOME);
    }
  }, [user, navigate]);

  // Load users on mount and when tab changes to users
  useEffect(() => {
    if (activeTab === 'users') {
      loadUsers();
    }
  }, [activeTab]);

  const loadUsers = async () => {
    setIsLoading(true);
    const result = await listUsers();
    if (result.success && result.users) {
      setUsers(result.users);
    } else {
      addNotification('error', result.message || 'Failed to load users');
    }
    setIsLoading(false);
  };

  const handleGrantInvite = async () => {
    if (!inviteAddress || !inviteCode) {
      addNotification('error', 'Please enter an address and invite code');
      return;
    }

    setIsGrantingInvite(true);
    const result = await grantInvite(inviteAddress as any, inviteCode);

    if (result.success) {
      addNotification('success', 'Invite granted successfully');
      setInviteAddress('');
      setInviteCode('');
      loadUsers(); // Refresh users list
    } else {
      addNotification('error', result.message || 'Failed to grant invite');
    }

    setIsGrantingInvite(false);
  };

  const handleBanUser = async (address: string, banned: boolean) => {
    const result = await banUser(address as any, banned);

    if (result.success) {
      addNotification('success', banned ? 'User banned' : 'User unbanned');
      loadUsers();
    } else {
      addNotification('error', result.message || 'Failed to update ban status');
    }
  };

  const handleRevokeInvite = async (address: string) => {
    if (!confirm(`Revoke invite for ${address}?`)) return;

    const result = await revokeInvite(address as any);

    if (result.success) {
      addNotification('success', 'Invite revoked');
      loadUsers();
    } else {
      addNotification('error', result.message || 'Failed to revoke invite');
    }
  };

  const handleSetInviteCount = async (address: string, count: number) => {
    const result = await setInviteCount(address as any, count);

    if (result.success) {
      addNotification('success', 'Invite count updated');
      loadUsers();
    } else {
      addNotification('error', result.message || 'Failed to update invite count');
    }
  };

  const handleSetCoopArb = async (address: string, status: boolean) => {
    const result = await setCoopArb(address as any, status);

    if (result.success) {
      addNotification('success', 'Coop arb status updated');
      loadUsers();
    } else {
      addNotification('error', result.message || 'Failed to update coop arb status');
    }
  };

  const handleSetCanUseAgents = async (address: string, status: boolean) => {
    const result = await setCanUseAgents(address as any, status);

    if (result.success) {
      addNotification('success', 'Agent access updated');
      loadUsers();
    } else {
      addNotification('error', result.message || 'Failed to update agent access');
    }
  };

  const formatAddress = (addr: string) => {
    return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
  };

  // If not admin, don't render
  if (!user || user.role !== 'admin') {
    return null;
  }

  return (
    <div className="container mx-auto p-6 max-w-7xl">
      {/* Header */}
      <div className="mb-8">
        <h1 className="text-3xl font-bold mb-2">Admin Panel</h1>
        <p className="text-fg-2">Manage users and invite codes</p>
      </div>

      {/* Tabs */}
      <div className="flex gap-2 mb-6 border-b border-border">
        <button
          onClick={() => setActiveTab('users')}
          className={`px-4 py-2 font-medium border-b-2 transition-colors ${
            activeTab === 'users'
              ? 'border-primary text-primary'
              : 'border-transparent text-fg-2 hover:text-foreground'
          }`}
        >
          Users
        </button>
        <button
          onClick={() => setActiveTab('invites')}
          className={`px-4 py-2 font-medium border-b-2 transition-colors ${
            activeTab === 'invites'
              ? 'border-primary text-primary'
              : 'border-transparent text-fg-2 hover:text-foreground'
          }`}
        >
          Invite Management
        </button>
      </div>

      {/* Users Tab */}
      {activeTab === 'users' && (
        <Card>
          <CardHeader>
            <CardTitle>All Users ({users.length})</CardTitle>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="flex items-center justify-center py-8">
                <div className="animate-spin">
                  <Icon name="circle-notch" className="w-6 h-6 text-fg-2" />
                </div>
              </div>
            ) : users.length === 0 ? (
              <p className="text-center text-fg-2 py-8">No users yet</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full">
                  <thead>
                    <tr className="border-b border-border">
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Address</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Role</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Invite Code</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Remaining</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Agents</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Coop Arb</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Disclaimer</th>
                      <th className="text-left py-3 px-4 font-medium text-fg-2">Status</th>
                      <th className="text-right py-3 px-4 font-medium text-fg-2">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {users.map((u) => (
                      <tr key={u.wallet_address} className="border-b border-border/50 hover:bg-bg-1/50">
                        <td className="py-3 px-4 font-mono text-sm">{formatAddress(u.wallet_address)}</td>
                        <td className="py-3 px-4">
                          <Badge variant={u.role === 'admin' ? 'primary' : 'default'}>{u.role}</Badge>
                        </td>
                        <td className="py-3 px-4 font-mono text-sm">{u.invite_code || '-'}</td>
                        <td className="py-3 px-4">
                          <Input
                            type="number"
                            value={u.invite_remaining_uses || 0}
                            onChange={(e) => {
                              const val = parseInt((e.target as HTMLInputElement).value, 10);
                              if (!isNaN(val) && val >= 0) {
                                handleSetInviteCount(u.wallet_address, val);
                              }
                            }}
                            className="w-20 h-8 px-2 text-sm"
                            variant="number"
                            min="0"
                          />
                        </td>
                        <td className="py-3 px-4">
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => handleSetCanUseAgents(u.wallet_address, !u.can_use_agents)}
                            className={u.can_use_agents ? 'text-primary' : 'text-fg-2'}
                          >
                            <Icon name={u.can_use_agents ? 'check-circle' : 'x-circle'} className="w-4 h-4" />
                          </Button>
                        </td>
                        <td className="py-3 px-4">
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => handleSetCoopArb(u.wallet_address, !u.coop_arb_status)}
                            className={u.coop_arb_status ? 'text-primary' : 'text-fg-2'}
                          >
                            <Icon name={u.coop_arb_status ? 'check-circle' : 'x-circle'} className="w-4 h-4" />
                          </Button>
                        </td>
                        <td className="py-3 px-4">
                          <Badge variant={u.disclaimer_signed ? 'primary' : 'negative'}>
                            {u.disclaimer_signed ? 'Signed' : 'Pending'}
                          </Badge>
                        </td>
                        <td className="py-3 px-4">
                          {u.banned ? (
                            <Badge variant="negative">Banned</Badge>
                          ) : (
                            <Badge variant="default">Active</Badge>
                          )}
                        </td>
                        <td className="py-3 px-4 text-right">
                          <div className="flex items-center justify-end gap-2">
                            {u.invite_code && (
                              <Button
                                variant="outlined"
                                size="xs"
                                onClick={() => handleRevokeInvite(u.wallet_address)}
                                title="Revoke Invite"
                              >
                                <Icon name="link-slash" className="w-3 h-3" />
                              </Button>
                            )}
                            <Button
                              variant={u.banned ? 'primary' : 'outlined'}
                              size="xs"
                              onClick={() => handleBanUser(u.wallet_address, !u.banned)}
                            >
                              {u.banned ? 'Unban' : 'Ban'}
                            </Button>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      )}

      {/* Invite Management Tab */}
      {activeTab === 'invites' && (
        <div className="space-y-6">
          {/* Grant Invite Card */}
          <Card>
            <CardHeader>
              <CardTitle>Grant Invite</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-fg-2 mb-2">Wallet Address</label>
                <Input
                  value={inviteAddress}
                  onInput={(e) => setInviteAddress((e.target as HTMLInputElement).value)}
                  placeholder="0x..."
                  className="font-mono"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-fg-2 mb-2">Invite Code</label>
                <Input
                  value={inviteCode}
                  onInput={(e) => {
                    const val = (e.target as HTMLInputElement).value;
                    if (val.length <= 6) setInviteCode(val);
                  }}
                  placeholder="123456"
                  className="font-mono"
                />
              </div>
            </CardContent>
            <CardFooter>
              <Button
                variant="primary"
                onClick={handleGrantInvite}
                disabled={isGrantingInvite || !inviteAddress || !inviteCode}
                className="ml-auto"
              >
                {isGrantingInvite ? 'Granting...' : 'Grant Invite'}
              </Button>
            </CardFooter>
          </Card>

          {/* Your Invite Code Card */}
          <Card>
            <CardHeader>
              <CardTitle>Your Invite Code</CardTitle>
            </CardHeader>
            <CardContent>
              {user.invite_code ? (
                <>
                  <div className="flex items-center justify-between p-4 bg-bg-2 rounded-lg border border-border">
                    <div>
                      <p className="text-sm text-fg-2 mb-1">Invite Code</p>
                      <p className="text-2xl font-bold font-mono text-primary">{user.invite_code}</p>
                    </div>
                    <div className="text-right">
                      <p className="text-sm text-fg-2 mb-1">Remaining Uses</p>
                      <p className="text-xl font-bold">{user.invite_remaining_uses || 0}</p>
                    </div>
                  </div>
                  <p className="text-sm text-fg-2 mt-3">
                    Share your invite code with trusted users. Each code can be used up to {user.invite_remaining_uses || 0} times.
                  </p>
                </>
              ) : (
                <p className="text-fg-2 text-center py-4">You don't have an invite code yet.</p>
              )}
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  );
}
