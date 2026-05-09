#!/usr/bin/env bash
# Script to count lines of code (LOC) for Solidity files
# Excludes dependencies (lib/, node_modules/), counts with and without comments

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== SOLIDITY LOC ANALYSIS ===${NC}\n"

# Function to count LOC
count_loc() {
    local file=$1
    local total=$(wc -l < "$file" | tr -d ' ')

    # Count non-empty, non-comment lines (approximation)
    local code=$(sed 's://.*::' "$file" | \
                 grep -v '^\s*$' | \
                 grep -cv '^\s*/\*' || echo "$total")

    echo "$total $code"
}

# Contracts
echo -e "${BLUE}CONTRACTS${NC}"
echo "File                                     Total LOC  Code LOC"
echo "───────────────────────────────────────────────────────────────"

total_contracts_total=0
total_contracts_code=0

for dir in evm/src/aimm evm/src/darkpool evm/src/oracles; do
    if [ -d "$dir" ]; then
        for file in "$dir"/*.sol; do
            if [ -f "$file" ]; then
                name=$(basename "$file")
                read total code < <(count_loc "$file")
                printf "%-40s %9d %10d\n" "$name" "$total" "$code"
                total_contracts_total=$((total_contracts_total + total))
                total_contracts_code=$((total_contracts_code + code))
            fi
        done
    fi
done

echo "───────────────────────────────────────────────────────────────"
printf "${YELLOW}%-40s %9d %10d${NC}\n" "TOTAL CONTRACTS" "$total_contracts_total" "$total_contracts_code"

# Libraries
echo -e "\n${BLUE}LIBRARIES${NC}"
echo "File                                     Total LOC  Code LOC"
echo "───────────────────────────────────────────────────────────────"

total_libs_total=0
total_libs_code=0

if [ -d "evm/src/libraries" ]; then
    for file in evm/src/libraries/*.sol; do
        if [ -f "$file" ]; then
            name=$(basename "$file")
            read total code < <(count_loc "$file")
            printf "%-40s %9d %10d\n" "$name" "$total" "$code"
            total_libs_total=$((total_libs_total + total))
            total_libs_code=$((total_libs_code + code))
        fi
    done
fi

echo "───────────────────────────────────────────────────────────────"
printf "${YELLOW}%-40s %9d %10d${NC}\n" "TOTAL LIBRARIES" "$total_libs_total" "$total_libs_code"

# Interfaces
echo -e "\n${BLUE}INTERFACES${NC}"
echo "File                                     Total LOC  Code LOC"
echo "───────────────────────────────────────────────────────────────"

total_interfaces_total=0
total_interfaces_code=0

if [ -d "evm/src/interfaces" ]; then
    for file in evm/src/interfaces/*.sol; do
        if [ -f "$file" ]; then
            name=$(basename "$file")
            read total code < <(count_loc "$file")
            printf "%-40s %9d %10d\n" "$name" "$total" "$code"
            total_interfaces_total=$((total_interfaces_total + total))
            total_interfaces_code=$((total_interfaces_code + code))
        fi
    done
fi

echo "───────────────────────────────────────────────────────────────"
printf "${YELLOW}%-40s %9d %10d${NC}\n" "TOTAL INTERFACES" "$total_interfaces_total" "$total_interfaces_code"

# Utilities
echo -e "\n${BLUE}UTILITIES${NC}"
echo "File                                     Total LOC  Code LOC"
echo "───────────────────────────────────────────────────────────────"

total_utils_total=0
total_utils_code=0

if [ -d "evm/src/utils" ]; then
    for file in evm/src/utils/*.sol; do
        if [ -f "$file" ]; then
            name=$(basename "$file")
            read total code < <(count_loc "$file")
            printf "%-40s %9d %10d\n" "$name" "$total" "$code"
            total_utils_total=$((total_utils_total + total))
            total_utils_code=$((total_utils_code + code))
        fi
    done
fi

echo "───────────────────────────────────────────────────────────────"
printf "${YELLOW}%-40s %9d %10d${NC}\n" "TOTAL UTILITIES" "$total_utils_total" "$total_utils_code"

# SDK
if [ -d "sdk/evm" ]; then
    echo -e "\n${BLUE}SDK CONTRACTS${NC}"
    echo "File                                     Total LOC  Code LOC"
    echo "───────────────────────────────────────────────────────────────"

    total_sdk_total=0
    total_sdk_code=0

    for file in sdk/evm/*.sol; do
        if [ -f "$file" ]; then
            name=$(basename "$file")
            read total code < <(count_loc "$file")
            printf "%-40s %9d %10d\n" "$name" "$total" "$code"
            total_sdk_total=$((total_sdk_total + total))
            total_sdk_code=$((total_sdk_code + code))
        fi
    done

    echo "───────────────────────────────────────────────────────────────"
    printf "${YELLOW}%-40s %9d %10d${NC}\n" "TOTAL SDK" "$total_sdk_total" "$total_sdk_code"
fi

# Grand total
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
grand_total_total=$((total_contracts_total + total_libs_total + total_interfaces_total + total_utils_total + total_sdk_total))
grand_total_code=$((total_contracts_code + total_libs_code + total_interfaces_code + total_utils_code + total_sdk_code))
printf "${GREEN}%-40s %9d %10d${NC}\n" "GRAND TOTAL" "$grand_total_total" "$grand_total_code"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"

echo "Note: Code LOC excludes blank lines and single-line comments (//)."
echo "Multi-line comments (/* */) are partially counted."
