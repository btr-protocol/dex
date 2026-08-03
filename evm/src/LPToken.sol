// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Err} from "@btr-shared/Errors.sol";
import {IPool} from "./interfaces/IPool.sol";
import {Constants as C} from "./libraries/Constants.sol";

/// @notice Pool-facing surface of a leg receipt. `mint`/`burn` are callable by the owning pool only.
interface ILPToken {
  function mint(address to, uint256 amount) external;
  function burn(address from, uint256 amount) external;
  function totalSupply() external view returns (uint256);
  function balanceOf(address account) external view returns (uint256);
}

/// @title LPToken - per-leg ERC-20 receipt, the pool's SOLE share ledger for that leg
/// @notice One clone per (pool, leg). Deployed by `PoolAdminWrite.initAsset` as an EIP-1167
///         clone-with-immutable-args, so pool / asset / decimals / symbol / name cost no storage.
/// @dev Value per share is `balance * assets[asset].liquidityIndex / 1e18`, NOT a fixed rate:
///      `decimals()` mirrors the underlying only because `LIQUIDITY_INDEX_INIT == 1e18` makes the
///      first share 1:1 with the first underlying unit. The index moves with fees, donations, yield,
///      decay and write-downs, and `PoolAux.hookWriteDown` can drive it to 0 (terminal: every share
///      is then worth exactly 0 and the leg is unrecoverable). Price off `Pool.previewWithdraw`,
///      never off a decimals-derived assumption.
/// @dev The pool never calls back into itself through this token: `mint`, `burn` and the transfer
///      lock only STATICCALL `Pool.flowCooldownSeconds()`, so no path re-enters `nonReentrant` or
///      trips `requireNoFlash` and a transfer can never fail for a reason outside this contract.
contract LPToken is ERC20 {
  /// @dev One slot per holder. `frozen` is the quantity that may not leave before `stamp + cooldown`.
  struct Lock {
    uint32 stamp;
    uint224 frozen;
  }

  /// @notice Anti-JIT frozen-amount lock. Public so an integrator can size an exit without guessing.
  mapping(address => Lock) public locks;

  // Immutable args, appended after the 45-byte EIP-1167 runtime prefix. Read with `extcodecopy`
  // into scratch rather than `LibClone.argsOnClone`, which allocates memory on every hot read.
  //   45 pool(20) | 65 asset(20) | 85 decimals(1) | 86 symbol(bytes32) | 118 name(bytes32)
  uint256 private constant ARG_POOL = 45;
  uint256 private constant ARG_ASSET = 65;
  uint256 private constant ARG_DECIMALS = 85;
  uint256 private constant ARG_SYMBOL = 86;
  uint256 private constant ARG_NAME = 118;

  function _arg(uint256 offset) private view returns (bytes32 w) {
    assembly ("memory-safe") {
      extcodecopy(address(), 0x00, offset, 0x20)
      w := mload(0x00)
    }
  }

  function _pool() internal view returns (address) {
    return address(uint160(uint256(_arg(ARG_POOL) >> 96)));
  }

  /// @notice The leg this receipt is issued against, post-`PoolIO.wrap` (the native leg is wnative).
  function asset() external view returns (address) {
    return address(uint160(uint256(_arg(ARG_ASSET) >> 96)));
  }

  /// @notice The owning pool. Sole mint and burn authority; pinned in the clone's code, not storage.
  /// @dev Pools are beacon proxies, so this pins the ADDRESS, not the bytecode that may mint. Real
  ///      mint authority is whatever the beacon points at, behind the factory's timelocked upgrade.
  function pool() external view returns (address) {
    return _pool();
  }

  function decimals() public view override returns (uint8) {
    return uint8(uint256(_arg(ARG_DECIMALS) >> 248));
  }

  function symbol() public view override returns (string memory) {
    return _str(ARG_SYMBOL);
  }

  function name() public view override returns (string memory) {
    return _str(ARG_NAME);
  }

  function _str(uint256 offset) private view returns (string memory) {
    bytes32 w = _arg(offset);
    uint256 n;
    while (n < 32 && w[n] != 0) ++n;
    bytes memory b = new bytes(n);
    for (uint256 i; i < n; ++i) {
      b[i] = w[i];
    }
    return string(b);
  }

  /// @dev Every leg receipt would otherwise ship an unrevocable infinite Permit2 allowance, and
  ///      `approve(PERMIT2, x)` for any finite x would revert. Permit2 routing is not a product
  ///      decision here.
  function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
    return false;
  }

  /// @notice Mint `amount` shares to `to` and (re)arm the anti-JIT lock over the minted quantity.
  /// @dev NEVER add a mint-to-arbitrary-recipient path (`depositFor(to)`): the lock is a single
  ///      parcel that this refreshes, so a third party able to mint to a victim could dust-mint once
  ///      per window and hold the victim's whole recent balance frozen indefinitely. Stamping
  ///      `msg.sender` instead would collapse the invariant. Only same-address minting is safe.
  function mint(address to, uint256 amount) external {
    if (msg.sender != _pool()) revert Err.NotAuth();
    Lock storage l = locks[to];
    uint256 cd = _cooldown();
    uint256 frozen = block.timestamp >= uint256(l.stamp) + cd ? amount : uint256(l.frozen) + amount;
    if (frozen > type(uint224).max) revert Err.ExcessiveAmount(frozen, type(uint224).max);
    l.stamp = uint32(block.timestamp);
    l.frozen = uint224(frozen);
    _mint(to, amount);
  }

  /// @notice Burn `amount` shares from `from`. Reverts internally on insufficiency, so the pool must
  ///         never read `balanceOf` first.
  function burn(address from, uint256 amount) external {
    if (msg.sender != _pool()) revert Err.NotAuth();
    _burn(from, amount);
  }

  /// @dev Single source of truth: the pool's own `flowCooldownSeconds`. A per-token copy plus an
  ///      admin fan-out would be a second place to keep in sync, and the cap at
  ///      `MAX_FLOW_COOLDOWN` makes the read skippable for any lock older than that.
  function _cooldown() private view returns (uint256) {
    return IPool(_pool()).flowCooldownSeconds();
  }

  /// @dev Anti-JIT invariant: no share may leave `from` within `cooldown` of its own mint. Shares
  ///      are fungible, so bounding outflow by `balance - frozen` is exactly that statement, and it
  ///      freezes the minted AMOUNT rather than the account: a dust deposit routed through an
  ///      ERC-4626 wrapper locks the dust, not the wrapper's whole pooled balance.
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal view override {
    // Solady calls this on `_mint` with `from == 0`; `balanceOf(0) - amount` would underflow and
    // every mint would revert. It must NOT skip on `to == 0`: burn is the redeem path and is
    // exactly what the lock gates.
    if (from == address(0)) return;
    // address(0) holds the leg's unburnable dead-share floor, not a burn sink. A user transfer
    // there would raise that floor with LP money, permanently, and be indistinguishable on chain
    // from the protocol seed. Burning is reachable through the pool's withdraw paths only.
    if (to == address(0) && msg.sender != _pool()) revert Err.ZeroAddr();
    Lock storage l = locks[from];
    uint256 frozen = l.frozen;
    if (frozen == 0) return;
    uint256 stamp = l.stamp;
    // `setFlowCooldown` is capped at MAX_FLOW_COOLDOWN, so any older lock is unconditionally
    // clear and the pool read is skipped.
    if (block.timestamp >= stamp + C.MAX_FLOW_COOLDOWN) return;
    uint256 cd = _cooldown();
    if (block.timestamp >= stamp + cd) return;
    if (balanceOf(from) < amount + frozen) {
      revert Err.CooldownActive(uint32(stamp + cd - block.timestamp));
    }
  }
}
