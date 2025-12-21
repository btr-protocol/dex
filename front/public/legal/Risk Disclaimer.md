### BTR RISK DISCLAIMER
*Last Updated: January 2025*

#### 1. DEFINITION

At BTR ("BTR", "we", "us", "our"), we prioritize risk transparency. This disclaimer applies to all services provided through BTR's decentralized exchange protocol and front-end interfaces (collectively "Services"):

#### 1.1. BTR DEX Protocol
- **AIMM Protocol**: Balanced Automated Market Maker - a multi-asset DEX with hub-and-spoke routing, dynamic fees, and coverage ratio-based active liquidity management
- **Web Interface** ([https://btr.supply](https://btr.supply)): Front-end for interacting with the AIMM protocol
- **Smart Contracts**: Immutable and upgradeable smart contracts deployed on Ethereum and compatible EVM chains

#### 1.2. Core Protocol Activities

The BTR protocol enables the following activities:
- **Token swaps**: Trading between supported digital assets
- **Liquidity provision**: Depositing tokens to earn trading fees and incentives
- **Flash loans**: Uncollateralized borrowing for single-transaction use cases (ERC-3156 compliant)
- **Staking**: Locking LP tokens (sLP) or governance tokens (sBTR) to earn rewards and voting rights
- **Governance**: Participating in protocol decisions via BTR token voting

You should carefully assess whether using BTR's services matches your risk tolerance and financial capacity for potential losses.

### 2. PROTOCOL RISKS

#### 2.1. Smart Contract Risks
The protocol relies on smart contracts that, while audited, may contain undiscovered vulnerabilities. Bugs or exploits could result in partial or total loss of deposited funds. Smart contracts are upgradeable via beacon proxy pattern—upgrades may introduce new risks or bugs.

#### 2.2. Market and Financial Risks
Digital assets are highly volatile. Token prices can fluctuate dramatically due to market conditions, adoption, speculation, regulatory changes, or technical factors. Trading and providing liquidity can result in losses exceeding your initial deposit. You should only use funds you can afford to lose entirely.

BTR does not provide investment, legal, or tax advice. You are solely responsible for evaluating the suitability of these services for your circumstances and should consult qualified advisors as needed.

#### 2.3. Liquidity Provider Risks

**Coverage Ratio Haircuts**: The protocol tracks coverage ratio (reserves/liabilities) per asset. When coverage falls below 1.0, withdrawals receive proportionally reduced amounts reflecting available reserves. LPs share losses pro-rata without additional penalties. For details, see [Coverage Ratio Documentation](/specs/ALM_AND_COVERAGE.md).

**Liability Time Decay**: Assets with prolonged underwater coverage may undergo gradual liability reduction to eliminate bad debt. This socialized loss mechanism ensures long-term pool sustainability but may reduce LP claim values over time.

**Dynamic Fees**: Swap fees adjust based on coverage ratio, volatility, and price divergence. High fees during imbalances may reduce trading volume and LP earnings.

**Impermanent Divergence**: Unlike traditional AMMs, AIMM uses single-sided liquidity (deposit USDC, withdraw USDC). While this eliminates classic impermanent loss, coverage ratio fluctuations can cause similar effects if reserves deplete via swaps.

#### 2.4. Slippage and Execution Risks
Large trades may experience significant price impact due to piecewise bonding curves. Actual execution prices may differ from quoted prices if market conditions change between quote and execution. Front-running or MEV (Maximal Extractable Value) by other users or validators may disadvantage your transactions.

#### 2.5. Staking and Governance Risks
Staked tokens (sLP, sBTR) have a 21-day unlock period (parametric cooldown). During this period, tokens earn no rewards and cannot be transferred. Staking involves locking capital—opportunity cost may exceed earned rewards. Governance decisions may affect protocol parameters unfavorably.

#### 2.6. Oracle and Pricing Risks
The protocol uses **internal oracles** (dual EMA TWAPs) for price discovery, optionally supplemented by external oracles. While oracle data is not used directly for swap pricing (eliminating classic oracle manipulation risks), it influences:
- **Dynamic liquidity shaping**: Breadth of piecewise bonding curves adjusts based on volatility metrics
- **Fee calculation**: Tri-factor fee model uses oracle divergence to detect unusual market conditions
- **Circuit breakers**: Automated freezes trigger when internal price TWAPs deviate beyond thresholds

Oracle failures, manipulation, or staleness could cause incorrect fee calculations, suboptimal liquidity distribution, or false circuit breaker triggers. For details, see [Oracle Architecture](/specs/ORACLE.md) and [Circuit Breakers](/specs/CIRCUIT_BREAKERS.md).

#### 2.7. Circuit Breaker Risks
The protocol implements automated circuit breakers to halt trading when:
1. **Reserve price floor breach**: Swap price falls below configured minimum
2. **Deviation freeze**: Fast/slow TWAP ratio divergence exceeds thresholds (detects depegs, exploits)

While circuit breakers protect against catastrophic losses, they may trigger false positives during extreme volatility, temporarily freezing trading even when markets are functioning normally. Frozen assets cannot be swapped until conditions normalize or governance intervenes.

#### 2.8. Flash Loan Risks
Flash loans are uncollateralized and must be repaid within a single transaction. Failure to repay causes the entire transaction to revert, potentially resulting in gas fee losses. Flash loans may be exploited by sophisticated attackers to manipulate markets or drain protocol value.

#### 2.9. Counterparty and Custody Risks
BTR does not act as a counterparty, broker, or custodian. All transactions occur peer-to-contract. You retain custody of your wallet and keys—lost or compromised keys result in permanent, irreversible loss of funds. Transactions on blockchains are final and irreversible.

### 3. THIRD-PARTY AND EXTERNAL RISKS

#### 3.1. Regulatory and Compliance Risks
Digital asset regulations vary significantly by jurisdiction and are rapidly evolving. You are solely responsible for ensuring your use of BTR services complies with all applicable laws and regulations in your jurisdiction. BTR does not provide legal advice. Regulatory actions against digital assets, DeFi protocols, or specific tokens may render the protocol illegal or unusable in your region. Citizenship and geographic restrictions are detailed in [our Terms of Service](/terms-of-service).

#### 3.2. Blockchain Network Risks
The protocol operates on Ethereum and other EVM-compatible blockchains. Network congestion, high gas fees, consensus failures, forks, or attacks on underlying blockchains may disrupt access or functionality. Blockchain transactions are irreversible—errors cannot be corrected.

#### 3.3. External Oracle Risks (Optional Integrations)
While the protocol primarily relies on internal oracles, external oracle integrations (e.g., Chainlink, Pyth) may be used as fallback price sources. External oracles carry risks including:
- Data feed failures or staleness
- Oracle network attacks or manipulation
- Latency in price updates
- Incorrect data from off-chain sources

For external oracle terms and disclosures:
- Chainlink: https://chain.link/terms
- Pyth Network: https://pyth.network/disclaimer

#### 3.4. Front-End and Interface Risks
The web interface at [https://btr.supply](https://btr.supply) is a convenience layer—you can interact with smart contracts directly if the interface is unavailable. Front-end outages, DNS hijacking, phishing sites, or malicious interfaces may prevent access or cause loss of funds. Always verify URLs and contract addresses.

#### 3.5. Token-Specific Risks
Tokens listed on the protocol may have unique risks:
- **Fee-on-transfer tokens**: May cause reserve/liability tracking discrepancies
- **Rebasing tokens**: Supply changes may affect accounting
- **Upgradeable tokens**: Token contract changes could break integrations
- **Low liquidity tokens**: Higher slippage and potential for manipulation
- **Experimental tokens**: Unproven security, high volatility, potential for total loss

The protocol does not endorse or guarantee the safety of any listed token.

### 4. USER RESPONSIBILITIES AND ACKNOWLEDGMENT

By using BTR services, you acknowledge and accept:

1. **Full Responsibility**: You bear sole responsibility for all decisions and outcomes related to your use of the protocol. You are solely liable for any losses, whether financial or otherwise.

2. **No Guarantees**: BTR makes no warranties regarding accuracy, reliability, security, or performance of the protocol. Services are provided "as is" and "as available."

3. **Technical Competence**: You possess sufficient technical knowledge to understand blockchain systems, smart contracts, and DeFi risks. You have conducted your own research and evaluation.

4. **No Recourse**: BTR shall not be liable for lost deposits, lost profits, lost opportunities, data inaccuracies, technical failures (client-side, server-side, or blockchain-side), or any consequential damages.

5. **Indemnification**: You agree to hold BTR and its contributors harmless from any claims, damages, or liabilities arising from your use of the services.

6. **Information Only**: Documentation, specifications, and materials provided by BTR are for informational purposes only and do not constitute financial, legal, or technical advice.

7. **Independent Verification**: You should always conduct your own research, review all specifications, and verify smart contract code before using the services.

For full terms and conditions, see [our Terms of Service](/terms-of-service).
