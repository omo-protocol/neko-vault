// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title Ritual Chain precompile and system contract addresses
library RitualPrecompiles {
    // Precompiles
    address internal constant HTTP_CALL = address(0x0801);
    address internal constant LLM = address(0x0802);
    address internal constant JQ = address(0x0803);
    address internal constant LONG_RUNNING_HTTP = address(0x0805);
    address internal constant ONNX = address(0x0800);

    // System contracts
    address internal constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address internal constant ASYNC_JOB_TRACKER = 0xC069FFCa0389f44eCA2C626e55491b0ab045AEF5;
    address internal constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address internal constant TEE_SERVICE_REGISTRY = 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F;
    address internal constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address internal constant SECRETS_ACCESS_CONTROL = 0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD;
}
