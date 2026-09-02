import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { parseEther, getAddress } from "viem";

const SCHEDULER_ADDR = getAddress("0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B");
const RITUAL_WALLET_ADDR = getAddress("0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948");
const TEE_REGISTRY_ADDR = getAddress("0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F");
const HTTP_PRECOMPILE_ADDR = getAddress("0x0000000000000000000000000000000000000801");
const JQ_PRECOMPILE_ADDR = getAddress("0x0000000000000000000000000000000000000803");

describe("ConsensusPredict — Multi-Oracle Fault-Tolerant Prediction Market", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();
  const [deployer, alice, bob, carol] = await viem.getWalletClients();

  let predict: any;
  let mockScheduler: any;
  let mockWallet: any;
  let mockTeeRegistry: any;
  let mockHttp: any;
  let mockJq: any;

  beforeEach(async () => {
    mockScheduler = await viem.deployContract("MockScheduler");
    mockWallet = await viem.deployContract("MockRitualWallet");
    mockTeeRegistry = await viem.deployContract("MockTEEServiceRegistry");
    mockHttp = await viem.deployContract("MockHttpPrecompile");
    mockJq = await viem.deployContract("MockJqPrecompile");

    const schedulerBytecode = await publicClient.getCode({ address: mockScheduler.address });
    const walletBytecode = await publicClient.getCode({ address: mockWallet.address });
    const registryBytecode = await publicClient.getCode({ address: mockTeeRegistry.address });
    const httpBytecode = await publicClient.getCode({ address: mockHttp.address });
    const jqBytecode = await publicClient.getCode({ address: mockJq.address });

    await testClient.setCode({ address: SCHEDULER_ADDR, bytecode: schedulerBytecode! });
    await testClient.setCode({ address: RITUAL_WALLET_ADDR, bytecode: walletBytecode! });
    await testClient.setCode({ address: TEE_REGISTRY_ADDR, bytecode: registryBytecode! });
    await testClient.setCode({ address: HTTP_PRECOMPILE_ADDR, bytecode: httpBytecode! });
    await testClient.setCode({ address: JQ_PRECOMPILE_ADDR, bytecode: jqBytecode! });

    predict = await viem.deployContract("RitualPredict", [200n]);
  });

  it("1. Execution Funding: should deposit execution gas into RitualWallet escrow", async () => {
    const fundingAmount = parseEther("1.0");
    await predict.write.fundExecution([500000n], { value: fundingAmount });

    const balance = await predict.read.executionBalance();
    assert.equal(balance, fundingAmount);
  });

  it("2. Single-Source Market: creates, bets, and resolves autonomously", async () => {
    await predict.write.createMarket([
      {
        question: "Will ETH be at least $4,000?",
        oracleUrl: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
        jsonPath: ".ethereum.usd",
        target: 4000n,
        comparator: 1, // GTE
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);

    const aliceStake = parseEther("2.0");
    const bobStake = parseEther("1.0");

    const predictAlice = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: alice } });
    const predictBob = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob } });

    await predictAlice.write.bet([1n, true], { value: aliceStake });
    await predictBob.write.bet([1n, false], { value: bobStake });

    await testClient.impersonateAccount({ address: SCHEDULER_ADDR });
    await testClient.setBalance({ address: SCHEDULER_ADDR, value: parseEther("10.0") });
    const schedulerWallet = await viem.getWalletClient(SCHEDULER_ADDR);
    const predictFromScheduler = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: schedulerWallet } });

    await predictFromScheduler.write.onScheduledResolve([0n, 1n]);

    const market = await predict.read.getMarket([1n]);
    assert.equal(market.state, 3); // Resolved
    assert.equal(market.outcome, 1); // Yes
    assert.equal(market.observedValue, 4500n);

    // Alice claims
    const aliceBalBefore = await publicClient.getBalance({ address: alice.account.address });
    const tx = await predictAlice.write.claimWinnings([1n]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
    const gasSpent = receipt.gasUsed * receipt.effectiveGasPrice;
    const aliceBalAfter = await publicClient.getBalance({ address: alice.account.address });
    assert.equal(aliceBalAfter - aliceBalBefore + gasSpent, aliceStake + bobStake);
  });

  it("3. Multi-Oracle Consensus: aggregates 3 independent sources & computes median value", async () => {
    await predict.write.createConsensusMarket([
      {
        question: "Will BTC be at least $95,000 across major exchanges?",
        oracleUrls: [
          "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT",
          "https://api.coinbase.com/v2/prices/BTC-USD/spot",
          "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
        ],
        jsonPaths: [".price", ".data.amount", ".bitcoin.usd"],
        minQuorum: 2,
        target: 4000n,
        comparator: 1, // GTE
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);

    const aliceStake = parseEther("3.0");
    const bobStake = parseEther("2.0");

    const predictAlice = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: alice } });
    const predictBob = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob } });

    await predictAlice.write.bet([1n, true], { value: aliceStake });
    await predictBob.write.bet([1n, false], { value: bobStake });

    // Settle via Scheduler
    await testClient.impersonateAccount({ address: SCHEDULER_ADDR });
    await testClient.setBalance({ address: SCHEDULER_ADDR, value: parseEther("10.0") });
    const schedulerWallet = await viem.getWalletClient(SCHEDULER_ADDR);
    const predictFromScheduler = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: schedulerWallet } });

    await predictFromScheduler.write.onScheduledResolve([0n, 1n]);

    const market = await predict.read.getMarket([1n]);
    assert.equal(market.state, 3); // Resolved
    assert.equal(market.outcome, 1); // Yes
    assert.equal(market.validSourcesCount, 3); // All 3 verified
    assert.equal(market.observedValue, 4500n); // Consensus median

    // Alice claims total 5.0 ETH pool
    const aBalBefore = await publicClient.getBalance({ address: alice.account.address });
    const tx = await predictAlice.write.claimWinnings([1n]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
    const gas = receipt.gasUsed * receipt.effectiveGasPrice;
    const aBalAfter = await publicClient.getBalance({ address: alice.account.address });
    assert.equal(aBalAfter - aBalBefore + gas, aliceStake + bobStake);
  });

  it("4. Empty Winning Side: refunds all participants if no one bet on the winning outcome", async () => {
    await predict.write.createMarket([
      {
        question: "Will ETH be at least $4,000?",
        oracleUrl: "https://api.example.com/eth",
        jsonPath: ".price",
        target: 4000n,
        comparator: 1,
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);

    const bobStake = parseEther("2.0");
    const predictBob = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob } });
    await predictBob.write.bet([1n, false], { value: bobStake });

    await testClient.impersonateAccount({ address: SCHEDULER_ADDR });
    await testClient.setBalance({ address: SCHEDULER_ADDR, value: parseEther("10.0") });
    const schedulerWallet = await viem.getWalletClient(SCHEDULER_ADDR);
    const predictFromScheduler = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: schedulerWallet } });

    await predictFromScheduler.write.onScheduledResolve([0n, 1n]);

    const market = await predict.read.getMarket([1n]);
    assert.equal(market.state, 4); // Invalid

    const bobBalBefore = await publicClient.getBalance({ address: bob.account.address });
    const refundTx = await predictBob.write.claimRefund([1n]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: refundTx });
    const gasSpent = receipt.gasUsed * receipt.effectiveGasPrice;
    const bobBalAfter = await publicClient.getBalance({ address: bob.account.address });
    assert.equal(bobBalAfter - bobBalBefore + gasSpent, bobStake);
  });
});
