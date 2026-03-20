/**
 * Simple JWT-like auth for backend services
 * Uses Bun's native crypto for HMAC-SHA256 signing
 */
import { createHmac } from 'crypto';

const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-in-production';
const TOKEN_EXPIRY_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

export interface TokenPayload {
  address: string;
  role: 'admin' | 'user';
  iat?: number;
  exp?: number;
}

function base64UrlEncode(data: string): string {
  return Buffer.from(data).toString('base64url');
}

function base64UrlDecode(data: string): string {
  return Buffer.from(data, 'base64url').toString('utf8');
}

function sign(data: string): string {
  return createHmac('sha256', JWT_SECRET).update(data).digest('hex');
}

/**
 * Generate a signed token
 */
export async function generateToken(payload: Omit<TokenPayload, 'iat' | 'exp'>): Promise<string> {
  const now = Date.now();
  const fullPayload: TokenPayload = {
    ...payload,
    iat: now,
    exp: now + TOKEN_EXPIRY_MS,
  };

  const header = base64UrlEncode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = base64UrlEncode(JSON.stringify(fullPayload));
  const signature = sign(`${header}.${body}`);

  return `${header}.${body}.${signature}`;
}

/**
 * Verify and decode a token
 */
export function verifyToken(token: string): TokenPayload | null {
  try {
    const [header, body, signature] = token.split('.');
    if (!header || !body || !signature) return null;

    // Verify signature
    const expectedSig = sign(`${header}.${body}`);
    if (signature !== expectedSig) return null;

    // Decode payload
    const payload = JSON.parse(base64UrlDecode(body)) as TokenPayload;

    // Check expiry
    if (payload.exp && Date.now() > payload.exp) return null;

    return payload;
  } catch {
    return null;
  }
}

/**
 * Extract bearer token from request
 */
export function extractBearerToken(req: Request): string | null {
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ')) return null;
  return auth.slice(7);
}
