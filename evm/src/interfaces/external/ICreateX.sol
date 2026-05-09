// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ICreateX — minimal CreateX surface used by deploy scripts
interface ICreateX {
    error FailedContractCreation(address emitter);
    error FailedContractInitialisation(address emitter, bytes revertData);
    error FailedEtherTransfer(address emitter, bytes revertData);
    error InvalidNonceValue(address emitter);
    error InvalidSalt(address emitter);

    event ContractCreation(address indexed newContract, bytes32 indexed salt);
    event ContractCreation(address indexed newContract);
    event Create3ProxyContractCreation(address indexed newContract, bytes32 indexed salt);

    struct Values { uint256 constructorAmount; uint256 initCallAmount; }

    function computeCreate3Address(bytes32 salt) external view returns (address);
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
    function deployCreate3(bytes calldata initCode) external payable returns (address);
}
