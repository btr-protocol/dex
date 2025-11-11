# Code Export Script (`./dump`)

A utility script to export project code to a single text file using [repo2txt](https://github.com/your-repo/repo2txt).

## Features

- Exports file tree structure followed by file contents
- Supports selective export by component (contracts and SDK modules)
- Automatically excludes generated files
- Creates timestamped output files in `./dumps/` directory
- Color-coded terminal output
- Mix and match contracts and SDK modules in a single export

## Usage

```bash
./dump [OPTIONS]
```

### Options

#### Contract Options
- `--bamm` - Export core BAMM contracts
- `--darkpool` - Export darkpool contracts
- `--hooks` - Export hooks implementations
- `--circuits` - Export circuit files

#### Documentation Options
- `--specs` - Export specification documents

#### SDK Options
- `--sdk-common` - Export SDK common utilities (types, constants, utils)
- `--sdk-darkpool` - Export SDK darkpool module (note, merkle tree, proof builder)
- `--sdk-circuits` - Export SDK circuits module
- `--sdk-oracles` - Export SDK oracles module (base oracle, binance oracle)
- `--sdk-guardians` - Export SDK guardians module (circuit breaker, base guardian)
- `--sdk-flows` - Export SDK flows module (deposit, swap, withdraw)
- `--sdk-abis` - Export SDK ABIs (contract ABIs for BAMM and DarkPool)

#### What Gets Exported

**`--bamm`** exports only:
- BAMM.sol
- BAMMFactory.sol
- BAMMHookRegistry.sol
- BAMMManagement.sol
- libraries/LibPricing.sol

**`--darkpool`** exports only:
- DarkPool.sol
- DarkPoolFactory.sol
- libraries/LibBAMM.sol
- libraries/LibMerkleTree.sol
- libraries/LibVerifier.sol

**`--hooks`** exports:
- All files in contracts/src/hooks/

**`--circuits`** exports:
- All files in circuits/

**`--specs`** exports:
- All specification documents from specs/ (16 markdown files including ARCHITECTURE, DARK_POOL, HOOKS_SPECIFICATION, ORACLE, etc.)

### Examples

#### Contract Exports
```bash
# Export BAMM contracts only
./dump --bamm

# Export darkpool contracts only
./dump --darkpool

# Export both BAMM and darkpool
./dump --bamm --darkpool

# Export hooks only
./dump --hooks
```

#### Documentation Exports
```bash
# Export specification documents
./dump --specs

# Export BAMM contracts with specs
./dump --bamm --specs
```

#### SDK Exports
```bash
# Export SDK darkpool with common utilities
./dump --sdk-darkpool --sdk-common

# Export SDK oracles and guardians with common utilities
./dump --sdk-oracles --sdk-guardians --sdk-common

# Export all SDK modules
./dump --sdk-common --sdk-darkpool --sdk-circuits --sdk-oracles --sdk-guardians --sdk-flows --sdk-abis
```

#### Mixed Exports
```bash
# Export BAMM contracts with SDK flows
./dump --bamm --sdk-flows

# Export darkpool contracts with SDK darkpool
./dump --darkpool --sdk-darkpool --sdk-common

# Export everything
./dump --bamm --darkpool --hooks --circuits --sdk-common --sdk-darkpool --sdk-oracles
```

## Output

Files are saved to `./dumps/` with the format:
```
<components>_<timestamp>.txt
```

For example:
- `bamm_20251111_162301.txt`
- `bamm_darkpool_20251111_162309.txt`
- `hooks_20251111_162315.txt`
- `specs_20251111_175333.txt`
- `bamm_specs_20251111_175339.txt`
- `sdk-common_sdk-darkpool_20251111_172849.txt`
- `bamm_sdk-flows_20251111_172900.txt`

## Structure

The output file contains:
1. A visual tree structure of the exported files
2. File contents, one after another, with clear path markers

Example output for `./dump --bamm`:
```
+--------------------------+
| Dump tree for directory |
+--------------------------+
└── bamm
   ├── BAMM.sol
   ├── BAMMFactory.sol
   ├── BAMMHookRegistry.sol
   ├── BAMMManagement.sol
   └── libraries
      └── LibPricing.sol

--- Path: /path/to/bamm/BAMM.sol ---
[file contents]

--- Path: /path/to/bamm/BAMMFactory.sol ---
[file contents]
...
```

## Requirements

- Bash shell
- Python 3
- repo2txt installed at `~/Work/repo2txt/`

## Notes

- Generated files (e.g., `darkpool/libraries/generated/*`) are automatically excluded
- Backup files (`*.bak`) are excluded
- Lock files (`*.lock`) are excluded
- Output files include both the tree structure and full file contents for easy LLM consumption
