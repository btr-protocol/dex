import { useState, useEffect, useCallback } from 'preact/hooks';
import type { Address, Hex } from '@sdk/eth';
import { logger } from '@sdk/utils';

const log = logger.withContext('auth');

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

const AUTH_TOKEN_KEY = 'btr-auth-token';
const AUTH_API_URL = import.meta.env.VITE_AUTH_API || 'http://localhost:4001';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface User {
  wallet_address: Address;
  role: 'admin' | 'user';
  invited: boolean;
  disclaimer_signed: boolean;
  disclaimer_signed_at?: string;
  disclaimer_expiry?: string;
  can_use_agents: boolean;
  coop_arb_status: boolean;
  banned: boolean;
  invite_code?: string;
  invite_remaining_uses?: number;
  parent_invite_code?: string;
  created_at?: string;
  updated_at?: string;
}

export interface AuthResponse {
  success: boolean;
  message?: string;
  token?: string;
  user?: User;
}

export interface DisconnectResponse {
  success: boolean;
  message?: string;
}

// ─────────────────────────────────────────────────────────────
// Token Management
// ─────────────────────────────────────────────────────────────

export function getAuthToken(): string | null {
  if (typeof localStorage === 'undefined') return null;
  return localStorage.getItem(AUTH_TOKEN_KEY);
}

export function setAuthToken(token: string): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.setItem(AUTH_TOKEN_KEY, token);
}

export function clearAuthToken(): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.removeItem(AUTH_TOKEN_KEY);
}

// ─────────────────────────────────────────────────────────────
// Fetch Interceptor
// ─────────────────────────────────────────────────────────────

/**
 * Create a fetch function that adds Bearer token and handles auth errors
 */
export function createAuthInterceptor(baseFetch: typeof fetch = fetch): (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const token = getAuthToken();

    // Add Authorization header if token exists
    const headers = new Headers(init?.headers);
    if (token) {
      headers.set('Authorization', `Bearer ${token}`);
    }

    const response = await baseFetch(input, {
      ...init,
      headers,
    });

    // Handle 401/403 - clear token and redirect
    if (response.status === 401 || response.status === 403) {
      clearAuthToken();
      // Redirect to guard page (will be handled by App.tsx check)
      window.location.href = '/';
    }

    // Check for new token in response headers
    if (response.ok) {
      const newToken = response.headers.get('Authorization');
      if (newToken) {
        // Remove 'Bearer ' prefix if present
        const tokenValue = newToken.startsWith('Bearer ')
          ? newToken.slice(7)
          : newToken;
        setAuthToken(tokenValue);
      }
    }

    return response;
  };
}

// Global auth fetch instance
export const authFetch = createAuthInterceptor();

// ─────────────────────────────────────────────────────────────
// SIWE (EIP-4361) Message Generation
// ─────────────────────────────────────────────────────────────

export interface SIWEMessage {
  domain: string;
  address: string;
  statement: string;
  uri: string;
  version: '1';
  chainId: number;
  nonce: string;
  issuedAt: string;
  expirationTime?: string;
}

/**
 * Generate SIWE-compliant sign-in message
 * Follows EIP-4361 standard with required fields
 */
export function generateSIWEMessage(address: string): SIWEMessage {
  const domain = window.location.hostname;
  const uri = window.location.origin;
  const timestamp = new Date();
  const issuedAt = new Date();
  const nonce = Math.floor(Math.random() * 4294967296).toString(); // 32-bit random
  const expirationTime = new Date(issuedAt.getTime() + 30 * 24 * 60 * 60 * 1000); // 30 days

  const termsUrl = `${uri}/terms-and-conditions`;
  const riskUrl = `${uri}/risk-disclaimer`;
  const statement = `By signing, you acknowledge that:\n1. You have read and agree to our Terms & Conditions: ${termsUrl}\n2. You understand the risks disclosed in our Risk Disclaimer: ${riskUrl}\n3. This signature is valid for 30 days from ${issuedAt.toISOString()}`;

  return {
    domain,
    address,
    statement,
    uri,
    version: '1',
    chainId: 1,
    nonce,
    issuedAt: issuedAt.toISOString(),
    expirationTime: expirationTime.toISOString(),
  };
}

/**
 * Format SIWE message as string for wallet signing
 */
export function formatSIWEMessage(siweMsg: SIWEMessage): string {
  return `${siweMsg.domain} wants you to sign in with your Ethereum account:
${siweMsg.uri}

${siweMsg.statement}

URI: ${siweMsg.uri}
Version: ${siweMsg.version}
Chain ID: ${siweMsg.chainId}
Nonce: ${siweMsg.nonce}
Issued At: ${siweMsg.issuedAt}
${siweMsg.expirationTime ? `Expiration Time: ${siweMsg.expirationTime}` : ''}
`;
}

/**
 * Format SIWE message as string for wallet signing (alternative)
 * For backward compatibility with simple message signing
 */
/**
 * Format SIWE message as string for wallet signing (alternative)
 * For backward compatibility with simple message signing
 */
export function formatSimpleMessage(siweMsg: SIWEMessage): string {
  return `${siweMsg.domain} wants you to sign in with your Ethereum account:
${siweMsg.uri}

${siweMsg.statement}

URI: ${siweMsg.uri}
Version: ${siweMsg.version}
Chain ID: ${siweMsg.chainId}
Nonce: ${siweMsg.nonce}
Issued At: ${siweMsg.issuedAt}
${siweMsg.expirationTime ? `Expiration Time: ${siweMsg.expirationTime}` : ''}
`;
}

// ─────────────────────────────────────────────────────────────
// API Client Functions
// ─────────────────────────────────────────────────────────────

/**
 * Check if invite code is valid
 */
export async function checkInvite(inviteCode: string): Promise<{ valid: boolean; message?: string }> {
  try {
    const response = await fetch(`${AUTH_API_URL}/api/auth/check-invite`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ inviteCode }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        valid: false,
        message: data.message || 'Invalid invite code',
      };
    }

    return {
      valid: data.valid === true,
      message: data.message,
    };
  } catch (error) {
    log.error('Check invite error', error);
    return {
      valid: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Verify invite code and authenticate
 */
export async function invite(
  inviteCode: string,
  signature: Hex,
  message: string,
  address: Address
): Promise<AuthResponse> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/auth/invite`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        inviteCode,
        signature,
        message,
        address: address.toLowerCase(),
      }),
    });

    const data = await response.json();

    if (!response.ok) {
      log.error('Invite verification failed', data);
      return {
        success: false,
        message: data.message || 'Failed to verify invite code',
      };
    }

    // Store token if provided
    if (data.token) {
      setAuthToken(data.token);
    }

    return {
      success: true,
      message: data.message,
      token: data.token,
      user: data.user,
    };
  } catch (error) {
    log.error('Invite request error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Disconnect current session
 */
export async function disconnect(): Promise<DisconnectResponse> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/auth/disconnect`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
    });

    const data = await response.json();

    if (!response.ok) {
      log.error('Disconnect failed', data);
      return {
        success: false,
        message: data.message || 'Failed to disconnect',
      };
    }

    // Clear local token
    clearAuthToken();

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Disconnect request error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Get current user info
 */
export async function getUserInfo(): Promise<{ success: boolean; user?: User; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/user/me`, {
      method: 'GET',
    });

    if (response.status === 401 || response.status === 403) {
      clearAuthToken();
      return {
        success: false,
        message: 'Session expired',
      };
    }

    if (!response.ok) {
      const data = await response.json();
      return {
        success: false,
        message: data.message || 'Failed to get user info',
      };
    }

    const data = await response.json();
    return {
      success: true,
      user: data,
    };
  } catch (error) {
    log.error('Get user info error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

// ─────────────────────────────────────────────────────────────
// Admin API Functions
// ─────────────────────────────────────────────────────────────

/**
 * Admin: List all users
 */
export async function listUsers(): Promise<{ success: boolean; users?: User[]; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/users`, {
      method: 'GET',
    });

    if (!response.ok) {
      const data = await response.json();
      return {
        success: false,
        message: data.message || 'Failed to list users',
      };
    }

    const data = await response.json();
    return {
      success: true,
      users: data,
    };
  } catch (error) {
    log.error('List users error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Ban/unban user
 */
export async function banUser(
  address: Address,
  banned: boolean
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/ban`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ banned }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to update ban status',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Ban user error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Revoke invite
 */
export async function revokeInvite(
  address: Address
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/revoke`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to revoke invite',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Revoke invite error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Grant invite to address
 */
export async function grantInvite(
  address: Address,
  inviteCode: string
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/grant`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ inviteCode }),
    });

    const data = await response.json();

    if (!response.ok) {
      log.error('Grant invite failed', data);
      return {
        success: false,
        message: data.message || 'Failed to grant invite',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Grant invite error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Set invite count
 */
export async function setInviteCount(
  address: Address,
  count: number
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/invite-count`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ count }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to set invite count',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Set invite count error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Toggle coop arb
 */
export async function setCoopArb(
  address: Address,
  status: boolean
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/coop-arb`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ status }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to update coop arb status',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Set coop arb error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Admin: Toggle can use agents
 */
export async function setCanUseAgents(
  address: Address,
  status: boolean
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/admin/user/${address.toLowerCase()}/can-use-agents`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ status }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to update agent access',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Set can use agents error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

// ─────────────────────────────────────────────────────────────
// Auth Hook
// ─────────────────────────────────────────────────────────────

/**
 * Sign disclaimer with wallet
 */
export async function signDisclaimer(
  address: Address,
  signature: Hex
): Promise<AuthResponse> {
  try {
    // Generate and format SIWE message
    const siweMsg = generateSIWEMessage(address);

    const response = await fetch(`${AUTH_API_URL}/api/auth/disclaimer-sign`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        signature,
        message: formatSimpleMessage(siweMsg),
        address: address.toLowerCase(),
      }),
    });

    const data = await response.json();

    if (!response.ok) {
      log.error('Disclaimer sign failed', data);
      return {
        success: false,
        message: data.message || 'Failed to sign disclaimer',
      };
    }

    // Store token if provided
    if (data.token) {
      setAuthToken(data.token);
    }

    return {
      success: true,
      message: data.message,
      token: data.token,
      user: data.user,
    };
  } catch (error) {
    log.error('Sign disclaimer error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

/**
 * Check if user needs to sign disclaimer
 */
export function needsDisclaimerSignature(user?: User): boolean {
  if (!user) return true;
  if (!user.disclaimer_signed || !user.disclaimer_expiry) return true;
  const expiry = new Date(user.disclaimer_expiry).getTime();
  return Date.now() > expiry;
}

/**
 * Update user's disclaimer signed status
 */
export async function updateDisclaimerStatus(signed: boolean): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await authFetch(`${AUTH_API_URL}/api/user/disclaimer`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ disclaimer_signed: signed }),
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        message: data.message || 'Failed to update disclaimer status',
      };
    }

    return {
      success: true,
      message: data.message,
    };
  } catch (error) {
    log.error('Update disclaimer status error', error);
    return {
      success: false,
      message: error instanceof Error ? error.message : 'Network error',
    };
  }
}

export function useAuth() {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  // Check session on mount
  const checkSession = useCallback(async () => {
    const token = getAuthToken();
    if (!token) {
      setIsAuthenticated(false);
      setUser(null);
      setIsLoading(false);
      return false;
    }

    setIsLoading(true);
    const result = await getUserInfo();

    if (result.success && result.user) {
      setIsAuthenticated(true);
      setUser(result.user);
      setIsLoading(false);
      return true;
    } else {
      setIsAuthenticated(false);
      setUser(null);
      setIsLoading(false);
      return false;
    }
  }, []);

  useEffect(() => {
    checkSession();
  }, [checkSession]);

  // Login with invite code and wallet signature
  const login = useCallback(async (code: string, address: Address, signFn: (message: string) => Promise<Hex>) => {
    setIsLoading(true);

    // Sign SIWE message
    const siweMsg = generateSIWEMessage(address);
    const message = formatSimpleMessage(siweMsg);
    let signature: Hex;

    try {
      signature = await signFn(message);
    } catch (error) {
      log.error('Failed to sign message', error);
      setIsLoading(false);
      return { success: false, message: 'Failed to sign message. Please try again.' };
    }

    // Verify invite
    const result = await invite(code, signature, message, address);

    if (result.success && result.user) {
      setIsAuthenticated(true);
      setUser(result.user);
    }

    setIsLoading(false);
    return result;
  }, []);

  // Logout
  const logout = useCallback(async () => {
    await disconnect();
    setIsAuthenticated(false);
    setUser(null);
  }, []);

  return {
    isAuthenticated,
    user,
    isLoading,
    login,
    logout,
    checkSession,
  };
}
