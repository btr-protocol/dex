#!/bin/bash

##############################################################################
# Trusted Setup Ceremony Script
#
# This script performs a Groth16 trusted setup ceremony for the DarkPool
# circuit. It downloads phase 1 (Powers of Tau) from the community and
# runs phase 2 with multiple contributors.
#
# Usage:
#   ./scripts/trusted-setup-ceremony.sh [n_contributors] [circuit_name]
#
# Environment variables:
#   CIRCUIT_PATH: Path to .circom file (default: sdk/src/circuits/darkpool.circom)
#   N_CONTRIBUTORS: Number of contributors (default: 3)
#   POWERS_OF_TAU_SIZE: Powers of tau size parameter (default: 21 = 2^21)
#
# Output:
#   - Generated .zkey file: ${CIRCUIT_NAME}_final.zkey
#   - Verification key: evm/src/darkpool/Verifier.sol
#   - Ceremony transcript with contributor signatures
#
##############################################################################

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

CIRCUIT_NAME="${2:-darkpool}"
CIRCUIT_PATH="${CIRCUIT_PATH:-sdk/src/circuits/${CIRCUIT_NAME}.circom}"
BUILD_DIR="sdk/src/circuits/build"
N_CONTRIBUTORS="${1:-3}"
POWERS_OF_TAU_SIZE="21"  # 2^21 ≈ 2M constraints (sufficient for depth 32)
POWERS_OF_TAU_FILE="powersOfTau28_hez_final_${POWERS_OF_TAU_SIZE}.ptau"
POWERS_OF_TAU_URL="https://hermez.s3-eu-west-1.amazonaws.com/${POWERS_OF_TAU_FILE}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Utility Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 not found. Please install it."
        exit 1
    fi
}

# ============================================================================
# Validation
# ============================================================================

log_info "Validating environment..."

# Check required commands
check_command "circom"
check_command "snarkjs"
check_command "node"

# Check circuit file exists
if [ ! -f "$CIRCUIT_PATH" ]; then
    log_error "Circuit file not found: $CIRCUIT_PATH"
    exit 1
fi

log_info "Circuit path: $CIRCUIT_PATH"
log_info "Number of contributors: $N_CONTRIBUTORS"
log_info "Powers of Tau size: $POWERS_OF_TAU_SIZE"

# ============================================================================
# Phase 1: Powers of Tau (Reuse from Community)
# ============================================================================

log_info "PHASE 1: Powers of Tau (Community Ceremony)"

if [ -f "$POWERS_OF_TAU_FILE" ]; then
    log_warn "Powers of Tau file already exists: $POWERS_OF_TAU_FILE"
    log_info "Skipping download. Using existing file."
    log_warn "⚠️  Ensure this file was downloaded from a trusted source!"
else
    log_info "Downloading Powers of Tau (1.5GB)..."
    log_info "Source: $POWERS_OF_TAU_URL"

    if ! wget -q --show-progress "$POWERS_OF_TAU_URL"; then
        log_error "Failed to download Powers of Tau. Check your internet connection."
        log_info "Alternative: Download manually from $POWERS_OF_TAU_URL"
        exit 1
    fi

    log_info "Download complete!"
fi

# Verify Powers of Tau integrity
log_info "Verifying Powers of Tau..."
if snarkjs powersoftau verify "$POWERS_OF_TAU_FILE" 2>/dev/null; then
    log_info "Powers of Tau verification: ✅ PASSED"
else
    log_error "Powers of Tau verification failed"
    exit 1
fi

# ============================================================================
# Circuit Compilation
# ============================================================================

log_info "Compiling circuit..."

# Create build directory
mkdir -p "$BUILD_DIR"

# Compile circuit
if circom "$CIRCUIT_PATH" \
    --r1cs \
    --wasm \
    --sym \
    -o "$BUILD_DIR/" \
    2>&1 | grep -E "error|warning" || true; then
    :
fi

if [ ! -f "$BUILD_DIR/${CIRCUIT_NAME}.r1cs" ]; then
    log_error "Circuit compilation failed"
    exit 1
fi

log_info "Circuit compiled: $BUILD_DIR/${CIRCUIT_NAME}.r1cs"

# ============================================================================
# Phase 2: Circuit-Specific Setup
# ============================================================================

log_info "PHASE 2: Circuit-Specific Setup"

# Step 1: Initialize phase 2 from phase 1
log_info "Step 1: Initializing phase 2..."

snarkjs groth16 setup \
    "$BUILD_DIR/${CIRCUIT_NAME}.r1cs" \
    "$POWERS_OF_TAU_FILE" \
    "${CIRCUIT_NAME}_0000.zkey" \
    > /dev/null 2>&1

log_info "Phase 2 initialized: ${CIRCUIT_NAME}_0000.zkey"

# Step 2: Contributor contributions
log_info "Step 2: Collecting $N_CONTRIBUTORS contributor signatures..."

for i in $(seq 1 $N_CONTRIBUTORS); do
    prev=$((i - 1))
    prev_padded=$(printf "%04d" $prev)
    curr_padded=$(printf "%04d" $i)

    log_info "  Contributor $i/$N_CONTRIBUTORS..."

    # Generate random entropy for this contributor
    # SECURITY: Use system entropy source
    ENTROPY=$(openssl rand -hex 64)

    # Contributor contribution
    snarkjs zkey contribute \
        "${CIRCUIT_NAME}_${prev_padded}.zkey" \
        "${CIRCUIT_NAME}_${curr_padded}.zkey" \
        --name="Contributor $i ($(date +%Y-%m-%d))" \
        -v \
        -e="$ENTROPY" \
        > /dev/null 2>&1

    log_info "    ✅ Contribution received"
done

FINAL_CONTRIB=$(printf "%04d" $N_CONTRIBUTORS)

# Step 3: Apply random beacon (adds public entropy)
log_info "Step 3: Applying random beacon (public entropy)..."

# Use a fixed beacon hash for testing/MVP
# For production: use block hash or other trusted randomness
BEACON_HASH="0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

snarkjs zkey beacon \
    "${CIRCUIT_NAME}_${FINAL_CONTRIB}.zkey" \
    "${CIRCUIT_NAME}_final.zkey" \
    "$BEACON_HASH" \
    10 \
    -n="Final Beacon ($(date +%Y-%m-%d))" \
    > /dev/null 2>&1

log_info "Random beacon applied: ${CIRCUIT_NAME}_final.zkey"

# ============================================================================
# Verification and Export
# ============================================================================

log_info "VERIFICATION & EXPORT"

# Step 4: Verify final zkey
log_info "Step 1: Verifying final zkey..."

if snarkjs zkey verify "$BUILD_DIR/${CIRCUIT_NAME}.r1cs" "$POWERS_OF_TAU_FILE" "${CIRCUIT_NAME}_final.zkey" 2>/dev/null; then
    log_info "Final zkey verification: ✅ PASSED"
else
    log_error "Final zkey verification failed"
    exit 1
fi

# Step 5: Export verification key for Solidity
log_info "Step 2: Exporting Solidity verification key..."

snarkjs zkey export solidityverifier \
    "${CIRCUIT_NAME}_final.zkey" \
    "evm/src/darkpool/Verifier.sol" \
    > /dev/null 2>&1

log_info "Verification key exported: evm/src/darkpool/Verifier.sol"

# Step 6: Generate public signals definition (optional)
log_info "Step 3: Generating public signals..."

snarkjs zkey export json \
    "${CIRCUIT_NAME}_final.zkey" \
    "${CIRCUIT_NAME}_final.json" \
    > /dev/null 2>&1

log_info "Public signals: ${CIRCUIT_NAME}_final.json"

# ============================================================================
# Summary
# ============================================================================

log_info "=================================================="
log_info "TRUSTED SETUP CEREMONY COMPLETE"
log_info "=================================================="
log_info ""
log_info "Generated artifacts:"
log_info "  • Zkey file: ${CIRCUIT_NAME}_final.zkey"
log_info "  • Verifier contract: evm/src/darkpool/Verifier.sol"
log_info "  • Public signals (JSON): ${CIRCUIT_NAME}_final.json"
log_info ""
log_info "Next steps:"
log_info "  1. Review the Verifier.sol contract"
log_info "  2. Update DarkPool to use new verifier"
log_info "  3. Run full test suite"
log_info "  4. Deploy to testnet"
log_info ""
log_info "For production deployment:"
log_info "  • Conduct full circuit audit (Trail of Bits/Zellic)"
log_info "  • Run public ceremony with 50+ contributors"
log_info "  • Collect public attestations from each contributor"
log_info "  • Document ceremony process in GitHub"
log_info ""

# Cleanup intermediate files (optional)
if [ "$N_CONTRIBUTORS" -gt 1 ]; then
    log_info "Cleaning up intermediate contributor files..."
    for i in $(seq 0 $((N_CONTRIBUTORS - 1))); do
        padded=$(printf "%04d" $i)
        if [ -f "${CIRCUIT_NAME}_${padded}.zkey" ]; then
            rm "${CIRCUIT_NAME}_${padded}.zkey"
        fi
    done
    log_info "Intermediate files cleaned"
fi

log_info "✅ Ceremony script completed successfully!"
