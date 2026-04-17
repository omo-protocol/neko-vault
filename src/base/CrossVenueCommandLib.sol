// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title CrossVenueCommandLib
/// @notice Canonical types and EIP-712 hashing for the narrow Ritual→Base command envelope.
///         Base contracts MUST only consume CommandEnvelope. Raw venue-trade payloads
///         and arbitrary calldata are explicitly out of scope.
library CrossVenueCommandLib {
    enum CommandType {
        TOPUP_PM_BUFFER,
        TOPUP_HL_BUFFER,
        PAUSE,
        REFILL_RESERVE
    }

    struct CommandEnvelope {
        bytes32 cycleId;
        CommandType commandType;
        address dstVault;
        address asset;
        uint256 amount;
        bytes32 destinationRef;
        bytes32 payloadHash;
        uint256 nonce;
        uint256 deadline;
        bytes32 ritualTxHash;
    }

    bytes32 internal constant COMMAND_ENVELOPE_TYPEHASH = keccak256(
        "CommandEnvelope(bytes32 cycleId,uint8 commandType,address dstVault,address asset,uint256 amount,bytes32 destinationRef,bytes32 payloadHash,uint256 nonce,uint256 deadline,bytes32 ritualTxHash)"
    );

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function hashEnvelope(CommandEnvelope memory env) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMAND_ENVELOPE_TYPEHASH,
                env.cycleId,
                uint8(env.commandType),
                env.dstVault,
                env.asset,
                env.amount,
                env.destinationRef,
                env.payloadHash,
                env.nonce,
                env.deadline,
                env.ritualTxHash
            )
        );
    }

    function domainSeparator(string memory name, string memory version, address verifyingContract)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifyingContract
            )
        );
    }

    function digest(bytes32 separator, bytes32 envHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", separator, envHash));
    }
}
