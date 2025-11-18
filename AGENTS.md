# Agent Guidelines

## Documentation Structure

### Project Root (`./`)
- **README.md ONLY** - Keep the project root clean with just the main README
- No other documentation files should be placed at the root level

### Specifications & Documentation (`./specs`)

**CRITICAL: All specs MUST live in `./specs/`**

- ✅ **Canonical location**: `./specs/` (root-level specs directory)
- All technical specifications should be placed in `./specs/`
- All work-in-progress documentation should be placed in `./specs/`
- All audit reports, fix summaries, and implementation notes should be placed in `./specs/`
- Organize documents by topic/feature within the specs directory

**When encountering duplicate spec files:**
1. **Check modification dates FIRST**: Use `ls -lh` or `stat` to compare timestamps
2. **Compare content**: Use `diff` to verify which version is more complete
3. **Ask user for confirmation**: NEVER automatically overwrite or delete without explicit approval
4. **Assume nothing**: Older files may contain unique content not in newer versions
5. **Document consolidation**: Explain what was merged/moved in commit messages

### Code Documentation
- Code should be well-commented with inline documentation
- Complex algorithms should reference the relevant spec document in `./specs/`
- Use NatSpec format for Solidity contracts

## File Organization

```
/
├── README.md                    # Main project README only
├── specs/                       # ✅ CANONICAL: All documentation and specs HERE
│   ├── ARCHITECTURE.md
│   ├── ORACLE.md
│   ├── FEES.md
│   ├── ALM_AND_COVERAGE.md
│   ├── CIRCUIT_BREAKERS.md
│   ├── LIABILITY_TIME_DECAY.md
│   ├── TOKENOMICS.md
│   ├── ALLOCATION_AND_VESTING.md
│   └── ...
├── contracts/
│   ├── src/
│   │   ├── specs/               # ❌ DEPRECATED: Do not use, may be outdated
│   │   └── ...
│   └── ...
├── sdk/                         # SDK implementation
└── ...
```

## Frontend Stack

**CRITICAL: Frontend uses ONLY Tailwind CSS + Radix UI**

- ✅ **Styling**: Tailwind CSS v3 (utility-first CSS framework)
- ✅ **Components**: Radix UI primitives (headless, accessible components)
- ❌ **NO Chakra UI**: DO NOT use or import Chakra UI under any circumstances
- ❌ **NO Material UI**: DO NOT use Material UI
- ❌ **NO other UI frameworks**: Stick to Tailwind + Radix only

**Typography:**
- Body & Headings: Inter Variable
- Numeric/Mono: Mozilla Text, SF Mono, Monaco (fallback chain)

## Guidelines for Agents

1. **Keep root clean**: Only README.md belongs at the project root
2. **Specs location**: All documentation, specifications, and notes go in `./specs/`
3. **No temporary files**: Move work-in-progress docs to `./specs/` when complete
4. **Reference properly**: When creating new code, reference existing specs in `./specs/`
5. **Update README**: Keep root README.md current with high-level project overview
6. **Commit conventions**: Follow atomic commit rules in [`CONTRIBUTING.md`](CONTRIBUTING.md)
7. **Frontend stack**: ONLY use Tailwind CSS + Radix UI (NO Chakra, NO Material UI)

## Communication Style

**KEEP RESPONSES CONCISE. NO LONG SUMMARIES.**

- Report status briefly (1-2 lines)
- Only elaborate when explicitly asked
- Write detailed docs in files, not in responses
- Example: "✅ Optimizations complete. Main contracts compile. Tests need updates."
