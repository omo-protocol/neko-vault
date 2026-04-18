// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualHttpLib} from "./RitualHttpLib.sol";

/// @notice External library that wraps the boilerplate of building an HTTP-precompile envelope
///         and dispatching it. Kept external so the controller's runtime stays under EIP-170 —
///         every `_submit*` callsite in the controller collapses to a single library call.
library MultiLegSubmitLib {
    struct Ctx {
        string adapterUrl;
        address executor;
        bytes[] encryptedSecrets;
        bytes[] secretSignatures;
        string[] secretHeaderKeys;
        string[] secretHeaderValues;
        uint64 pollIntervalBlocks;
        uint64 maxPollBlock;
        uint256 deliveryGasLimit;
        uint256 ttl;
        address controller;
    }

    function dispatch(
        Ctx memory ctx,
        string memory urlPath,
        bytes memory payload,
        bytes4 callback
    ) external {
        RitualHttpLib.submit(
            RitualHttpLib.HttpRequest({
                url: string(abi.encodePacked(ctx.adapterUrl, urlPath)),
                payload: payload,
                executor: ctx.executor,
                encryptedSecrets: ctx.encryptedSecrets,
                secretSignatures: ctx.secretSignatures,
                secretHeaderKeys: ctx.secretHeaderKeys,
                secretHeaderValues: ctx.secretHeaderValues,
                ttl: ctx.ttl
            }),
            RitualHttpLib.Polling({
                pollIntervalBlocks: ctx.pollIntervalBlocks,
                maxPollBlock: ctx.maxPollBlock
            }),
            RitualHttpLib.Delivery({
                target: ctx.controller,
                callback: callback,
                gasLimit: ctx.deliveryGasLimit
            })
        );
    }
}
