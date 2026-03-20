### BTR RISK DISCLAIMER
*Last Updated: January 22, 2026*

#### 1. DEFINITION

At BTR ("BTR", "we", "us", "our"), we prioritize risk transparency. This disclaimer applies to all services provided through BTR's decentralized exchange protocol and front-end interfaces (collectively "Services"):

#### 1.1. BTR DEX Protocol
- **AIMM Protocol**: Balanced Automated Market Maker - a multi-asset DEX with hub-and-spoke routing, dynamic fees, and coverage ratio-based active liquidity management
- **Web Interface** ([https://btr.supply](https://btr.supply)): Front-end for interacting with the AIMM protocol
- **Smart Contracts**: Open-source upgradeable smart contracts using Diamond proxy pattern, deployed on Ethereum and compatible EVM chains

#### 1.2. Core Protocol Activities

The BTR protocol enables the following activities:
- **Token swaps**: Trading between supported digital assets
- **Liquidity provision**: Depositing tokens to earn trading fees and incentives
- **Flash loans**: Uncollateralized borrowing for single-transaction use cases (ERC-3156 compliant)
- **Staking**: Locking LP tokens (sLP) or governance tokens (sBTR) to earn rewards and voting rights
- **Governance**: Participating in protocol decisions via BTR token voting

You should carefully assess whether using BTR's services matches your risk tolerance and financial capacity for potential losses.

---

### 2. PROTOCOL RISKS

#### 2.1. Smart Contract Risks

The protocol relies on smart contracts that are **open-source** and available for public inspection on GitHub. While the code undergoes internal testing, **no third-party security audit has been completed**. Undiscovered vulnerabilities could result in partial or total loss of deposited funds.

**Diamond Proxy Architecture**: The protocol uses a Diamond proxy pattern (ERC-2535), which allows modular upgrades through facet replacement. Unlike traditional upgrade patterns, Diamond upgrades enable granular changes to specific functionality. Upgrades require a 3-7 day timelock but introduce centralization risk:
- **Module upgrade control**: Protocol owners can add, replace, or remove Diamond facets
- **Upgrade backdoor**: Even with timelocks, centralized upgrade authority could potentially bypass community consensus
- **Storage collision risks**: Diamond patterns require careful ERC-7201 slot management; collisions could corrupt data

For details on upgradeability and governance processes, see [Protocol Architecture](/specs/PROTOCOL.md).

**Reentrancy Protection**: Critical modules implement ReentrancyGuard patterns, but external calls to other contracts could enable reentrancy attacks if third-party contracts are malicious.

**Open-Source Status**: All smart contracts are open-source and available for third-party security review. Users and security researchers are encouraged to audit the code. However, absence of third-party audit findings does not guarantee absence of vulnerabilities.

#### 2.2. Market and Financial Risks

Digital assets are highly volatile. Token prices can fluctuate dramatically due to market conditions, adoption, speculation, regulatory changes, or technical factors. Trading and providing liquidity can result in losses exceeding your initial deposit. You should only use funds you can afford to lose entirely.

BTR does not provide investment, legal, or tax advice. You are solely responsible for evaluating the suitability of these services for your circumstances and should consult qualified advisors as needed.

#### 2.3. Liquidity Provider Risks

**Coverage Ratio Haircuts**: The protocol tracks coverage ratio (reserves/liabilities) per asset. When coverage falls below 1.0, withdrawals receive proportionally reduced amounts based on the **power-law formula**:

```
haircut (h) = (1 - coverage)^η
```

Where `η` (eta) is a power-law parameter that determines the severity of haircuts. As coverage approaches 0%, haircuts approach 100%, meaning LPs could face **total loss** of their claims. LPs share losses pro-rata without additional penalties. For details, see [Coverage Ratio Documentation](/specs/ALM_AND_COVERAGE.md).

**Undercollateralization Risk**: If an asset's coverage ratio reaches 0% due to depletion, LPs in that pool lose 100% of their deposits. No insurance or backstop exists for undercollateralized pools.

**Liability Time Decay**: Assets with prolonged underwater coverage may undergo linear liability reduction to eliminate bad debt. This socialized loss mechanism gradually reduces LP claim values over time to ensure long-term pool sustainability.

**Index Manipulation**: Donations to liquidity pools increase the pool index disproportionately, effectively diluting existing LPs. While this is intended to reward capital providers, it can be abused.

**Insufficient Liquidity**: Swaps and withdrawals are blocked if reserves fall below `minLiquidity` thresholds, temporarily trapping funds until conditions improve or new deposits arrive.

**Dynamic Fees**: Swap fees adjust based on coverage ratio, volatility, and price divergence. High fees during imbalances may reduce trading volume and LP earnings.

**Impermanent Divergence**: Unlike traditional AMMs, AIMM uses single-sided liquidity (deposit USDC, withdraw USDC). While this eliminates classic impermanent loss, coverage ratio fluctuations can cause similar effects if reserves deplete via swaps.

**Flow Guard Bypass Prevention**: Deposits have a 15-second cooldown before withdrawal can be initiated to prevent Just-In-Time (JIT) manipulation attempts. LPs should understand this delay when planning entry/exit strategies.

#### 2.4. Pricing Mechanics Risks

The AIMM protocol uses sophisticated pricing mechanisms that carry specific risks:

**Extreme Volatility Spikes**: The protocol maintains fast and slow Exponential Moving Averages (EMAs) for volatility metrics. During extreme market events, these EMAs can spike to **10,000%** (100×), causing massive spreads and temporarily making swaps prohibitively expensive. This is an intentional protective measure but can cause temporary illiquidity.

**Spline Manipulation**: Piecewise bonding curves are defined by spline parameters controllable by the protocol owner. If set adversarially, these could create unfavorable pricing profiles (e.g., excessive spreads, asymmetric price impact). Owners are expected to act in protocol interest, but centralization risk exists.

**Decimal Overflow**: Prices are encoded in B64 format which has limits for high-price tokens (e.g., BTC at $50,000+). The protocol mitigates this by using 18-decimal accumulators, but edge cases where tokens appreciate dramatically could cause encoding issues.

**No Automated Circuit Breaker**: Circuit breakers are **manual** and require owner or governance action. There is no automated pause on extreme price divergence. If operators are unavailable during crisis, manual intervention may be delayed.

**Pricing Error Propagation**: Incorrect oracle inputs (TWAP divergence) can lead to incorrect mid-price calculations, causing adverse trade execution for users.

#### 2.5. Oracle Architecture Risks

The protocol uses **internal oracles** based on Time-Weighted Average Price (TWAP) with specific vulnerabilities:

**TWAP Manipulation**: Large swaps can shift the fast and slow EMA windows, distorting price inputs. While this requires significant capital, sophisticated attackers could manipulate oracles to:
- Trigger false circuit breaker freezes
- Manipulate dynamic fee calculations
- Distort volatility metrics

**Oracle Staleness**: If no swaps occur for **7+ days**, fast and slow TWAPs diverge from market prices. During low-liquidity periods, oracles may become stale and outdated:
- Fast TWAP (short window) reflects no new data
- Slow TWAP (long window) lags significantly behind market
- Price-dependent operations use stale data

**Keeper Bot Dependence**: The protocol relies on keeper bots to update oracles and maintain TWAP accuracy. If keeper services go offline:
- Oracles only update when swaps occur
- Stale oracle periods extend beyond 7 days during low activity
- Volatility calculations become unreliable
- Dynamic fees may use incorrect inputs

**B64 Overflow for High-Price Tokens**: High-value tokens (e.g., BTC, ETH at high prices) require careful accumulator decimal handling (18 decimals) to avoid B64 encoding overflow. Configuration errors could cause pricing malfunctions.

**No Oracle Circuit Breaker**: There is no automated mechanism to pause operations when internal TWAPs diverge excessively from external market prices. Manual intervention is required.

**External Oracle Reliance**: If the protocol integrates external oracles (Chainlink, Pyth, etc.) as fallbacks, attacks on those external oracle networks propagate to BTR. The protocol currently relies primarily on internal TWAPs but may use external sources.

For technical details, see [Oracle Architecture](/specs/ORACLE.md).

#### 2.6. Slippage and Execution Risks

Large trades may experience significant price impact due to piecewise bonding curves. Actual execution prices may differ from quoted prices if market conditions change between quote and execution. Front-running or MEV (Maximal Extractable Value) by other users or validators may disadvantage your transactions.

**No Native MEV Protection**: The protocol does not implement Flashbots Protect, FPI (Flashbots Protect Interface), or batch auctions. All transactions are visible in the mempool and vulnerable to:
- Front-running
- Sandwich attacks
- Back-running
- Arbitrage

Users are responsible for setting appropriate slippage tolerances and understanding that execution quality is not guaranteed.

#### 2.7. Staking and Governance Risks

**21-Day Unlock Period**: Staked tokens (sLP, sBTR) have a mandatory 21-day unlock period. During this period:
- Tokens earn no rewards
- Tokens cannot be transferred or sold (soulbound)
- Tokens are locked even if protocol suffers catastrophic failure or exploit

If the protocol fails or is exploited during the 21-day unlock window, staked funds are **not recoverable** until the unlock period expires, after which assets may have zero value.

**BTR Token Minting**: The Treasury contract can mint unlimited BTR tokens. While intended for protocol governance and rewards, this creates **dilution risk**:
- Governance could approve excessive minting
- Large mint events dilute existing BTR holders
- No hard cap on BTR supply is enforced by code

**Soulbound Limitations**: sLP and sBTR tokens are soulbound—they cannot be sold, transferred, or traded. Users must unstake and wait 21 days to access liquidity, creating opportunity costs and trapping funds during emergencies.

**Voting Centralization**: BTR governance uses token-weighted voting. Large BTR holders (whales, Treasury, early adopters) can unilaterally pass proposals, including those that may be detrimental to smaller users. Governance power is proportional to BTR holdings, not user count.

**Unstake Blocking**: If the StakingV1 contract is paused (via circuit breaker or emergency action), users cannot unstake. Funds remain locked indefinitely until the contract is unpaused, which requires owner or governance action.

**Opportunity Cost**: Staking involves locking capital for extended periods. During volatile market conditions, opportunity costs (missed gains from other investments) may exceed staking rewards.

#### 2.8. Flash Loan Risks

Flash loans are uncollateralized and must be repaid within a single transaction. Failure to repay causes the entire transaction to revert, potentially resulting in gas fee losses.

**Oracle Manipulation via Flash Loans**: Sophisticated attackers can combine flash loans with swaps to manipulate internal TWAP oracles:
1. Borrow large amounts via flash loan
2. Execute large swap to distort fast/slow EMA windows
3. Use distorted oracle data to exploit other protocol operations
4. Repay flash loan within same transaction

While this requires deep technical knowledge and capital, the absence of oracle-specific flash loan protection creates vulnerability.

**Liquidity Drain**: Rapid flash loans could drain reserves below `minLiquidity` thresholds, blocking normal swaps and withdrawals for other users. If multiple pools are affected simultaneously, protocol-wide illiquidity could occur.

**Fee Underpricing**: The `flashFeeBps` parameter controls flash loan fees. If set too low by governance, the protocol may lose money on flash loans (net negative after gas costs for keeper operations).

**Flash Loan Attacks**: Borrowers may use flash loans to orchestrate complex attacks involving multiple protocols or steps to drain liquidity. The protocol has no dedicated flash loan mitigation beyond standard reentrancy guards.

#### 2.9. Circuit Breaker Risks

The protocol implements **manual** circuit breakers to halt trading when:
1. **Reserve price floor breach**: Swap price falls below configured minimum
2. **Deviation freeze**: Fast/slow TWAP ratio divergence exceeds thresholds (detects depegs, exploits)

**Manual Trigger Only**: Circuit breakers are **not automated**. They require:
- Owner action via multisig
- Governance proposal and execution
- Keeper bot monitoring and trigger

If operators are unavailable during a crisis, circuit breakers may not trigger in time to prevent losses.

**False Positives**: Circuit breakers may trigger false positives during extreme volatility, temporarily freezing trading even when markets are functioning normally. Frozen assets cannot be swapped until conditions normalize or governance intervenes.

**Extended Freezes**: Once triggered, circuit breakers may remain active for extended periods if governance is slow to respond or if uncertainty about market conditions persists. Users cannot withdraw or swap frozen assets.

#### 2.10. Counterparty and Custody Risks

BTR does not act as a counterparty, broker, or custodian. All transactions occur peer-to-contract. You retain custody of your wallet and keys—lost or compromised keys result in permanent, irreversible loss of funds. Transactions on blockchains are final and irreversible.

---

### 3. BRIDGING AND MULTI-CHAIN RISKS

#### 3.1. Bridge Architecture Risks

BTR supports cross-chain transfers via LayerZero messaging protocol. This introduces additional risks:

**Bridge Failure**: If the LayerZero bridge fails:
- Tokens sent across chains are burned on source chain
- Tokens may never arrive on destination chain
- Recovery requires manual intervention by bridge operators
- No automatic refund mechanism exists

**Bridge operators (relayer, oracle, or owner)** must manually process recovery, which may be delayed or denied depending on circumstances.

**Rate Limit Exhaustion**: Daily rate limits on bridge transfers can block cross-chain transactions. If rate limits are exhausted (e.g., during high-volume events), users must wait for the limit to reset (typically 24 hours) before transferring funds.

**Bridge Upgradeability**: The bridge contract is UUPS upgradeable with a 7-day timelock. Upgrades could theoretically introduce vulnerabilities, backdoors, or malicious behavior. While intended for security improvements, centralized upgrade control creates risk.

**Peer Misconfiguration**: The bridge requires correct peer addresses for each supported chain. If misconfigured:
- Messages are lost (tokens burned, never received)
- Cross-chain functionality fails
- Recovery may be impossible without redeployment

**LayerZero Dependency**: BTR relies on LayerZero's decentralized oracle and relayer network. If LayerZero's infrastructure fails, suffers a 51% attack, or is otherwise compromised, BTR's bridge functionality is impacted.

#### 3.2. Multi-Chain Liquidity Fragmentation

When tokens are bridged across chains, liquidity becomes fragmented:
- Price discrepancies between chains create arbitrage opportunities
- Low liquidity on destination chains increases slippage
- Cross-chain arbitrage may not be profitable due to bridge fees and delays
- Liquidity depth varies significantly per chain

Users should understand that providing liquidity on multiple chains exposes them to risks on each chain independently.

---

### 4. SECURITY AND MALICIOUS ACTOR RISKS

#### 4.1. Protocol Upgrade Risks

The AIMM protocol uses upgradeable smart contracts via Diamond proxy pattern (ERC-2535). Protocol upgrades, modifications, or parameter changes may be executed by governance, contract owners, or keeper bots to:
- Fix bugs or security vulnerabilities
- Add new features or improve protocol functionality
- Respond to changing market conditions or security incidents
- Adjust pricing algorithms, coverage ratios, or other protocol parameters
- Upgrade oracle configurations or circuit breaker settings
- Replace or add Diamond facets

**Diamond Proxy Specific Risks**:
- **Facet replacement**: Individual functions can be upgraded without redeploying entire contract
- **Storage layout changes**: Incorrect facet upgrades can corrupt existing state
- **Facet selection attacks**: Malicious facets could be added if upgrade authority is compromised
- **Hidden backdoors**: Granular upgrades enable subtle changes difficult to detect

**Timelock Protections**: Upgrades require a 3-7 day timelock, providing window for community review. However, during emergencies, governance could accelerate upgrades or use emergency controls.

**Centralized Upgrade Authority**: While intended to be decentralized via governance, current upgrade permissions may vest in multisig owners or DAO contracts. Centralization creates risks of:
- Unilateral upgrades without community approval
- Delayed or rejected necessary upgrades
- Capture by malicious actors

You are solely responsible for reviewing upgrade proposals and their potential impact before participating in governance decisions or continuing to use the protocol.

#### 4.2. Malicious Attack Risks

DeFi protocols face ongoing threats from malicious actors seeking to exploit vulnerabilities. Specific risks include:

**Smart Contract Exploits**: Attackers may discover and exploit undiscovered vulnerabilities in smart contract code, potentially resulting in partial or total loss of protocol funds. Common exploit vectors include:
- Reentrancy attacks
- Integer overflow/underflow
- Logic errors in complex pricing or coverage calculations
- Signature replay attacks

**Oracle Manipulation**: Despite internal oracle protections, sophisticated attackers may manipulate price feeds by:
- Executing large swaps to distort TWAPs
- Flash loan + swap combinations
- Timing attacks during keeper oracle updates
- Exploiting stale oracle periods during low activity

**Flash Loan Attacks**: Borrowers may use flash loans to orchestrate complex attacks involving multiple protocols or steps to drain liquidity, manipulate oracles, or exploit arithmetic relationships.

**MEV Extraction**: Validators or searchers may front-run, sandwich, or otherwise profit from your transactions, reducing your execution quality. The protocol has no native MEV protection.

**Governance Attacks**: Malicious actors may attempt to gain control of governance tokens or voting power to pass proposals detrimental to protocol users, including:
- Excessive token minting (dilution)
- Fee parameter manipulation
- Unauthorized protocol upgrades
- Drain of treasury funds

BTR employs multiple security measures including internal testing, circuit breakers, and monitoring, but no system can be 100% secure. **No third-party security audit has been completed.** You acknowledge these inherent risks.

#### 4.3. Cryptographic and Quantum Computing Risks

The protocol relies on widely-accepted cryptographic standards (ECC, SHA-256, etc.) currently considered secure. However, you acknowledge that:
- Future advances in computing technology, including quantum computing, could potentially compromise current cryptographic standards
- Such advances could theoretically enable private key extraction or transaction forgeries
- The protocol may require upgrades or migrations to quantum-resistant cryptography if such threats materialize

While these risks are currently theoretical and distant, they represent a long-term uncertainty in digital asset security.

---

### 5. OPERATIONAL RISKS

#### 5.1. Frontend and Interface Risks

The web interface at [https://btr.supply](https://btr.supply) is a convenience layer—you can interact with smart contracts directly if the interface is unavailable.

**Frontend Downtime**: If the web interface goes offline due to:
- Server failures
- DDoS attacks
- DNS issues
- Malicious compromise

Users must interact directly with smart contracts using alternative interfaces (e.g., Etherscan, Tenderly, custom dApps) or CLI tools. This requires technical knowledge and increases risk of errors.

**Phishing and Malicious Interfaces**: Always verify URLs and contract addresses. Malicious sites mimicking BTR's interface can:
- Steal private keys
- Redirect transactions to attacker contracts
- Display fake balances and states
- Trick users into approving malicious spenders

**Client-Side Errors**: Browser extensions, wallet issues, or network connectivity problems can cause transaction failures, gas losses, or incorrect state display.

#### 5.2. Keeper Bot Failures

The protocol relies on keeper bots to perform critical maintenance operations:
- Oracle updates (TWAP calculations)
- Fee collection and redistribution
- Liquidity rebalancing
- Coverage ratio monitoring

If keeper services go offline:
- **Oracles become stale**: TWAPs only update when swaps occur
- **Fees uncollected**: Protocol revenue may be lost
- **Manual intervention required**: Protocol operations degrade
- **Extended delays**: If no swaps occur, oracles may diverge from market for weeks

Keeper reliability is critical but not guaranteed. Users should understand that keeper failures degrade protocol functionality without necessarily causing catastrophic loss.

#### 5.3. Oracle Stoppage

If oracles stop updating (due to no swaps + no keepers):
- TWAPs diverge significantly from market prices
- Dynamic fee calculations use stale volatility data
- Circuit breakers may misfire (false positives or missed triggers)
- Liquidity shaping becomes suboptimal

Recovery requires manual oracle reset or governance intervention, which may be delayed.

#### 5.4. Blockchain Congestion

Periods of high network activity (e.g., NFT mints, DeFi events) can cause:
- **Increased gas fees**: Swaps and deposits become uneconomic
- **Failed transactions**: Insufficient gas limits cause reverts and lost fees
- **Delayed confirmations**: Mempool congestion slows execution
- **Slippage degradation**: Long confirmation windows increase price impact

BTR is not responsible for losses incurred due to network congestion. Users should adjust gas prices and slippage tolerances accordingly.

---

### 6. USER ACTION RISKS

#### 6.1. Contract Address Verification

Users must verify they are interacting with genuine BTR contracts:
- Sending tokens to malicious or fake contracts results in **irreversible loss**
- Contract addresses can be found in official documentation and GitHub repositories
- Always cross-reference addresses from multiple trusted sources
- Be wary of unofficial "forks" or clones claiming to be BTR

#### 6.2. Slippage and Price Impact

Large trades suffer significant price impact due to liquidity depth limits:
- Setting slippage tolerance too low = failed transactions
- Setting slippage tolerance too high = accepting unfavorable prices
- Unexpected price movements between quote and execution = unfavorable fills

Users should understand their trade size relative to pool depth and set appropriate slippage tolerances.

#### 6.3. Front-Running and MEV

All transactions are visible in the mempool before confirmation, exposing users to:
- **Front-running**: Bots see your transaction and execute similar transactions ahead of yours
- **Sandwich attacks**: Bots place orders before and after your transaction to profit from price impact
- **Back-running**: Bots execute transactions after yours to profit from state changes
- **Arbitrage**: Bots extract value from price inefficiencies your transaction reveals

The protocol has no MEV protection. Users accept the risk of inferior execution quality.

#### 6.4. Gas Failures

Transactions can fail for various reasons:
- **Insufficient gas limit**: Transaction runs out of gas mid-execution, all work rolled back, gas fee lost
- **Gas price too low**: Transaction stays stuck in mempool, eventually drops or becomes outdated
- **Revert conditions**: Smart contract logic fails (e.g., slippage exceeded), all gas spent is lost
- **Nonce issues**: Transaction ordering issues cause reverts

Users are responsible for setting appropriate gas parameters and understanding that failed transactions result in gas fee losses with no value transferred.

#### 6.5. Approval and Allowance Risks

Users must approve contracts to spend tokens:
- **Infinite approvals**: Approving unlimited spend increases risk if contract is compromised
- **Revocation difficulties**: Some approval patterns are difficult to revoke
- **Multiple approvals**: Users may accidentally approve malicious contracts

Best practice: approve only the amount needed, or use permit-based approvals when available.

---

### 7. THIRD-PARTY AND EXTERNAL RISKS

#### 7.1. Regulatory and Compliance Risks

Digital asset regulations vary significantly by jurisdiction and are rapidly evolving. You are solely responsible for ensuring your use of BTR services complies with all applicable laws and regulations in your jurisdiction. BTR does not provide legal advice. Regulatory actions against digital assets, DeFi protocols, or specific tokens may render the protocol illegal or unusable in your region. Citizenship and geographic restrictions are detailed in [our Terms of Service](/terms-of-service).

#### 7.2. Blockchain Network Risks

The protocol operates on Ethereum and other EVM-compatible blockchains. You acknowledge and accept the following risks associated with blockchain infrastructure:

- **Network Forks**: Hard forks, soft forks, or chain reorganizations may occur on the underlying blockchain networks. Such events may result in transaction disputes, blockchain splits, or loss of funds. BTR has no control over network forks and cannot guarantee how the protocol will behave during or after a fork event.

- **Protocol Rules Changes**: The underlying blockchain networks may change their rules, consensus mechanisms, or fee structures through governance or upgrades. Such changes may impact the usability, cost, or functionality of the Services.

- **Network Congestion**: Periods of high network activity may cause transaction delays, failed transactions, or increased gas fees. BTR is not responsible for losses incurred due to network congestion.

- **Network Outages**: The underlying blockchain networks may experience temporary outages, downtime, or degradation of service. During such periods, you may be unable to interact with the protocol.

- **51% Attacks**: Theoretical attacks on blockchain consensus mechanisms could result in transaction reversals, double-spending, or other security compromises. While rare, you acknowledge this risk.

- **Irreversibility**: Blockchain transactions are irreversible—errors cannot be corrected. BTR cannot reverse or refund any transaction once it has been confirmed on-chain.

#### 7.3. External Oracle Risks (Optional Integrations)

While the protocol primarily relies on internal oracles, external oracle integrations (e.g., Chainlink, Pyth) may be used as fallback price sources. External oracles carry risks including:
- Data feed failures or staleness
- Oracle network attacks or manipulation
- Latency in price updates
- Incorrect data from off-chain sources

For external oracle terms and disclosures:
- Chainlink: https://chain.link/terms
- Pyth Network: https://pyth.network/disclaimer

#### 7.4. Token-Specific Risks

Tokens listed on the protocol may have unique risks:
- **Fee-on-transfer tokens**: May cause reserve/liability tracking discrepancies
- **Rebasing tokens**: Supply changes may affect accounting
- **Upgradeable tokens**: Token contract changes could break integrations
- **Low liquidity tokens**: Higher slippage and potential for manipulation
- **Experimental tokens**: Unproven security, high volatility, potential for total loss
- **Blacklisted tokens**: Contracts may block addresses (including BTR protocol contracts)

The protocol does not endorse or guarantee the safety of any listed token. Users should research token projects before providing liquidity.

---

### 8. USER RESPONSIBILITIES AND ACKNOWLEDGMENT

By using BTR services, you acknowledge and accept:

1. **Full Responsibility**: You bear sole responsibility for all decisions and outcomes related to your use of the protocol. You are solely liable for any losses, whether financial or otherwise.

2. **No Guarantees**: BTR makes no warranties regarding accuracy, reliability, security, or performance of the protocol. Services are provided "as is" and "as available."

3. **Technical Competence**: You possess sufficient technical knowledge to understand blockchain systems, smart contracts, and DeFi risks. You have conducted your own research and evaluation.

4. **No Recourse**: BTR shall not be liable for lost deposits, lost profits, lost opportunities, data inaccuracies, technical failures (client-side, server-side, or blockchain-side), or any consequential damages.

5. **Indemnification**: You agree to indemnify and hold BTR and its contributors harmless from any claims, damages, or liabilities arising from your use of the services.

6. **Information Only**: Documentation, specifications, and materials provided by BTR are for informational purposes only and do not constitute financial, legal, or technical advice.

7. **Independent Verification**: You should always conduct your own research, review all specifications, verify smart contract code, and consult with qualified professionals before using the services.

8. **Audit Status**: You acknowledge that no third-party security audit has been completed. Smart contracts are open-source and available for public review, but absence of third-party audit findings does not guarantee absence of vulnerabilities.

For full terms and conditions, see [our Terms of Service](/terms-of-service).
