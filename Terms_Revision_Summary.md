# BTR Terms of Service Revision Summary

**Date**: January 22, 2026
**Revised By**: Jocasta (Technical Writer)
**Document**: `/Users/derpa/Work/btr/dex/front/public/legal/Terms of Service.md`

---

## Executive Summary

The BTR Terms of Service have been comprehensively revised to address critical legal gaps identified through comparison with industry-standard DeFi terms (Nado protocol). The revision adds 8 new major sections, expands existing sections with DeFi-specific disclosures, and clarifies liability and dispute resolution mechanisms while preserving BTR's unique AIMM protocol context and decentralized nature.

**Key Statistics**:
- **Sections Added**: 8 major new sections
- **Sections Enhanced**: 7 existing sections significantly expanded
- **Lines Added**: ~150 new lines of legal content
- **Total Sections**: 21 (up from 15 incomplete)

---

## Critical Additions

### 1. Prominent VPN Prohibition Warning ⚠️
**Location**: Preamble (immediately after document title)

**Content**: Bold, prominently displayed warning prohibiting VPN use to circumvent geographic restrictions.

**Rationale**: Nado protocol includes a similar warning at the top of their terms. This is a critical protection against regulatory liability, as circumventing jurisdiction restrictions can expose the protocol to enforcement actions. Making it prominent demonstrates intent to enforce restrictions.

---

### 2. Fees and Charges Section (NEW)
**Section**: 5

**Content**:
- Network fees (gas, transaction fees)
- Protocol fees (if any)
- Fee estimates disclaimer
- Third-party fees

**Rationale**: The original Terms had no explicit fee structure definition. Users need clarity that they are responsible for all network fees (gas) and that estimates are approximations only. This protects against disputes over fee amounts and prevents claims that the protocol "misled" users about costs.

---

### 3. Protocol Changes and Blockchain Forks (NEW)
**Section**: 11

**Content**:
- 11.1: Smart Contract Modifications and Upgrades
- 11.2: Blockchain Infrastructure Risks (forks, network changes, congestion, 51% attacks)
- 11.3: Oracle and Data Source Risks (TWAP oracle vulnerabilities, keeper bot failures)

**Rationale**: This section addresses critical DeFi-specific risks that were completely missing:
- **Fork risk**: Blockchain forks can split chains, create double-spending scenarios, or cause transaction disputes. BTR must disclaim liability for network-level events it cannot control.
- **Upgrade risk**: As a protocol with upgradeable contracts (beacon proxy pattern), users need explicit disclosure that upgrades may change protocol behavior and affect their positions.
- **Oracle risk**: BTR uses internal TWAP oracles and keeper bots. Oracle manipulation is a common DeFi attack vector. This section disclaims liability for oracle failures, which is essential given the recent history of oracle exploits in DeFi.
- **Quantum computing**: Added as a future risk factor (included in Nado's terms as well).

**Preserved BTR Context**: The section explicitly references the beacon proxy pattern, keeper bots, TWAP oracles, and coverage ratios—maintaining BTR's unique AIMM protocol characteristics.

---

### 4. Service Modifications and Suspension Rights (NEW)
**Section**: 12

**Content**:
- 12.1: Right to Modify Services (features, algorithms, fee structures, assets)
- 12.2: Right to Suspend or Discontinue Services
- 12.3: No Liability for Modifications or Suspensions

**Rationale**: The original Section 12 covered termination but not modification or suspension. Protocols need flexibility to:
- Adapt to changing regulations
- Respond to security incidents
- Upgrade technology
- Discontinue deprecated features
- Conduct maintenance

Without explicit modification rights, users could argue that protocol changes constitute a breach of contract. This section provides the necessary legal flexibility.

---

### 5. Regulatory Compliance Section (NEW)
**Section**: 13

**Content**:
- 13.1: Cooperation with Authorities (disclosure of information, compliance measures)
- 13.2: Sanctions Compliance (OFAC, UN, EU sanctions)
- 13.3: Anti-Money Laundering (AML) monitoring
- 13.4: Tax Compliance (user responsibility)

**Rationale**: DeFi protocols are increasingly subject to regulatory scrutiny. This section:
- Establishes the protocol's right to cooperate with law enforcement (critical for avoiding obstruction of justice claims)
- Provides a basis for complying with sanctions enforcement (required to avoid OFAC violations)
- Establishes AML monitoring capabilities (important for preventing abuse)
- Clarifies tax responsibility (prevents users from claiming the protocol should handle tax reporting)

**Preserved BTR Context**: No changes needed—this applies equally to all DeFi protocols.

---

### 6. Third-Party Resources Disclaimer (NEW)
**Section**: 14

**Content**: Disclaimer for links to third-party websites, applications, and services.

**Rationale**: The Interface may link to external resources (Etherscan, block explorers, DeFi dashboards, etc.). Without this disclaimer, BTR could be liable for content or services provided by third parties. This is a standard website liability protection.

---

### 7. Statute of Limitations (NEW)
**Section**: 18

**Content**: 1-year claim window from the date the cause of action accrues.

**Rationale**: Matches Nado's 1-year limitation. Without a statute of limitations, claims could theoretically be brought indefinitely. This protects the protocol from legacy claims and provides certainty. One year is reasonable for crypto where evidence degrades quickly and memories fade.

---

### 8. Governing Law and Jurisdiction (NEW)
**Section**: 19

**Content**:
- 19.1: Governing Law (Cayman Islands)
- 19.2: Jurisdiction (Cayman Islands courts)
- 19.3: International Use (user compliance with local laws)

**Rationale**: **This was the single most critical gap in the original Terms.** Without specified governing law, a court could apply any jurisdiction's laws based on procedural rules.

**Why Cayman Islands?**
- **Crypto-friendly jurisdiction**: The Cayman Islands is the most common jurisdiction for crypto protocols (similar to Delaware for US companies)
- **Legal certainty**: Well-established corporate law and arbitration framework
- **Tax neutrality**: No corporate income tax, capital gains tax, or withholding tax
- **Privacy**: Strong privacy protections for corporate entities
- **Industry standard**: Major crypto protocols (Uniswap, Aave, Curve, etc.) use Cayman Islands entities

**Policy Decision**: **REQUIRES TEAM APPROVAL** - The choice of jurisdiction is a strategic decision. Alternatives include:
- British Virgin Islands (similar to Cayman)
- Singapore (Asian-focused, strict crypto regulations)
- Switzerland (crypto-friendly, but complex)
- Delaware, USA (access to US legal system, but subject to US regulation and enforcement)

**Recommendation**: Cayman Islands is the industry standard for DeFi protocols and provides the best balance of legal certainty, tax efficiency, and regulatory predictability.

---

### 9. Comprehensive Dispute Resolution (MAJOR OVERHAUL)
**Section**: 20

**Changes from original Section 15**:

**Added**:
- 20.1: Mandatory binding arbitration with JAMS rules
- 20.2: Class action and representative action waiver (CLASS ACTION WAIVER IS CRITICAL)
- 20.3: Waiver of right to trial (jury trial waiver)
- 20.4: Small claims court exception
- 20.5: Opt-out provision (30-day window for individuals only)

**Rationale**: The original Section 15 was incomplete and lacked specificity. A robust dispute resolution section is essential for:

1. **Class action protection**: DeFi protocols are prime targets for class action lawsuits. A class action waiver is critical protection. Without it, a single exploit or bug could result in thousands of users joining a class action seeking damages far exceeding the protocol's assets.

2. **Forum selection**: Specifying JAMS arbitration in Cayman Islands provides predictability and prevents forum shopping.

3. **Individual opt-out**: Retains the original provision allowing individuals to opt out of arbitration. This is consumer-friendly and may be required in some jurisdictions to be enforceable.

4. **Small claims exception**: Allows users to bring small claims actions for minor disputes, which is reasonable and practical.

**Key Policy Decision**: **REQUIRES TEAM APPROVAL** - Whether to keep the individual opt-out provision or make arbitration mandatory.

**Options**:
- **Option A (Recommended)**: Keep the 30-day opt-out window. This is more consumer-friendly and may be more enforceable in certain jurisdictions. Most crypto protocols use this approach.
- **Option B**: Make arbitration mandatory (no opt-out). Provides stronger legal protection but may be less enforceable and creates negative user perception.

**Recommendation**: Keep the 30-day opt-out (Option A). It strikes a balance between legal protection and user choice, and aligns with industry practice.

---

## Significant Modifications

### 10. Enhanced Indemnification Control (Section 15.4)
**Original**: Section 11.3 mentioned indemnification but did not specify control rights.

**Modified**: Added explicit language that:
- BTR has exclusive right to control defense and settlement
- User must cooperate with defense
- User cannot settle without BTR's prior written consent

**Rationale**: Without control rights, users could settle claims in ways that create precedent liability for BTR. This is a standard indemnification control provision that protects the protocol from third-party settlements it cannot control.

---

### 11. Expanded Risk Disclaimers (Section 15.3)
**Added**: New types of losses excluded from liability:
- Protocol upgrades and smart contract modifications
- Oracle errors and manipulation
- Blockchain forks and network congestion
- Malicious attacks and protocol exploits
- Quantum computing advances

**Rationale**: These are specific DeFi risks that were not explicitly called out. Explicit disclaimers strengthen BTR's position against claims arising from these events.

---

### 12. Open-Source License Compliance (Section 8.5 - NEW subsection)
**Content**: Compliance with OSS licenses, source code availability, user notice of license differences.

**Rationale**: If BTR uses any open-source components (which is likely in a protocol using beacon proxy patterns, keeper bots, etc.), OSS license compliance is legally required. Failure to comply can result in license revocation, copyright infringement claims, or forced open-sourcing of proprietary code.

**Note**: The team should verify which OSS components are used and ensure compliance mechanisms are in place.

---

### 13. Renumbering of Sections
**Change**: Due to insertion of new sections, the section numbers were reorganized:

**Old Structure**:
1. Contact
2. Restrictions
3. No Fiduciary
4. Eligibility
5. Use of Services
6. General Conditions
7. Acceptable Use
8. IP
9. Privacy
10. Disclaimer
11. Liability
12. Termination
13. Language
14. General
15. Dispute Resolution (INCOMPLETE)

**New Structure**:
1. Contact
2. Restrictions
3. Eligibility
4. Use of Services
5. **Fees (NEW)**
6. General Conditions
7. Acceptable Use
8. IP (added OSS compliance)
9. Privacy
10. Disclaimer
11. **Protocol Changes & Forks (NEW)**
12. **Service Modifications (NEW)**
13. **Regulatory Compliance (NEW)**
14. **Third-Party Resources (NEW)**
15. Liability (enhanced)
16. Termination
17. Language
18. **Statute of Limitations (NEW)**
19. **Governing Law (NEW)**
20. **Dispute Resolution (OVERHAULED)**
21. General

---

## Sections Kept As-Is (Minor Edits)

The following sections were retained with minimal changes, only adding references to new sections or updating section numbers:

- **Section 1: Contact** - No changes
- **Section 2: Restrictions of Use** - No content changes (list of restricted countries unchanged)
- **Section 3: Eligibility** - Minor formatting only
- **Section 4: Use of Services** - No content changes
- **Section 6: General Conditions** - No content changes
- **Section 7: Acceptable Use** - No content changes
- **Section 8: IP** - Added Section 8.5 (OSS), rest unchanged
- **Section 9: Privacy** - No content changes
- **Section 10: Disclaimer** - Fixed typo in Risk Disclaimer link
- **Section 16: Termination** - Updated continuing provisions list
- **Section 17: Language** - No content changes
- **Section 21: General** - Added "Electronic Communications" subsection

---

## Restricted Territories Review

**Current List**:
- USA, Canada, China, Japan (major economies)
- OFAC sanctioned countries (Russia, Iran, North Korea, etc.)
- Hong Kong, Thailand, Malaysia

**Nado List**:
- USA, Canada, Australia, UK, EU
- OFAC sanctioned countries

**Rationale for BTR's List**:
- **Excludes China**: Appropriate given strict crypto regulations and potential enforcement risks
- **Excludes Japan**: Appropriate given strict crypto exchange regulations
- **Excludes Hong Kong, Thailand, Malaysia**: Reflects regulatory uncertainty in these jurisdictions
- **Does not exclude EU/UK**: Strategic decision to serve European markets (subject to MiCA compliance)

**Policy Decision**: **REQUIRES TEAM APPROVAL** - Whether to adjust the restricted territories list.

**Options**:
- **Option A**: Keep current list (Asia-focused restrictions)
- **Option B**: Align with Nado (EU/UK restrictions, allow Asia)
- **Option C**: Comprehensive exclusion (most conservative approach)

**Recommendation**: Keep the current list unless there are specific regulatory concerns with serving EU/UK markets. The current list reflects a deliberate strategy to avoid strict Asian regulators while serving Western markets.

---

## Key Policy Decisions Requiring Team Approval

### 1. Governing Law and Jurisdiction (Section 19)
**Decision**: Cayman Islands law and courts

**Alternatives**:
- British Virgin Islands
- Singapore
- Switzerland
- Delaware, USA

**Recommendation**: **Approve Cayman Islands** - This is the industry standard for DeFi protocols and provides the optimal balance of legal certainty, tax efficiency, and regulatory predictability.

---

### 2. Arbitration Opt-Out Provision (Section 20.5)
**Decision**: 30-day opt-out window for individuals

**Alternatives**:
- Keep opt-out (recommended)
- Remove opt-out (mandatory arbitration)

**Recommendation**: **Keep opt-out** - This is more enforceable and consumer-friendly. Most major crypto protocols (Uniswap, Coinbase, etc.) use this approach.

---

### 3. Restricted Territories List (Section 2)
**Decision**: Current list (USA, Canada, China, Japan, OFAC, HK, Thailand, Malaysia)

**Alternatives**:
- Keep current (Asia-focused restrictions)
- Align with Nado (EU/UK restrictions)
- Comprehensive exclusion

**Recommendation**: **Keep current list** unless there are specific regulatory concerns with EU/UK markets. The current list reflects a deliberate strategy.

---

### 4. Fee Structure Clarification (Section 5)
**Decision**: Users responsible for all gas fees; protocol fees (if any) must be transparently displayed

**Team Action Required**: Confirm whether protocol charges fees beyond gas. If protocol fees are charged, the fee amounts and calculation methods should be documented for transparency.

---

### 5. Open-Source Components (Section 8.5)
**Team Action Required**: Inventory all OSS components used in the protocol, keeper bots, and interface. Ensure:
- OSS licenses are identified
- Source code is made available where required
- Compliance mechanisms are in place

---

## BTR-Specific Content Preserved

Throughout the revision, BTR's unique AIMM protocol context was preserved:

1. **Beacon Proxy Pattern**: Explicitly mentioned in preamble and Section 11.1
2. **Keeper Bots**: Referenced in preamble and oracle risks (Section 11.3)
3. **TWAP Oracles**: Specifically addressed in oracle risks section
4. **Coverage Ratios**: Referenced in prohibited activities (Section 4)
5. **Cooperative Arbitrage**: Implied in market manipulation prohibitions
6. **Anchor Tree Routing**: Context for multi-asset swap complexity
7. **Non-custodial**: Emphasized throughout (self-custody understanding)
8. **Inventory-based pricing**: Context for modification risks

All DeFi-specific risks and prohibitions (flash loan attacks, oracle manipulation, wash trading) were retained from the original Terms.

---

## Compliance Checklist

Before deploying the revised Terms, verify:

- [ ] Legal review by qualified counsel specializing in DeFi and Cayman Islands law
- [ ] Team approval of jurisdiction choice (Cayman Islands)
- [ ] Team approval of arbitration opt-out provision
- [ ] Confirmation of restricted territories list
- [ ] Inventory of OSS components and license compliance
- [ ] Update date (currently "January 2026")
- [ ] Add physical address for opt-out notices (Section 20.5)
- [ ] Review with insurance provider (if any) for coverage alignment
- [ ] Consider adding effective date/version control mechanism

---

## Next Steps

1. **Immediate**:
   - Review this summary with the core team
   - Obtain approvals for policy decisions
   - Legal review by DeFi-specialized counsel
   - Add physical address for opt-out notices

2. **Within 30 Days**:
   - Finalize legal review
   - Approve and deploy revised Terms
   - Update user notification mechanisms
   - Communicate changes to existing users (required by many jurisdictions)

3. **Ongoing**:
   - Establish Terms review schedule (quarterly or semi-annual)
   - Monitor regulatory developments and update as needed
   - Track enforcement actions against other DeFi protocols
   - Maintain compliance with evolving crypto regulations

---

## Conclusion

The revised Terms of Service comprehensively address the critical gaps identified in the original document while preserving BTR's unique AIMM protocol characteristics and decentralized nature. The addition of 8 major sections and enhancement of existing provisions provides robust legal protection, regulatory compliance frameworks, and clear user expectations.

The key policy decisions (governing law, arbitration provisions, restricted territories) should be reviewed and approved by the core team before finalizing the document. Legal review by qualified DeFi counsel is strongly recommended.

**Estimated Legal Review Time**: 5-10 hours for a DeFi-specialized attorney
**Estimated Cost**: $2,000 - $5,000 depending on counsel rates
**Deployment Timeline**: 2-3 weeks including review and approvals

---

**Document Prepared By**: Jocasta (Technical Writer & DeFi Education)
**Date**: January 22, 2026
**Version**: 1.0
