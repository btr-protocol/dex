# Agent Guidelines

**For AI assistants working on this codebase.**

---

## Quick Start

Read the guide for your task:

| Role | Guide |
|------|-------|
| **Frontend** | [`docs/6. Contributing/FRONTEND.md`](docs/6. Contributing/FRONTEND.md) |
| **Backend** | [`docs/6. Contributing/BACKEND.md`](docs/6. Contributing/BACKEND.md) |
| **Smart Contracts** | [`docs/6. Contributing/SMART_CONTRACTS.md`](docs/6. Contributing/SMART_CONTRACTS.md) |
| **Security/Audit** | [`docs/6. Contributing/SECURITY.md`](docs/6. Contributing/SECURITY.md) |
| **Quant/Research** | [`docs/6. Contributing/QUANT.md`](docs/6. Contributing/QUANT.md) |
| **Git Workflow** | [`docs/6. Contributing/GIT.md`](docs/6. Contributing/GIT.md) |
| **Markdown/Tables** | [`docs/6. Contributing/HEADLESS_TABLES.md`](docs/6. Contributing/HEADLESS_TABLES.md) |

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
| **Contracts** | Solidity 0.8.33 (exact) |
| **Testing** | Bun test, Foundry |
| **Linting** | oxlint |
| **Charts** | TradingView Lightweight, SVG (no chart.js) |

---

## Project Structure

```
dex/
├── sdk/           # Core SDK (tokens, chains, contracts metadata)
├── front/         # Preact frontend
├── back/collector/# Bun WebSocket server
└── contracts/     # Solidity contracts (Foundry)
```

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
