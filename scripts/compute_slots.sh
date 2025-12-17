#!/bin/bash

compute_slot() {
    local namespace="$1"
    echo "=== Computing slot for: $namespace ==="
    
    # Step 1: keccak256(namespace)
    local hash1=$(cast keccak "$namespace")
    echo "keccak256(\"$namespace\") = $hash1"
    
    # Step 2: Convert to uint256, subtract 1
    local num=$(cast to-dec "$hash1")
    local minus_one=$(echo "$num - 1" | bc)
    local hex_minus_one=$(printf "0x%064x" $minus_one)
    echo "minus 1 = $hex_minus_one"
    
    # Step 3: abi.encode(uint256)
    local encoded=$(cast abi-encode "f(uint256)" "$minus_one")
    echo "abi.encode = $encoded"
    
    # Step 4: keccak256(abi.encode)
    local hash2=$(cast keccak "$encoded")
    echo "keccak256(abi.encode) = $hash2"
    
    # Step 5: Mask off last byte
    local result=$(cast --to-hex "$(cast --to-dec "$hash2") & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00")
    echo "Final (masked) = $result"
    echo ""
}

compute_slot "aimm.storage.v1"
compute_slot "darkpool.storage.v1"
