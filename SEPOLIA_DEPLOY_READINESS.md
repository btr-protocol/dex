# SEPOLIA FULL-STACK DEPLOY READINESS (owner return checklist)

Target: Ethereum Sepolia (chainId 11155111), single testnet (supersedes Chapel/97).
State as of 2026-07-22: ORACLE STACK HELD (gate fail: no funded key), pool/AMM stack NOT deployed (by design; v4 density params regenerating).

## 0. Current state

| Item | State |
|---|---|
| `evm/script/SepoliaOracleDeploy.s.sol` | READY + security-clean + sim-clean (48 txs, 29.9M gas), STAGED |
| `evm/foundry.toml` | `sepolia` rpc alias + `[etherscan]` sepolia block, STAGED |
| `../keepers/oracle.sepolia.toml` | READY (23 feeds idx 0..22, 2-of-3 signers, theta 0.25/5bp, hb 1800/300s), STAGED, feed_id + oracle addr = zero placeholders until deploy |
| Deployer `0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe` | 0 ETH on Sepolia. BLOCKER |
| Relay `0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` | 0 ETH on Sepolia. BLOCKER |
| `evm/.env.sepolia`, `../keepers/.env.sepolia` | MISSING (chapel twins exist). BLOCKER |
| `ETHERSCAN_API_KEY` | unset (needed for `--verify`, else drop flag) |
| v4 density params (regime/W/dispersion/minDisp) | REGENERATING. Blocks curve presets + seal, nothing else |
| `deployments/11155111.deploy.json` | intentionally absent (re-run guard disarmed) |

## 1. Oracle stack broadcast runbook (run FIRST, blocks everything else)

Order matters; money-path.

1. Fund on Sepolia (faucet): deployer >= 0.3 ETH (sim est. 0.067 @ 2.2 gwei; base fee spikes 20-100 gwei), relay >= 0.2 ETH (batchPushSigned cadence).
2. Create `evm/.env.sepolia` + `../keepers/.env.sepolia` (gitignored, values never in git/logs). Required var NAMES:
   - deploy: `DEPLOYER_PK`; optional `TREASURY`, `GUARDIAN` (second key, gets AC guardian in-broadcast), `ETHERSCAN_API_KEY`, `REDEPLOY`, `DEPLOY_OUT`
   - seeds (1e18 units, from live NXR <= 5 min pre-broadcast): `ORACLE_SEED_ETH_1E18`, `ORACLE_SEED_BTC_1E18`, `ORACLE_SEED_BNB_1E18`, `ORACLE_SEED_XAUT_1E18`, `ORACLE_SEED_PAXG_1E18`, `ORACLE_SEED_syrupUSDC_1E18` (REQUIRED); `ORACLE_SEED_<SYMBOL>_1E18` for any stable > ~25bp off peg (clamp [0.98, 1.02])
   - keeper: `KEEPER_PRIVATE_KEY`, `NXR_API_URL`, `NXR_API_KEY`, optional `ORACLE_RPC_URL`
   Stale seed = stranded feed (first push must land inside dt=0 band: 50bp stable / 100bp volatile; no removeFeed, recovery = updateFeed widen + push-walk).
3. Broadcast (ONE command):
   ```sh
   cd ~/Work/btr/dex/evm && set -a && source .env.sepolia && set +a && \
   forge script script/SepoliaOracleDeploy.s.sol:SepoliaOracleDeploy \
     --sig "deployOracle()" --rpc-url sepolia --broadcast --slow --verify
   ```
   (`--slow`: ~48 sequential txs on public RPC. No `ETHERSCAN_API_KEY`: drop `--verify`.)
4. Verify on-chain: oracle has code, `getSigners()` == canonical 2-of-3, feed count == 23, sample `getFeed` fresh.
5. Fill `../keepers/oracle.sepolia.toml` from `deployments/11155111.deploy.json`: `oracle` <- `"oracle"`, each `feed_id` <- `"feed_<SYMBOL>"`. Zero placeholders fail config validation, cannot arm half-filled.
6. Start keeper IMMEDIATELY (same session; parked seeded-unpushed stack strands volatile feeds after ~1% drift):
   ```sh
   cd ~/Work/btr/keepers && set -a && source .env.sepolia && set +a && \
   cargo run --release -- oracle --config oracle.sepolia.toml --once && \
   KEEPER_EXECUTE=1 cargo run --release -- oracle --config oracle.sepolia.toml --execute
   ```
   Double gate: LIVE needs both `--execute` and `KEEPER_EXECUTE=1`.
7. If `GUARDIAN` was unset: `AccessControl.setGuardian(<second key>, true)` BEFORE pool deploy (independent fast-freeze must not depend on the single deployer EOA).

## 2. Pool/AMM stack: what it needs (contract chain)

Reference: `evm/script/Deploy.s.sol:56-92` (core chain) + `evm/script/TestnetDeploy.s.sol:87-160,385-427` (testnet sequence). All consume the SAME AC + tokens + oracle persisted in `deployments/11155111.deploy.json` (SoT; feed_id = keccak(asset, USDC) binds token addresses forever; a fresh AC or fresh tokens = orphaned oracle).

Deploy order:
1. `Admin(ac)`
2. `Flash()`
3. `PoolAux(ac, admin, flash)`
4. `Pool` impl `(ac, admin, flash, poolAux)`
5. `PoolFactory(poolImpl, deployer, ac)`
6. `createPool` x2 (EIP-1167 clones): stable core (17 assets, USDC base) + volatile core (6 assets)
7. `admin.setCurve(pool, 1, ...)` generic default preset MUST exist pre-seal, before first addAsset (`TestnetDeploy.s.sol:402-404`); then the full preset catalogue (9 regimes x wall ladder W)
8. `admin.addAsset` x23 (oracle cfg + ref oracle cfg + preset id + minFee + decimals + caps)
9. `admin.setAssetParams` / `setRiskFences` per asset (RISK_PARAMS_TESTNET.md section 3/4 tables)
10. `admin.sealBootstrap(pool)` x2 (LAST; post-seal curve changes restricted to the requestUpdateProfile path)
11. Seed liquidity: `pool.deposit(tok, amt)` per asset (`SEED_USDC` default 2,000,000e18 per pool) + faucet fund
12. Wire keeper -> pools: fill `pools = []` + per-feed `token =` in `oracle.sepolia.toml`; restart keeper. H-2 startup gate enforces every pool x feed satisfies `minFeePbps >= 2*theta`

## 3. READY NOW vs BLOCKED on v4 density

v4 density work regenerates: regime selection, wall tier W, dispersion (dispRef), minDisp. Density = curve shaping only. Theta/deviation/heartbeat/minFee policy is DECIDED and independent.

READY NOW (can execute the moment oracle is live + keys funded):
- Oracle stack broadcast + keeper (section 1, zero density dependency)
- Core contract deploys: Admin, Flash, PoolAux, Pool impl, PoolFactory (steps 1-5)
- `createPool` x2 (step 6)
- addAsset SKELETON: token set (23), decimals, oracle wiring, minFee = 2*theta (stable 0.5bp = 50 PBPS, volatile 10bp = 1000 PBPS), oracle-side maxDeviation floors (50/100bp), refBand 300 for volatiles
- setRiskFences: kappa / depthAmp / haircut / refBand columns of RISK_PARAMS_TESTNET.md (held values, not density-derived)
- Seed sizing (SEED_USDC), faucet, keeper pools-wiring plan

BLOCKED ON V4 (do NOT execute until params land):
- setCurve preset catalogue values: regime + W + dispRef per preset (step 7 beyond the generic default)
- Per-asset preset assignment inside addAsset / requestUpdateProfile
- minDisp / maxDisp dispersion bands (setAssetParams)
- `sealBootstrap` (hard gate: RISK_PARAMS_TESTNET.md mandates sim verification of the new param map BEFORE seal; post-seal changes are constrained)
- Therefore also: seed liquidity + swap-enable + keeper pool-wiring (ordered after seal)

Practical split: steps 1-6 CAN be broadcast ahead of the v4 drop to save time, but steps 7-12 form one coherent session with the sim verify; recommended to run 1-12 in one sitting once v4 lands (avoids a half-listed pool sitting on Sepolia).

## 4. Gaps requiring owner decision (pre-pool-broadcast)

1. NO `SepoliaPoolDeploy.s.sol` yet. `TestnetDeploy.s.sol` is Chapel-shaped: deploys its OWN oracle + tokens, BSC asset set (BTCB/WBNB/CAKE), single ref-oracle env wiring. Port required: consume `deployments/11155111.deploy.json` (ac/oracle/token addrs), 23-asset Sepolia set, 2 pools. Blocks nothing today; ~1 focused session, do it while v4 regenerates.
2. `REF_ORACLE` on Sepolia: volatile listing hard-requires an INDEPENDENT reference oracle (`TestnetDeploy.s.sol:114-121` + `_requireVolatileRefFeeds`; refBand=300 configs unexecutable without it). Chainlink Sepolia has ETH/USD + BTC/USD; BNB/XAUT/PAXG refs do not exist there. Options: (a) second ExternalOracle instance as ref (script only requires refOracle != oracle), (b) Chainlink for ETH/BTC + exempt/alt-ref the rest. OWNER CALL.
3. `XAUT_REF_ORACLE` + `XAUT_REF_FEED_ID` (must equal keccak(XAUT, USDC)): depends on choice in (2).
4. Guardian key: which address; wire via `GUARDIAN` env in the oracle broadcast (preferred) or setGuardian before pools.
5. Pre-mainnet only (not a Sepolia gate): keeper-side min push gap (~36s/feed) or volatile theta 5 -> 7bp; dedicated RPC for the relay path. Documented in `oracle.sepolia.toml`.
6. Additional deployer gas for pool stack: budget >= 0.5 ETH on top of the oracle 0.3 (2 pools + 23 listings + presets + seeds; rough, unbenchmarked).

## 5. Ordered master runbook (owner, ~12h return)

1. [READY] Faucet-fund deployer (>= 0.8 ETH total) + relay (>= 0.2 ETH)
2. [READY] Create both `.env.sepolia` files (var names in section 1.2)
3. [READY] Broadcast oracle stack (section 1.3) + verify + fill toml + start keeper (1.4-1.6)
4. [READY] Guardian wiring (1.7) if not done in-broadcast
5. [OWNER] Decide ref-oracle strategy (section 4.2-4.3)
6. [READY] Port `SepoliaPoolDeploy.s.sol` from TestnetDeploy (section 4.1); dry-run against fork
7. [WAIT] v4 density params land -> fill preset catalogue + per-asset map + minDisp/maxDisp
8. [BLOCKED-V4] Sim-verify new param map (RISK_PARAMS_TESTNET.md gate)
9. [BLOCKED-V4] Broadcast pool stack: core chain -> createPool x2 -> setCurve presets -> addAsset x23 -> setAssetParams/setRiskFences -> sealBootstrap
10. [BLOCKED-V4] Seed liquidity (SEED_USDC per pool) + faucet fund
11. [BLOCKED-V4] Wire keeper -> pools (pools=[] + token= per feed, H-2 minFee >= 2*theta gate) + keeper restart
12. [READY] Post-deploy: on-chain reads (feed freshness, pool mid vs NXR), monitor relay revert rate (30s lag ~ 2.5 Sepolia blocks)
