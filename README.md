# ConsensusPredict — Multi-Oracle Fault-Tolerant Prediction Market on Ritual Chain

An autonomous, self-resolving binary prediction market on [Ritual Chain](https://docs.ritualfoundation.org) featuring **Multi-Source TEE Consensus Aggregation**.

---

## 🌟 The Problem ConsensusPredict Solves

Standard EVM prediction markets and single-oracle contracts suffer from three major vulnerabilities:
1. **Single Point of Failure (SPOF)**: If the single oracle API (e.g. CoinGecko) rate-limits (HTTP 429), goes down (HTTP 500), or has stale data, the entire market breaks.
2. **Flash Manipulation**: A single bad actor or temporary price glitch on one exchange can unfairly settle an entire prediction market.
3. **Passive Keeper Dependency**: Smart contracts normally cannot wake up without centralized bots or keepers.

**ConsensusPredict solves all three natively on Ritual Chain**:
* 🛡️ **Multi-Source TEE Consensus**: Accepts an array of 3 to 5 independent data sources (e.g. Binance API, Coinbase API, Kraken API, CoinGecko API) and their respective jq query paths.
* 📊 **Outlier Elimination & Median Computation**: Gathers responses in TEE, validates quorum, eliminates extreme statistical anomalies, and calculates the **Consensus Median**.
* ⏰ **Autonomous Scheduling**: Uses the native **Ritual Scheduler (`0x56e7...D58B`)** to trigger resolution at the designated block with prepaid execution fees in **`RitualWallet (`0x532F...3948`)**.
* 💰 **Pari-Mutuel Pull Payouts**: Zero gas loops over participants, with automatic 100% refund protections if quorum fails or the winning side has zero bets.

---

## 🏗️ Architecture

```
                       createConsensusMarket(question, [urls], [jsonPaths], minQuorum, target)
     User  ──────────────────────────────────────────────────────────────────────────────────▶  ┌──────────────────────────┐
     User  ─────────────────────────────── bet(id, YES|NO) ──────────────────────────────────▶  │    RitualPredict.sol     │
                                                                                                 │  markets, pools, stakes  │
                                                               schedule() ◀──────────────────────┤                          │
                                                                                                 └──────────────────────────┘
      ┌─────────────────────────────┐                          ▲                                      │
      │ Scheduler  0x56e7…D58B      │  onScheduledResolve      │                                      │ deposit()
      │ system contract             │──────────────────────────┘                                      ▼
      │ fires at resolveBlock       │                                                    ┌────────────────────────┐
      │ 3 attempts, 200 blocks gap  │                                                    │ RitualWallet 0x532F…   │
      └─────────────────────────────┘                                                    │ prepaid execution fees │
                                                                                         └────────────────────────┘
                                      inside that scheduled transaction:

     TEEServiceRegistry 0x9644…  ──pickServiceByCapability(HTTP_CALL)──▶  TEE Executor Node
     
     HTTP Precompile 0x0801 + jq 0x0803:
     ├── Source 1 (Binance API)   ──▶ HTTP GET + jq  ──▶ $95,200
     ├── Source 2 (Coinbase API)  ──▶ HTTP GET + jq  ──▶ $95,150
     └── Source 3 (CoinGecko API) ──▶ HTTP GET + jq  ──▶ $95,180
                                                            │
                                                            ▼
                                   Consensus Median Computation ($95,180)
                                   Compare with Target ($95,000) ──▶ Settle Outcome.Yes
```

---

## 🧪 Local Mock Testing Suite

This repository includes a standalone local mock engine in `contracts/mocks/RitualMocks.sol` simulating canonical Ritual addresses (`0x0801`, `0x0803`, `0x56e7...`, `0x532F...`, `0x9644...`).

### Running Tests

```bash
cd hardhat
npm install --allow-git=all
npx hardhat test
```

### Verified Test Cases (`test/RitualPredict.test.ts`):
1. **Execution Funding**: Deposits and locks gas fees into `RitualWallet`.
2. **Single-Source Market**: Basic autonomous resolution and winner payout.
3. **Multi-Oracle Consensus**: Aggregates 3 independent sources, verifies quorum, computes median, and pays winners.
4. **Empty Winning Side**: Full refund guarantees if no one bets on the winning outcome.

---

## 📋 Reflection Question

> **"What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?"**

* **What should be public**: The list of oracle sources, jq query paths, minimum quorum requirements, target price thresholds, scheduled resolve blocks, and escrow balances. Making these public guarantees deterministic and transparent rule sets.
* **What should stay hidden**: Participant bet amounts and commit salts during the open betting phase. Keeping orders private inside TEE or commit-reveal envelopes prevents front-running and copy-trading arbitrage.
* **What should be decided by AI vs. by a Human**: Algorithmic consensus and statistical aggregation (filtering outliers, fetching multiple APIs, computing medians) should be executed autonomously by TEE-backed code. Humans should only intervene for emergency pause mechanisms or subjective governance appeals where no API consensus exists.

---

## 🚀 Quickstart

```bash
# 1. Clone your fork
git clone https://github.com/<YOUR_USERNAME>/ritual-chain-workshop-2.git
cd ritual-chain-workshop-2/hardhat

# 2. Install dependencies
npm install --allow-git=all

# 3. Compile contracts
npx hardhat compile

# 4. Run test suite
npx hardhat test
```
