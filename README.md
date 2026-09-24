# Nexum - Stablecoin-Powered Cross-Border Payments on Arc

Nexum is a global foreign-exchange and cross-border payments platform built on the Arc blockchain, settled entirely in USDC. It lets individuals and businesses anywhere in the world move money across borders with real local-currency amounts on both ends, without the delays, opacity, and cost of traditional banking rails. Every transaction settles on-chain, transparently, and is traceable on the Arc explorer.

---

## Vision

A world where sending money across a border is as fast, cheap, and certain as sending a message - where the currency you hold and the currency someone else needs are never a barrier, and where no one has to trust a middleman to hold their funds along the way.

## Mission

To give people and businesses in every market direct access to fair, transparent, stablecoin-settled payments and FX. Nexum replaces slow correspondent banking and siloed regional rails with an open USDC settlement layer, peer-to-peer liquidity at market rates, and on-chain escrow that protects both sides of every trade - so value moves in seconds, at real rates, with a verifiable record.

---

## What Problem Does Nexum Solve?

Cross-border payments are slow, expensive, and opaque almost everywhere. Banks charge high fees, take days to settle, and demand heavy documentation. Regional payment rails are fast but trapped within borders. Nexum bridges that gap by using USDC as a neutral settlement currency between any two local currencies, with peer-to-peer trading at market rates and built-in escrow that protects both parties. Funds are non-custodial, held in the user's own Circle wallet, and every step is recorded on-chain.

---

## The Key Protocols

### USDC Settlement Layer
Every payment, trade, and transfer settles in USDC. Pricing spans 160+ global currencies drawn from a live rate feed with automatic failover and database caching, so a feed outage never blocks activity. A currency appears only when its live rate is available, so there is no stale hardcoded list. USDC is the neutral unit that lets any local currency reach any other.

### Peer-to-Peer Marketplace with On-Chain Escrow
Users trade USDC directly with each other at agreed rates. A maker locks USDC into the escrow smart contract; a taker accepts on-chain, sends the local-currency payment off-chain (bank transfer or mobile money), and confirms with proof. On confirmation the contract releases the USDC to the taker. If a taker accepts but never pays within the window, the offer returns to the marketplace automatically for someone else to take - funds stay safely escrowed the whole time. A built-in trade chat lets both sides communicate and is cleared once the trade completes.

### Cross-Chain Bridge (Circle CCTP)
USDC moves between Arc and every supported chain through Circle's Cross-Chain Transfer Protocol - a burn-and-mint bridge, not a wrapped-token bridge. USDC is burned on the source chain and native USDC is minted on the destination, with no third-party custody and no synthetic asset. Because a burn is irreversible until its mint completes, every bridge is recorded before anything is signed and each stage is persisted as it happens; an interrupted transfer is never lost, and a reconciler tracks anything still outstanding against the real on-chain record.

### Fiat On/Off-Ramp
Users move between bank money and USDC directly. Fiat deposits are converted to USDC that lands in the user's own Circle wallet, and USDC can be withdrawn back to a bank account. Corridors are data-driven, so new currencies and rails can be added as they become available without code changes. KYC is handled by the ramp provider, so Nexum never holds sensitive personal documents.

### Multi-Chain Send
Users send USDC to any address on any chain their wallet holds funds on. Settlement is judged by the real on-chain receipt on that chain - never assumed - and each transfer links to that chain's own block explorer, so confirmation is always verifiable.

### Invoices and Settlement
Businesses generate invoices with unique references and share payment links. The payer opens the link and settles in USDC, with local-currency invoices converted at live rates before payment; payments route through the vault so the platform fee is applied at source. A settlement reports view aggregates payments and conversions into a CSV for accounting.

### Payroll
Businesses pay many recipients in a single batch, each payment carrying a unique reference for reconciliation. Disbursement is funded once into a platform-operated payout wallet, from which the batch is paid out - the payroll dashboard shows totals, recipients paid, in-progress batches, and an exportable per-recipient ledger.

### Platform Fees
A uniform, inclusive 0.1% fee is collected on-chain, only on successful P2P releases and invoice payments (cancellations and reopened trades are never charged). Fee accounting lives in the vault with per-protocol balances, and withdrawals are bounded so they can never touch user escrow. A super-admin-only dashboard shows collected, withdrawn, and available fees per protocol.

### Profiles and Reputation
Every account has a unique username and public profile. Reputation builds automatically from completed trades, with tiers and a verified badge for established, dispute-free traders. Private profile details are owner-only and stripped server-side from public views.

### Dispute Resolution
Clear-cut cases resolve automatically: a taker who never pays has the offer returned to the marketplace; prolonged maker silence after payment auto-releases to the taker. Contested cases go to an admin who accepts the case as judge, chats with both parties, reviews uploaded evidence privately, and issues a verdict the smart contract executes. An AI triage assistant can produce a neutral, structured case summary to speed review - it is strictly advisory, never decides, never messages users, never touches escrow, and treats user-supplied chat and evidence as untrusted data.

---

## Accounts and Wallets

Nexum uses Circle programmable wallets. A user signs in with Google or email and a secure Circle wallet is provisioned on verification - no seed phrase to manage and no browser extension required. Funds are non-custodial: the user controls their wallet, and Nexum never takes custody of balances. Public invoice payers can pay without creating an account.

---

## Key Features at a Glance

**For individuals**
- Move between 160+ currencies and USDC at live rates
- On/off-ramp between bank money and USDC
- Bridge native USDC across Arc, Ethereum, Base, Arbitrum, Polygon, Optimism, Avalanche, Unichain and Monad
- Send USDC to any address on any supported chain
- Trade peer-to-peer at agreed rates with full on-chain escrow protection
- Built-in trade chat with payment proof and automatic cleanup
- Public profile with reputation tier and verified badge

**For businesses**
- Payroll dashboard with batch payouts and exportable recipient ledger
- Invoice generation with shareable payment links and settlement reports
- Non-custodial treasury in USDC with live local-currency equivalents

**For platform integrity**
- Smart-contract escrow - no counterparty custody
- Automatic resolution for clear-cut disputes, admin-mediated resolution for the rest
- Advisory AI case summaries to speed admin triage
- Uniform on-chain fee accounting that can never touch user funds
- Full on-chain history on the Arc explorer, every admin action logged

---

## Live Platform

- **Frontend:** [nexumpay.xyz](https://nexumpay.xyz)
- **Home chain:** Arc (Chain ID 5042)
- **Bridged chains:** Ethereum, Base, Arbitrum, Polygon, Optimism, Avalanche, Unichain, Monad
- **Settlement:** USDC on Arc, bridged with Circle CCTP
- **Explorer:** [explorer.arc.io](https://explorer.arc.io)

---

## Getting Started

1. Visit [nexumpay.xyz](https://nexumpay.xyz) and sign in with Google or email to get your Circle wallet
2. Fund your wallet with USDC, or use the on-ramp to convert from bank money
3. Create your profile with a unique username
4. Start trading, sending, bridging, on/off-ramping, or creating invoices

For businesses, reach out to the platform admin to set up payroll and treasury access.

---

## Developer Setup

```bash
# Clone the repository
git clone https://github.com/soft-developper/Nexum.git
cd Nexum

# Backend
cd nexum-api
npm install
cp .env.example .env        # fill in your credentials
npm run dev

# Frontend (new terminal)
cd nexum-web
npm install
cp .env.local.example .env.local    # fill in your credentials
npm run dev
```

See `.env.example` and `.env.local.example` for the full list of required environment variables.

---

*Built on Arc - Powered by USDC - Bridged with Circle CCTP - Settled on-chain*
