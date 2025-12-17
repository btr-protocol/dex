#!/usr/bin/env python3
"""
Generate ERC-7201 compliant storage slots.
Formula: keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
"""

import hashlib

def keccak(data: bytes) -> bytes:
    """Keccak-256 hash function (same as Solidity's keccak256)"""
    from hashlib import sha3_256
    # Python 3.6+ has sha3 support, but we need keccak256 (different padding)
    # Use pycryptodome if available, otherwise use a workaround
    try:
        from Crypto.Hash import keccak as crypto_keccak
        k = crypto_keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
    except ImportError:
        # Fallback: use cast keccak command
        import subprocess
        result = subprocess.run(['cast', 'keccak', data.hex()], capture_output=True, text=True)
        return bytes.fromhex(result.stdout.strip()[2:])

def erc7201_slot(namespace_id: str) -> str:
    """
    Calculate ERC-7201 storage slot for a given namespace ID.

    Formula from EIP-7201:
    keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    """
    # Step 1: keccak256(id) -> uint256
    id_hash = keccak(namespace_id.encode('utf-8'))
    id_uint = int.from_bytes(id_hash, byteorder='big')

    # Step 2: uint256(keccak256(id)) - 1
    id_minus_1 = id_uint - 1

    # Step 3: abi.encode(uint256(...))
    # In ABI encoding, uint256 is just the 32-byte big-endian representation
    encoded = id_minus_1.to_bytes(32, byteorder='big')

    # Step 4: keccak256(abi.encode(...))
    slot_hash = keccak(encoded)
    slot_uint = int.from_bytes(slot_hash, byteorder='big')

    # Step 5: ... & ~bytes32(uint256(0xff))
    # This clears the lowest 8 bits
    mask = ~0xff
    final_slot = slot_uint & mask

    # Convert to hex string
    return '0x' + final_slot.to_bytes(32, byteorder='big').hex()

# Define all storage namespaces
NAMESPACES = [
    ("pool.storage.base.v1", "AIMM_STORAGE_LOCATION", "Base module storage location"),
    ("pool.storage.staking.v1", "STAKING_STORAGE_LOCATION", "Staking module storage location"),
    ("pool.storage.distributor.v1", "DISTRIBUTOR_STORAGE_LOCATION", "Distributor module storage location"),
    ("pool.storage.oracle.v1", "ORACLE_STORAGE_LOCATION", "Oracle module storage location"),
    ("pool.storage.rescue.v1", "RESCUE_STORAGE_LOCATION", "Rescue module storage location"),
]

def main():
    print("// ========== STORAGE LOCATIONS (ERC-7201) ==========")
    print()

    for namespace_id, constant_name, description in NAMESPACES:
        slot = erc7201_slot(namespace_id)
        print(f'/// @notice {description}')
        print(f'/// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("{namespace_id}")) - 1)) & ~bytes32(uint256(0xff))')
        print(f'bytes32 internal constant {constant_name} =')
        print(f'    {slot};')
        print()

if __name__ == '__main__':
    main()
