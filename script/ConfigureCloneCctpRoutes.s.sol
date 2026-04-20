// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {BaseCctpSender} from "../src/base/BaseCctpSender.sol";

/// @notice Per-vault CCTP route configuration. Run once per clone after `execFactory.deployExec`.
///         Each vault owns its own BaseCctpSender (one-per-clone, not shared), so the routes
///         here only affect this caller's vault. Called by the vaultOwner.
///
///         CCTP V2 domains: Ethereum=0, Avalanche=1, Arbitrum=3, Base=6, Polygon=7, HyperEVM=19.
///
///         destinationRefs the controllers emit (must all have routes if the archetype uses them):
///           "dest:hl:spot"     — MultiLeg HL-SPOT leg top-up → HL wallet (adapter moves to spot)
///           "dest:hl:perp"     — MultiLeg HL-PERP leg top-up → same HL wallet (adapter moves to perp)
///           "dest:pm"          — MultiLeg POLYMARKET leg top-up → Polymarket API wallet on Polygon
///           "dest:arb:ptloop"  — PtLoopController top-up → Arb PtLoopExecutor clone
///
///         Env vars (required):
///           PRIVATE_KEY          — vault owner (sender owner)
///           CCTP_SENDER          — this vault's BaseCctpSender
///
///         Archetype-specific (set only the ones your legs/strategy actually need):
///           HL_WALLET            — HyperEVM trading wallet; enables both `dest:hl:spot` and
///                                  `dest:hl:perp` routes (same recipient, different keys so the
///                                  adapter can tell which sub-balance to top up after mint).
///           HL_MAX_FEE           (default 0 = standard; set to ~50 for fast)
///           HL_FINALITY          (default 1000 = standard; 2000 = fast)
///
///           PM_WALLET            — Polymarket API wallet on Polygon; enables `dest:pm`.
///           PM_MAX_FEE           (default 0)
///           PM_FINALITY          (default 1000)
///
///           ARB_PT_EXECUTOR      — Arb-side PtLoopExecutor clone for this user/strategy. Deploy
///                                  first via `PtLoopFactory.cloneFor(owner, agent)` on Arb and
///                                  pass its address here. Enables `dest:arb:ptloop`.
///           PT_MAX_FEE           (default 50000 = fast transfer; PT loop needs sub-minute settle)
///           PT_FINALITY          (default 1000)
///
///         At least one archetype's wallet/executor must be set or the script reverts.
contract ConfigureCloneCctpRoutes is Script {
    uint32 constant DOMAIN_ARBITRUM = 3;
    uint32 constant DOMAIN_POLYGON = 7;
    uint32 constant DOMAIN_HYPEREVM = 19;

    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        BaseCctpSender sender = BaseCctpSender(payable(vm.envAddress("CCTP_SENDER")));
        address hlWallet = vm.envOr("HL_WALLET", address(0));
        address pmWallet = vm.envOr("PM_WALLET", address(0));
        address arbPtExec = vm.envOr("ARB_PT_EXECUTOR", address(0));

        if (hlWallet == address(0) && pmWallet == address(0) && arbPtExec == address(0)) {
            revert("set at least one of HL_WALLET / PM_WALLET / ARB_PT_EXECUTOR");
        }

        vm.startBroadcast(ownerPk);

        if (hlWallet != address(0)) {
            // HL spot + perp share the same HyperEVM wallet but use distinct destRef keys so the
            // adapter can read the ref off the top-up envelope and push USDC into the correct
            // HL Core sub-balance (spot vs perp). Collapsing to a single `dest:hl` key would
            // break the adapter's sub-balance routing.
            uint256 hlMaxFee = vm.envOr("HL_MAX_FEE", uint256(0));
            uint32 hlFinality = uint32(vm.envOr("HL_FINALITY", uint256(1000)));
            BaseCctpSender.Route memory hlRoute = BaseCctpSender.Route({
                destinationDomain: DOMAIN_HYPEREVM,
                mintRecipient: bytes32(uint256(uint160(hlWallet))),
                maxFee: hlMaxFee,
                minFinalityThreshold: hlFinality,
                hookData: bytes(""),
                active: true
            });
            sender.configureRoute(keccak256("dest:hl:spot"), hlRoute);
            sender.configureRoute(keccak256("dest:hl:perp"), hlRoute);
            console.log("HL spot + perp routes (domain 19) -> %s", hlWallet);
        }

        if (pmWallet != address(0)) {
            sender.configureRoute(
                keccak256("dest:pm"),
                BaseCctpSender.Route({
                    destinationDomain: DOMAIN_POLYGON,
                    mintRecipient: bytes32(uint256(uint160(pmWallet))),
                    maxFee: vm.envOr("PM_MAX_FEE", uint256(0)),
                    minFinalityThreshold: uint32(vm.envOr("PM_FINALITY", uint256(1000))),
                    hookData: bytes(""),
                    active: true
                })
            );
            console.log("PM route (domain 7) -> %s", pmWallet);
        }

        if (arbPtExec != address(0)) {
            sender.configureRoute(
                keccak256("dest:arb:ptloop"),
                BaseCctpSender.Route({
                    destinationDomain: DOMAIN_ARBITRUM,
                    mintRecipient: bytes32(uint256(uint160(arbPtExec))),
                    maxFee: vm.envOr("PT_MAX_FEE", uint256(50000)),
                    minFinalityThreshold: uint32(vm.envOr("PT_FINALITY", uint256(1000))),
                    hookData: bytes(""),
                    active: true
                })
            );
            console.log("PT loop route (domain 3) -> %s", arbPtExec);
        }

        vm.stopBroadcast();
        console.log("Clone CCTP routes configured on:", address(sender));
    }
}
