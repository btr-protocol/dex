# Agent Guidelines

## Documentation Structure

### Project Root (`./`)
- **README.md ONLY** - Keep the project root clean with just the main README
- No other documentation files should be placed at the root level

### Specifications & Documentation (`./specs`)
- All technical specifications should be placed in `./specs/`
- All work-in-progress documentation should be placed in `./specs/`
- All audit reports, fix summaries, and implementation notes should be placed in `./specs/`
- Organize documents by topic/feature within the specs directory

### Code Documentation
- Code should be well-commented with inline documentation
- Complex algorithms should reference the relevant spec document in `./specs/`
- Use NatSpec format for Solidity contracts

## File Organization

```
/
├── README.md                    # Main project README only
├── specs/                       # All documentation and specs
│   ├── ARCHITECTURE.md
│   ├── ORACLE.md
│   ├── FEES.md
│   └── ...
├── contracts/                   # Solidity contracts
├── sdk/                         # SDK implementation
└── ...
```

## Guidelines for Agents

1. **Keep root clean**: Only README.md belongs at the project root
2. **Specs location**: All documentation, specifications, and notes go in `./specs/`
3. **No temporary files**: Move work-in-progress docs to `./specs/` when complete
4. **Reference properly**: When creating new code, reference existing specs in `./specs/`
5. **Update README**: Keep root README.md current with high-level project overview
6. **Commit conventions**: Follow atomic commit rules in [`CONTRIBUTING.md`](CONTRIBUTING.md)
