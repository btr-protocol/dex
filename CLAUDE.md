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
