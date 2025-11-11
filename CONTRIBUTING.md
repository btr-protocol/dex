# Contributing to BAMM

## Atomic Commits

**All commits must be atomic** - one focused change per commit.

✅ Good: Add single function, fix one bug, update one doc section
❌ Bad: Multiple features + bugs + docs in one commit

**Rule**: If your commit message needs "and", split it into multiple commits.

---

## Commit Categories

| Category | Prefix | Purpose |
|----------|--------|---------|
| **Feature** | `feat` | New functionality, enhancements |
| **Fix** | `fix` | Bug fixes, error corrections |
| **Documentation** | `docs` | Documentation updates only (no code logic) |
| **Refactor** | `refac` | Code restructuring, same behavior |
| **Operations** | `ops` | CI/CD, build, tooling |

---

## Branch Naming

Format: `<category>/<brief-description>`

**Rules**:
- Lowercase only
- Separate words with hyphens
- Keep brief (2-4 words)

**Examples**:
- `feat/unified-volatility`
- `fix/oracle-precision`
- `docs/update-readme`
- `refac/pricing-lib`
- `ops/ci-pipeline`

---

## Commit Messages

Format:
```
[category] Brief description in imperative mood

Optional detailed explanation.
```

**Rules**:
1. Prefix: `[category]` in lowercase
2. Imperative mood: "Add" not "Added"
3. First line ≤ 72 characters
4. Optional body after blank line

**Examples**:

✅ Good:
```
[feat] Add baseline volatility calculation
[fix] Correct coverage ratio haircut
[docs] Update fee system documentation
[refac] Extract helper function
```

❌ Bad:
```
Update stuff
Fixed things
feat: Add feature (wrong format)
[FEAT] Add (uppercase)
```

---

## Pull Requests

**Title**: Same format as commit messages: `[category] Brief description`

**Size**:
- Small: < 200 lines (ideal)
- Medium: 200-500 lines (acceptable)
- Large: > 500 lines (split into smaller PRs)

---

## Pre-Commit Checklist

- [ ] Change is atomic (one logical change)
- [ ] Correct category prefix used
- [ ] Commit message in imperative mood
- [ ] First line ≤ 72 characters
- [ ] Code compiles without errors
- [ ] Only related files included

---

## Related Documentation

- [`AGENTS.md`](AGENTS.md) - AI agent guidelines
- [`CLAUDE.md`](CLAUDE.md) - Claude AI guide
- [`README.md`](README.md) - Project overview
