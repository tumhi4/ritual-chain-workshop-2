// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * ConsensusPredict — Multi-Oracle Fault-Tolerant Prediction Market on Ritual Chain.
 *
 * Traditional prediction markets rely on a single oracle endpoint. If that single API fails,
 * rate-limits (429), or reports manipulated data, the entire market is compromised.
 *
 * ConsensusPredict solves this via Autonomous Multi-Source TEE Consensus:
 * 1. Markets can be configured with multiple independent oracle sources (e.g. Binance, Coinbase, CoinGecko).
 * 2. At the scheduled resolution block, the Ritual Scheduler (0x56e7...D58B) wakes the contract.
 * 3. Inside TEE execution, the contract queries all configured sources via HTTP (0x0801) + jq (0x0803).
 * 4. Filters failed/offline endpoints, eliminates extreme outliers, and calculates the Consensus Median Value.
 * 5. Settles the market with cryptographic auditability and fault tolerance.
 */
contract RitualPredict {
    // ─────────────────────────────── Types ───────────────────────────────

    enum MarketType {
        SingleSource,
        MultiConsensus
    }

    enum MarketState {
        Open,
        Closed,
        Resolving,
        Resolved,
        Invalid
    }

    enum Comparator {
        GT,
        GTE,
        LT,
        LTE
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    struct OracleSource {
        string oracleUrl;
        string jsonPath;
    }

    struct Market {
        uint256 id;
        address creator;
        MarketType marketType;
        string question;
        string oracleUrl;
        string jsonPath;
        uint8 minQuorum; // Minimum valid sources required (e.g. 2 of 3)
        uint256 target;
        Comparator comparator;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        uint256 totalYes;
        uint256 totalNo;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue; // Consensus median value
        uint8 validSourcesCount;
        string invalidReason;
    }

    struct NewMarket {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    struct NewConsensusMarket {
        string question;
        string[] oracleUrls;
        string[] jsonPaths;
        uint8 minQuorum;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    // ────────────────────────────── Constants ────────────────────────────

    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;
    uint32 public constant RESOLVE_GAS_LIMIT = 2_500_000;
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;
    uint256 public constant HTTP_TTL_BLOCKS = 100;
    uint256 public constant EXECUTOR_PROBES = 8;
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 30 days;

    // ────────────────────────────── Storage ──────────────────────────────

    uint256 public immutable blockTimeMs;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;
    mapping(uint256 => OracleSource[]) private _marketSources;

    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;

    // ────────────────────────────── Events ───────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        MarketType marketType,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );

    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        Comparator comparator
    );

    event ConsensusRuleSet(
        uint256 indexed marketId,
        uint8 sourceCount,
        uint8 minQuorum,
        uint256 target,
        Comparator comparator
    );

    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );

    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );

    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        string reason
    );

    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 consensusMedian,
        uint8 validSources
    );

    event MarketInvalidated(uint256 indexed marketId, string reason);

    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    event StakeRefunded(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    // ────────────────────────────── Errors ───────────────────────────────

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();
    error InvalidQuorum();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;

        IScheduler(RitualChain.SCHEDULER).approveScheduler(
            RitualChain.SCHEDULER
        );
    }

    // ───────────────────────── Market Creation ───────────────────────────

    function createMarket(
        NewMarket calldata p
    ) external returns (uint256 marketId) {
        if (
            bytes(p.question).length == 0 ||
            bytes(p.oracleUrl).length == 0 ||
            bytes(p.jsonPath).length == 0
        ) revert EmptyString();

        if (
            p.bettingSeconds < MIN_BETTING_SECONDS ||
            p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS
        ) revert BadDuration();

        uint64 closeBlock = uint64(block.number + _secondsToBlocks(p.bettingSeconds));
        uint64 resolveBlock = uint64(closeBlock + _secondsToBlocks(p.resolveDelaySeconds));

        marketCount++;
        marketId = marketCount;

        uint256 scheduleId = _scheduleResolution(marketId, resolveBlock);

        _markets[marketId] = Market({
            id: marketId,
            creator: msg.sender,
            marketType: MarketType.SingleSource,
            question: p.question,
            oracleUrl: p.oracleUrl,
            jsonPath: p.jsonPath,
            minQuorum: 1,
            target: p.target,
            comparator: p.comparator,
            closeBlock: closeBlock,
            resolveBlock: resolveBlock,
            scheduleId: scheduleId,
            totalYes: 0,
            totalNo: 0,
            state: MarketState.Open,
            outcome: Outcome.Unresolved,
            attempts: 0,
            observedValue: 0,
            validSourcesCount: 1,
            invalidReason: ""
        });

        emit MarketCreated(
            marketId,
            msg.sender,
            MarketType.SingleSource,
            p.question,
            closeBlock,
            resolveBlock,
            scheduleId
        );

        emit ResolutionRuleSet(
            marketId,
            p.oracleUrl,
            p.jsonPath,
            p.target,
            p.comparator
        );
    }

    function createConsensusMarket(
        NewConsensusMarket calldata p
    ) external returns (uint256 marketId) {
        if (bytes(p.question).length == 0) revert EmptyString();
        if (p.oracleUrls.length == 0 || p.oracleUrls.length != p.jsonPaths.length) revert EmptyString();
        if (p.minQuorum == 0 || p.minQuorum > p.oracleUrls.length) revert InvalidQuorum();

        if (
            p.bettingSeconds < MIN_BETTING_SECONDS ||
            p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS
        ) revert BadDuration();

        uint64 closeBlock = uint64(block.number + _secondsToBlocks(p.bettingSeconds));
        uint64 resolveBlock = uint64(closeBlock + _secondsToBlocks(p.resolveDelaySeconds));

        marketCount++;
        marketId = marketCount;

        uint256 scheduleId = _scheduleResolution(marketId, resolveBlock);

        _markets[marketId] = Market({
            id: marketId,
            creator: msg.sender,
            marketType: MarketType.MultiConsensus,
            question: p.question,
            oracleUrl: "",
            jsonPath: "",
            minQuorum: p.minQuorum,
            target: p.target,
            comparator: p.comparator,
            closeBlock: closeBlock,
            resolveBlock: resolveBlock,
            scheduleId: scheduleId,
            totalYes: 0,
            totalNo: 0,
            state: MarketState.Open,
            outcome: Outcome.Unresolved,
            attempts: 0,
            observedValue: 0,
            validSourcesCount: 0,
            invalidReason: ""
        });

        for (uint256 i = 0; i < p.oracleUrls.length; i++) {
            _marketSources[marketId].push(
                OracleSource({
                    oracleUrl: p.oracleUrls[i],
                    jsonPath: p.jsonPaths[i]
                })
            );
        }

        emit MarketCreated(
            marketId,
            msg.sender,
            MarketType.MultiConsensus,
            p.question,
            closeBlock,
            resolveBlock,
            scheduleId
        );

        emit ConsensusRuleSet(
            marketId,
            uint8(p.oracleUrls.length),
            p.minQuorum,
            p.target,
            p.comparator
        );
    }

    // ───────────────────────── Betting ───────────────────────────────────

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock)
            revert BettingClosed();

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    // ───────────────────────── Resolution Callback ───────────────────────

    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();

        Market storage m = _market(marketId);
        if (m.state == MarketState.Resolved || m.state == MarketState.Invalid) {
            return;
        }

        m.attempts++;
        uint8 attempt = m.attempts;

        address executor = _pickExecutor(marketId, executionIndex);
        emit ResolutionAttempted(marketId, attempt, executor);

        (bool ok, uint256 consensusValue, uint8 validCount, string memory reason) = _resolveMarketValue(m, executor);

        if (!ok) {
            if (attempt < MAX_ATTEMPTS) {
                m.state = MarketState.Resolving;
            }
            _fail(m, marketId, attempt, reason);
            return;
        }

        try IScheduler(RitualChain.SCHEDULER).cancel(m.scheduleId) {} catch {}

        m.observedValue = consensusValue;
        m.validSourcesCount = validCount;

        bool wonYes = _compare(consensusValue, m.target, m.comparator);

        if (wonYes) {
            if (m.totalYes == 0) {
                _invalidate(m, marketId, "no winners on YES side");
                return;
            }
            m.state = MarketState.Resolved;
            m.outcome = Outcome.Yes;
        } else {
            if (m.totalNo == 0) {
                _invalidate(m, marketId, "no winners on NO side");
                return;
            }
            m.state = MarketState.Resolved;
            m.outcome = Outcome.No;
        }

        emit MarketResolved(marketId, m.outcome, consensusValue, validCount);
    }

    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        string memory reason
    ) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        emit MarketInvalidated(marketId, reason);
    }

    // ────────────────────────────── Payouts ──────────────────────────────

    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStake[marketId][msg.sender] +
            noStake[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStake[marketId][account]
            : noStake[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        return (stake * (m.totalYes + m.totalNo)) / winningPool;
    }

    // ────────────────────────────── Views ────────────────────────────────

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        if (m.state == MarketState.Open && block.number >= m.closeBlock)
            m.state = MarketState.Closed;
    }

    function getMarkets() external view returns (Market[] memory all) {
        uint256 total = marketCount;
        all = new Market[](total);
        for (uint256 i = 0; i < total; i++) {
            all[i] = getMarket(total - i);
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStake[marketId][account],
            noStake[marketId][account],
            settled[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.state == MarketState.Resolved)
            claimable = _payout(m, marketId, account);
        else if (m.state == MarketState.Invalid) claimable = yes + no;
    }

    // ───────────────────────── Execution funding ─────────────────────────

    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return
            IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    // ───────────────────── Ritual: Multi-Oracle Read Path ────────────────

    function _resolveMarketValue(
        Market storage m,
        address executor
    ) private returns (bool ok, uint256 consensusValue, uint8 validCount, string memory reason) {
        if (m.marketType == MarketType.SingleSource) {
            (bool sOk, uint256 sVal, string memory sReason) = _readSingleOracle(m.oracleUrl, m.jsonPath, executor);
            if (!sOk) return (false, 0, 0, sReason);
            return (true, sVal, 1, "");
        } else {
            OracleSource[] storage sources = _marketSources[m.id];
            uint256 len = sources.length;
            uint256[] memory collectedValues = new uint256[](len);
            uint8 count = 0;

            for (uint256 i = 0; i < len; i++) {
                (bool srcOk, uint256 val, ) = _readSingleOracle(sources[i].oracleUrl, sources[i].jsonPath, executor);
                if (srcOk) {
                    collectedValues[count] = val;
                    count++;
                }
            }

            if (count < m.minQuorum) {
                return (false, 0, count, "Consensus quorum not reached");
            }

            // Calculate median from collected values
            uint256 median = _calculateMedian(collectedValues, count);
            return (true, median, count, "");
        }
    }

    function _readSingleOracle(
        string memory url,
        string memory jsonPath,
        address executor
    ) private returns (bool ok, uint256 value, string memory reason) {
        if (executor == address(0)) {
            return (false, 0, "no valid TEE executor found");
        }

        string[] memory emptyHeaders = new string[](0);
        bytes memory inputData = abi.encode(
            executor,
            RitualChain.HTTP_GET,
            url,
            emptyHeaders,
            bytes(""),
            HTTP_TTL_BLOCKS
        );

        (bool callOk, bytes memory rawResponse) = RitualChain
            .HTTP_PRECOMPILE
            .call(inputData);

        if (!callOk || rawResponse.length == 0) {
            return (false, 0, "HTTP precompile call failed");
        }

        try this.decodeHttpResponse(rawResponse) returns (
            uint16 status,
            bytes memory body,
            string memory errorMessage
        ) {
            if (bytes(errorMessage).length > 0) return (false, 0, errorMessage);
            if (status != 200) return (false, 0, "HTTP non-200 status");

            (bool jqOk, uint256 parsedValue) = _jqUint(jsonPath, string(body));
            if (!jqOk) return (false, 0, "jq extraction failed");

            return (true, parsedValue, "");
        } catch Error(string memory err) {
            return (false, 0, err);
        } catch {
            return (false, 0, "HTTP response decoding failed");
        }
    }

    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    function _calculateMedian(uint256[] memory arr, uint8 count) private pure returns (uint256) {
        // Simple in-memory bubble sort for small array (count <= 10)
        for (uint8 i = 0; i < count; i++) {
            for (uint8 j = i + 1; j < count; j++) {
                if (arr[i] > arr[j]) {
                    uint256 tmp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = tmp;
                }
            }
        }

        if (count % 2 == 1) {
            return arr[count / 2];
        } else {
            return (arr[(count / 2) - 1] + arr[count / 2]) / 2;
        }
    }

    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _pickExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        uint256 seed = uint256(
            keccak256(
                abi.encode(
                    block.prevrandao,
                    block.number,
                    marketId,
                    executionIndex
                )
            )
        );
        (address executor, bool found) = ITEEServiceRegistry(
            RitualChain.TEE_SERVICE_REGISTRY
        ).pickServiceByCapability(
            RitualChain.CAPABILITY_HTTP_CALL,
            true,
            seed,
            EXECUTOR_PROBES
        );
        if (!found) return address(0);
        return executor;
    }

    function _scheduleResolution(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        bytes memory payload = abi.encodeWithSelector(
            this.onScheduledResolve.selector,
            uint256(0),
            marketId
        );

        callId = IScheduler(RitualChain.SCHEDULER).schedule(
            payload,
            RESOLVE_GAS_LIMIT,
            uint32(resolveBlock),
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            MIN_MAX_FEE_PER_GAS,
            0,
            0,
            address(this)
        );
    }

    // ────────────────────────────── Helpers ──────────────────────────────

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) private pure returns (bool) {
        if (comparator == Comparator.GT) return observed > target;
        if (comparator == Comparator.GTE) return observed >= target;
        if (comparator == Comparator.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
