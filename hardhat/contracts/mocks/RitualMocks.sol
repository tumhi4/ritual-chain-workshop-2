// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IScheduler, IRitualWallet, ITEEServiceRegistry, RitualChain} from "../ritual/RitualChain.sol";

contract MockScheduler is IScheduler {
    uint256 public nextCallId = 1;
    mapping(uint256 => bool) public cancelled;
    mapping(uint256 => uint8) public callStates;
    mapping(address => bool) public approved;

    struct ScheduledCall {
        address target;
        bytes data;
        uint32 gas;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
    }

    mapping(uint256 => ScheduledCall) public scheduledCalls;

    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external override returns (uint256 callId) {
        callId = nextCallId++;
        scheduledCalls[callId] = ScheduledCall({
            target: msg.sender,
            data: data,
            gas: gas,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            ttl: ttl,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            payer: payer
        });
        callStates[callId] = 1;
    }

    function cancel(uint256 callId) external override {
        cancelled[callId] = true;
        callStates[callId] = 2;
    }

    function getCallState(uint256 callId) external view override returns (uint8) {
        return callStates[callId];
    }

    function approveScheduler(address schedulerContract) external override {
        approved[schedulerContract] = true;
    }

    function trigger(uint256 callId, uint256 executionIndex) external returns (bool success) {
        ScheduledCall memory sc = scheduledCalls[callId];
        require(sc.target != address(0), "Call not found");
        
        bytes memory callData = sc.data;
        assembly {
            mstore(add(callData, 36), executionIndex)
        }
        
        (success, ) = sc.target.call{gas: sc.gas}(callData);
    }
}

contract MockRitualWallet is IRitualWallet {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public locks;

    function deposit(uint256 lockDuration) external payable override {
        balances[msg.sender] += msg.value;
        locks[msg.sender] = block.number + lockDuration;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function lockUntil(address account) external view override returns (uint256) {
        return locks[account];
    }
}

contract MockTEEServiceRegistry is ITEEServiceRegistry {
    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external pure override returns (address teeAddress, bool found) {
        return (address(0x1111111111111111111111111111111111111111), true);
    }

    function getIndexedServiceCountByCapability(uint8) external pure returns (uint256) {
        return 1;
    }
}

contract MockHttpPrecompile {
    fallback(bytes calldata) external returns (bytes memory) {
        string[] memory emptyArray = new string[](0);
        bytes memory mockBody = bytes("{\"price\": 4500}");
        uint16 mockStatus = 200;
        string memory mockError = "";
        bytes memory actualOutput = abi.encode(mockStatus, emptyArray, emptyArray, mockBody, mockError);
        bytes memory simmedInput = "";
        return abi.encode(simmedInput, actualOutput);
    }
}

contract MockJqPrecompile {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(4500));
    }
}
