/**
 * API user storage for backend
 * Uses SQLite via Bun's built-in support
 */
import { Database } from 'bun:sqlite';
import { apiUsersDBPath } from './storage.js';

export interface User {
  wallet_address: string;
  role: 'admin' | 'user';
  invited: number; // 1 = true, 0 = false (SQLite boolean)
  disclaimer_signed: number;
  disclaimer_signed_at: string | null;
  disclaimer_expiry: string | null;
  can_use_agents: number;
  coop_arb_status: number;
  banned: number;
  invite_code: string | null;
  invite_remaining_uses: number;
  parent_invite_code: string | null;
  created_at: string;
  updated_at: string;
}

let db: Database | null = null;

function getDB(): Database {
  if (db) return db;

  db = new Database(apiUsersDBPath);

  // Create tables
  db.run(`
    CREATE TABLE IF NOT EXISTS users (
      wallet_address TEXT PRIMARY KEY,
      role TEXT DEFAULT 'user',
      invited INTEGER DEFAULT 0,
      disclaimer_signed INTEGER DEFAULT 0,
      disclaimer_signed_at TEXT,
      disclaimer_expiry TEXT,
      can_use_agents INTEGER DEFAULT 1,
      coop_arb_status INTEGER DEFAULT 0,
      banned INTEGER DEFAULT 0,
      invite_code TEXT UNIQUE,
      invite_remaining_uses INTEGER DEFAULT 3,
      parent_invite_code TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  `);

  return db;
}

export interface UserStorage {
  getUserByAddress(address: string): User | null;
  getUserByInviteCode(code: string): User | null;
  upsertUser(address: string, role?: 'admin' | 'user', parentInviteCode?: string): Promise<void>;
  markDisclaimerSigned(address: string): Promise<void>;
  updateUser(address: string, updates: Partial<User>): Promise<void>;
  updateUserBanStatus(address: string, banned: boolean): Promise<void>;
  updateUserInvitedStatus(address: string, invited: boolean): Promise<void>;
  updateUserInviteRemainingUses(address: string, remainingUses: number): Promise<void>;
  updateCoopArbStatus(address: string, status: boolean): Promise<void>;
  updateUserCanUseAgents(address: string, canUse: boolean): Promise<void>;
  listUsers(): User[];
  close(): void;
}

function createUserStorage(): UserStorage {
  const database = getDB();

  return {
    getUserByAddress(address: string): User | null {
      const stmt = database.prepare('SELECT * FROM users WHERE LOWER(wallet_address) = LOWER(?)');
      return stmt.get(address) as User | null;
    },

    getUserByInviteCode(code: string): User | null {
      const stmt = database.prepare('SELECT * FROM users WHERE invite_code = ?');
      return stmt.get(code) as User | null;
    },

    async upsertUser(address: string, role: 'admin' | 'user' = 'user', parentInviteCode?: string): Promise<void> {
      const existing = this.getUserByAddress(address);

      if (existing) {
        // Update existing user
        const stmt = database.prepare(`
          UPDATE users SET
            invited = 1,
            parent_invite_code = COALESCE(?, parent_invite_code),
            updated_at = CURRENT_TIMESTAMP
          WHERE LOWER(wallet_address) = LOWER(?)
        `);
        stmt.run(parentInviteCode || null, address);

        // Decrement inviter's remaining uses
        if (parentInviteCode) {
          const decrementStmt = database.prepare(`
            UPDATE users SET
              invite_remaining_uses = MAX(0, invite_remaining_uses - 1),
              updated_at = CURRENT_TIMESTAMP
            WHERE invite_code = ?
          `);
          decrementStmt.run(parentInviteCode);
        }
      } else {
        // Generate invite code for new user
        const inviteCode = `${address.slice(2, 8).toUpperCase()}${Date.now().toString(36).toUpperCase()}`;

        const stmt = database.prepare(`
          INSERT INTO users (wallet_address, role, invited, invite_code, parent_invite_code)
          VALUES (LOWER(?), ?, 1, ?, ?)
        `);
        stmt.run(address, role, inviteCode, parentInviteCode || null);

        // Decrement inviter's remaining uses
        if (parentInviteCode) {
          const decrementStmt = database.prepare(`
            UPDATE users SET
              invite_remaining_uses = MAX(0, invite_remaining_uses - 1),
              updated_at = CURRENT_TIMESTAMP
            WHERE invite_code = ?
          `);
          decrementStmt.run(parentInviteCode);
        }
      }
    },

    async markDisclaimerSigned(address: string): Promise<void> {
      const now = new Date();
      const expiry = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000); // 30 days

      const stmt = database.prepare(`
        UPDATE users SET
          disclaimer_signed = 1,
          disclaimer_signed_at = ?,
          disclaimer_expiry = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(now.toISOString(), expiry.toISOString(), address);
    },

    async updateUser(address: string, updates: Partial<User>): Promise<void> {
      const fields = Object.keys(updates)
        .filter(k => k !== 'wallet_address' && k !== 'created_at')
        .map(k => `${k} = ?`);

      if (fields.length === 0) return;

      const values = Object.keys(updates)
        .filter(k => k !== 'wallet_address' && k !== 'created_at')
        .map(k => (updates as any)[k]);

      const stmt = database.prepare(`
        UPDATE users SET ${fields.join(', ')}, updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(...values, address);
    },

    async updateUserBanStatus(address: string, banned: boolean): Promise<void> {
      const stmt = database.prepare(`
        UPDATE users SET
          banned = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(banned ? 1 : 0, address);
    },

    async updateUserInvitedStatus(address: string, invited: boolean): Promise<void> {
      const stmt = database.prepare(`
        UPDATE users SET
          invited = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(invited ? 1 : 0, address);
    },

    async updateUserInviteRemainingUses(address: string, remainingUses: number): Promise<void> {
      const stmt = database.prepare(`
        UPDATE users SET
          invite_remaining_uses = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(remainingUses, address);
    },

    async updateCoopArbStatus(address: string, status: boolean): Promise<void> {
      const stmt = database.prepare(`
        UPDATE users SET
          coop_arb_status = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(status ? 1 : 0, address);
    },

    async updateUserCanUseAgents(address: string, canUse: boolean): Promise<void> {
      const stmt = database.prepare(`
        UPDATE users SET
          can_use_agents = ?,
          updated_at = CURRENT_TIMESTAMP
        WHERE LOWER(wallet_address) = LOWER(?)
      `);
      stmt.run(canUse ? 1 : 0, address);
    },

    listUsers(): User[] {
      const stmt = database.prepare('SELECT * FROM users ORDER BY created_at DESC');
      return stmt.all() as User[];
    },

    close(): void {
      if (db) {
        db.close();
        db = null;
      }
    },
  };
}

let instance: UserStorage | null = null;

export async function getUserStorage(): Promise<UserStorage> {
  if (!instance) {
    instance = createUserStorage();
  }
  return instance;
}

export { User as UserType };
