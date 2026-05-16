# Agent Guidelines

**For AI assistants working on this codebase.**

---

## Quick Start

Read the guide for your task (canonical docs tree lives at `~/Work/btr/docs/`):

| Role | Guide |
|------|-------|
| **Frontend** | [`~/Work/btr/docs/dex/6. Contributing/FRONTEND.md`](../docs/dex/6.%20Contributing/FRONTEND.md) |
| **Backend** | [`~/Work/btr/docs/dex/6. Contributing/BACKEND.md`](../docs/dex/6.%20Contributing/BACKEND.md) |
| **Smart Contracts** | [`~/Work/btr/docs/dex/6. Contributing/SMART_CONTRACTS.md`](../docs/dex/6.%20Contributing/SMART_CONTRACTS.md) |
| **Security/Audit** | [`~/Work/btr/docs/dex/6. Contributing/SECURITY.md`](../docs/dex/6.%20Contributing/SECURITY.md) |
| **Quant/Research** | [`~/Work/btr/docs/dex/6. Contributing/QUANT.md`](../docs/dex/6.%20Contributing/QUANT.md) |
| **Git Workflow** | [`~/Work/btr/docs/dex/6. Contributing/GIT.md`](../docs/dex/6.%20Contributing/GIT.md) |
| **Markdown/Tables** | [`~/Work/btr/docs/dex/6. Contributing/HEADLESS_TABLES.md`](../docs/dex/6.%20Contributing/HEADLESS_TABLES.md) |

---

## Critical Rules

1. **Package Manager**: Use `bun` exclusively - NEVER npm/yarn
2. **Git Identity**: Always use the user's git identity - NEVER use agent/AI names as commit author
3. **Dead Code**: ZERO TOLERANCE - delete unused code immediately
4. **Communication**: Keep responses SHORT - brief status, no verbose summaries

---

## Problem Solving

When you don't know something:
1. **WebSearch first** - Use WebSearch to find current information
2. **Ask second** - If web search doesn't help, ask the user

---

## Tech Stack Overview

| Area | Technology |
|------|------------|
| **Runtime** | Bun (not Node.js) |
| **Frontend** | Native Preact (no compat), Signals, Tailwind CSS |
| **Backend** | Bun + TypeScript + SQLite |
| **Contracts** | Solidity 0.8.35 (exact) |
| **Testing** | Bun test, Foundry |
| **Linting** | oxlint |
| **Charts** | TradingView Lightweight, SVG (no chart.js) |

---

## Project Structure

```
dex/
├── evm/         # Solidity contracts (Foundry)
├── sim/         # Off-chain simulation harness (Zig)
├── svm/         # Reserved for Solana port
├── scripts/     # Tooling (search index, slot computation, plotting, local dev)
└── salts/       # CREATE3 salt registry (deterministic addresses)
```

Off-chain code lives in sibling repos under `~/Work/btr/`:
`sdk/` (ABIs + EVM client), `swap/` (aggregator SDK), `back/` (Bun services), `front/` (Preact SPA), `alm/` (ALM vault contracts), `shared/` (shared Solidity primitives).

---

## Module Commands

All modules support:
```bash
bun run dev           # Development server
bun run build         # Production build
bun run typecheck     # Type check with tsgo
bun run lint          # Lint with oxlint
bun run fmt           # Format with oxlint
```

Root level:
```bash
bun run dev           # Start front + back in parallel
bun run build         # Build all modules
bun run typecheck     # Type check all
bun run lint          # Lint entire codebase
```

---

## Key Policies

### Dead Code
- NO deprecated code, backward compatibility layers
- NO commented-out code blocks
- NO unused imports, functions, types, or variables
- Delete unused code immediately

### Comments
- Explain WHY, not WHAT
- Keep non-obvious logic, invariants, safety constraints
- Remove decorative ASCII art, verbose headers

### Git
- Atomic commits (one logical change)
- Category prefixes: `feat`, `fix`, `docs`, `refac`, `ops`
- NEVER mention AI tools in commit messages
- Use user's git identity (not agent/AI)

---

*For detailed guidelines, see the role-specific guides listed above.*
