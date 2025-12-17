# Claude AI Development Guide

This project uses Claude AI for development assistance and automation.

## Documentation

For comprehensive information about using Claude AI agents with this project, see:

**→ [`AGENTS.md`](AGENTS.md)**

The `AGENTS.md` file contains:
- Agent configuration and usage
- Development workflows
- Best practices for AI-assisted development
- Project-specific conventions
- Task automation guidelines

---

## Quick Links

| Topic | File |
|-------|------|
| **Agent Usage & Setup** | [`AGENTS.md`](AGENTS.md) |
| **Project Architecture** | [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) |
| **Fee System** | [`specs/FEES.md`](specs/FEES.md) |
| **Coverage Ratio ALM** | [`specs/ALM_COVERAGE_RATIO.md`](specs/ALM_COVERAGE_RATIO.md) |
| **Oracle System** | [`specs/ORACLE.md`](specs/ORACLE.md) |

---

## Current Status

**Date**: 2025-01-11

### Recent Work

- ✅ Tri-factor fee model implementation complete
- ✅ Unified volatility system (single decode, reused for breadth + fees)
- ✅ Coverage ratio-based ALM (Wombat-style reserves/liabilities)
- ✅ Coverage ratio haircut for withdrawals
- ✅ All interfaces consolidated to `contracts/src/interfaces/`
- ✅ Comprehensive documentation updated

### Production Status

- ✅ **Code**: Compiles cleanly (zero errors in production code)
- ✅ **Docs**: Consolidated and comprehensive
- ✅ **Tests**: Pending (test file signature updates needed)

---

For detailed agent instructions and workflows, see [`AGENTS.md`](AGENTS.md).

---

## Documentation Location

**CRITICAL: All specs live in `./specs/`**

- ✅ **Canonical location**: `/specs/` (root-level)

**When handling duplicate files:**
1. **ALWAYS check modification dates** (use `stat` or `ls -lh`) before overwriting
2. **ALWAYS compare content** with `diff` to verify newer version is superset
3. **ALWAYS ask user for confirmation** before overwriting or deleting files
4. **Document the consolidation** in commit message

**Never assume newer = better**—always verify!

---

## Package Manager - BUN ONLY

**⚠️ CRITICAL: Use `bun` EXCLUSIVELY for all package management tasks.**

- ❌ **NEVER** use `npm` (not installed, not configured, DO NOT USE)
- ❌ **NEVER** use `yarn` (deprecated)
- ✅ **ALWAYS** use `bun install`, `bun add`, `bun run`

Examples:
```bash
bun install          # Install dependencies
bun add package      # Add a package
bun run dev          # Run dev server
bun run build        # Build project
```

---

## Communication Style

**CRITICAL: Keep responses SHORT and CONCISE.**

- ❌ **NO** long summaries after completing tasks
- ❌ **NO** verbose explanations unless explicitly requested
- ❌ **NO** repeating what you just did in detail
- ✅ **YES** brief status updates (1-2 lines)
- ✅ **YES** ask questions when needed
- ✅ **YES** report errors concisely

**Example of good communication:**
```
✅ Fixed all struct optimizations. Main contracts compile. Tests need updates.
```

**Example of bad communication:**
```
❌ [15 paragraphs explaining every change made, gas savings, rationale, etc.]
```

**When to be verbose:**
- When explicitly asked for details
- When writing documentation files
- When explaining complex architectural decisions
