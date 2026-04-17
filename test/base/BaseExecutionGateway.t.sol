// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOFT} from "../mocks/MockOFT.sol";
import {BaseExecutionGateway} from "../../src/base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../../src/base/BaseStrategyModule.sol";
import {BaseOftSender} from "../../src/base/BaseOftSender.sol";
import {CrossVenueCommandLib} from "../../src/base/CrossVenueCommandLib.sol";

contract BaseExecutionGatewayTest is Test {
    MockERC20 internal usdc;
    MockOFT internal oft;
    BaseExecutionGateway internal gateway;
    BaseStrategyModule internal module;
    BaseOftSender internal oftSender;

    address internal owner = address(0xA11CE);
    address internal vault = address(0xBEEF);
    bytes32 internal constant PM_DEST_REF = keccak256("dest:pm-rail");
    bytes32 internal constant HL_DEST_REF = keccak256("dest:hl-rail");

    uint256 internal signer1Pk = 0xA1;
    uint256 internal signer2Pk = 0xA2;
    uint256 internal signer3Pk = 0xA3;
    address internal signer1;
    address internal signer2;
    address internal signer3;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oft = new MockOFT(address(usdc));
        signer1 = vm.addr(signer1Pk);
        signer2 = vm.addr(signer2Pk);
        signer3 = vm.addr(signer3Pk);

        module = new BaseStrategyModule(owner, address(usdc), address(0));
        gateway = new BaseExecutionGateway(owner, vault, address(usdc), address(module), "NekoBaseGateway", "1");
        oftSender = new BaseOftSender(address(usdc), owner);

        vm.startPrank(owner);
        module.setGateway(address(gateway));
        module.setOftSender(address(oftSender));
        oftSender.setAuthorizedCaller(address(module), true);
        oftSender.configureRoute(
            PM_DEST_REF,
            BaseOftSender.Route({
                oft: address(oft),
                dstEid: 30109, // Polygon
                recipient: bytes32(uint256(uint160(address(0xDEADBEEF)))),
                extraOptions: bytes(""),
                hlCoreReceiver: address(0),
                slippageBps: 0,
                active: true
            })
        );
        oftSender.configureRoute(
            HL_DEST_REF,
            BaseOftSender.Route({
                oft: address(oft),
                dstEid: 30316, // HyperEVM
                recipient: bytes32(uint256(uint160(address(0xCAFEBABE)))),
                extraOptions: bytes(""),
                hlCoreReceiver: address(0xABCD1234),
                slippageBps: 0,
                active: true
            })
        );
        gateway.setSigner(signer1, true);
        gateway.setSigner(signer2, true);
        gateway.setSigner(signer3, true);
        gateway.setThreshold(2);
        gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 1_000_000e6);
        gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER, 1_000_000e6);
        gateway.setDailyCap(2_000_000e6);
        vm.stopPrank();

        usdc.mint(address(module), 5_000_000e6);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _envelope(
        CrossVenueCommandLib.CommandType cmd,
        uint256 amount,
        uint256 nonce,
        bytes32 cycleId,
        uint256 deadline
    ) internal view returns (CrossVenueCommandLib.CommandEnvelope memory) {
        bytes32 destRef = cmd == CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER ? HL_DEST_REF : PM_DEST_REF;
        return CrossVenueCommandLib.CommandEnvelope({
            cycleId: cycleId,
            commandType: cmd,
            dstVault: vault,
            asset: address(usdc),
            amount: amount,
            destinationRef: destRef,
            payloadHash: keccak256("payload:v1"),
            nonce: nonce,
            deadline: deadline,
            ritualTxHash: keccak256("ritual:tx")
        });
    }

    function _sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _digestOf(CrossVenueCommandLib.CommandEnvelope memory env) internal view returns (bytes32) {
        bytes32 envHash = CrossVenueCommandLib.hashEnvelope(env);
        return CrossVenueCommandLib.digest(gateway.DOMAIN_SEPARATOR(), envHash);
    }

    /// Sigs sorted by signer address ascending (gateway requires strictly increasing recovered addresses).
    function _sortedSigs(CrossVenueCommandLib.CommandEnvelope memory env, uint256[] memory pks)
        internal
        view
        returns (bytes[] memory)
    {
        bytes32 d = _digestOf(env);
        // Sort pks by their addresses ascending.
        for (uint256 i = 0; i < pks.length; i++) {
            for (uint256 j = i + 1; j < pks.length; j++) {
                if (vm.addr(pks[i]) > vm.addr(pks[j])) {
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }
        bytes[] memory sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            sigs[i] = _sign(pks[i], d);
        }
        return sigs;
    }

    // ─── Tests ───────────────────────────────────────────────────────────────

    function testHappyPathPmTopUp() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);

        // Module → oftSender → MockOFT.send pulls from oftSender. USDC ends up in the mock OFT.
        uint256 before = usdc.balanceOf(address(oft));
        gateway.executeCommand(env, sigs);
        assertEq(usdc.balanceOf(address(oft)), before + 100e6);
    }

    function testRejectReplayedNonce() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        gateway.executeCommand(env, sigs);

        vm.expectRevert(BaseExecutionGateway.NonceAlreadyUsed.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectReplayedCycle() public {
        CrossVenueCommandLib.CommandEnvelope memory env1 =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(7)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs1 = _sortedSigs(env1, pks);
        gateway.executeCommand(env1, sigs1);

        CrossVenueCommandLib.CommandEnvelope memory env2 =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER, 50e6, 2, bytes32(uint256(7)), block.timestamp + 1 hours);
        bytes[] memory sigs2 = _sortedSigs(env2, pks);
        vm.expectRevert(BaseExecutionGateway.CycleAlreadyConsumed.selector);
        gateway.executeCommand(env2, sigs2);
    }

    function testRejectExpired() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);

        vm.warp(env.deadline + 1);
        vm.expectRevert(BaseExecutionGateway.EnvelopeExpired.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectWrongVault() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        env.dstVault = address(0xDEAD);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        vm.expectRevert(BaseExecutionGateway.WrongVault.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectBelowThreshold() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](1);
        pks[0] = signer1Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        vm.expectRevert(BaseExecutionGateway.InsufficientSignatures.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectDuplicateSigner() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        bytes32 d = _digestOf(env);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(signer1Pk, d);
        sigs[1] = _sign(signer1Pk, d);
        vm.expectRevert(BaseExecutionGateway.DuplicateSigner.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectNonSigner() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256 randomPk = 0xBADBEEF;
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = randomPk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        // One valid + one unauthorized → still below threshold (only 1 valid counts).
        vm.expectRevert(BaseExecutionGateway.InsufficientSignatures.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectAboveCommandCap() public {
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 1_000_001e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        vm.expectRevert(BaseExecutionGateway.AmountAboveCommandCap.selector);
        gateway.executeCommand(env, sigs);
    }

    function testRejectAboveDailyCap() public {
        for (uint256 i = 1; i <= 2; i++) {
            CrossVenueCommandLib.CommandEnvelope memory env = _envelope(
                CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER,
                1_000_000e6,
                i,
                bytes32(i),
                block.timestamp + 1 hours
            );
            uint256[] memory pks = new uint256[](2);
            pks[0] = signer1Pk;
            pks[1] = signer2Pk;
            gateway.executeCommand(env, _sortedSigs(env, pks));
        }

        CrossVenueCommandLib.CommandEnvelope memory env3 = _envelope(
            CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER, 1, 3, bytes32(uint256(3)), block.timestamp + 1 hours
        );
        uint256[] memory pks2 = new uint256[](2);
        pks2[0] = signer1Pk;
        pks2[1] = signer2Pk;
        bytes[] memory sigs3 = _sortedSigs(env3, pks2);
        vm.expectRevert(BaseExecutionGateway.AmountAboveDailyCap.selector);
        gateway.executeCommand(env3, sigs3);
    }

    function testPauseCommandPauses() public {
        CrossVenueCommandLib.CommandEnvelope memory envP =
            _envelope(CrossVenueCommandLib.CommandType.PAUSE, 0, 1, bytes32(uint256(99)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        gateway.executeCommand(envP, _sortedSigs(envP, pks));
        assertTrue(module.deploymentsPaused());

        CrossVenueCommandLib.CommandEnvelope memory env2 = _envelope(
            CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 2, bytes32(uint256(2)), block.timestamp + 1 hours
        );
        bytes[] memory sigs2 = _sortedSigs(env2, pks);
        vm.expectRevert(BaseStrategyModule.DeploymentsPaused.selector);
        gateway.executeCommand(env2, sigs2);
    }

    function testGatewayPauseFlag() public {
        vm.prank(owner);
        gateway.setPaused(true);
        CrossVenueCommandLib.CommandEnvelope memory env =
            _envelope(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, 100e6, 1, bytes32(uint256(1)), block.timestamp + 1 hours);
        uint256[] memory pks = new uint256[](2);
        pks[0] = signer1Pk;
        pks[1] = signer2Pk;
        bytes[] memory sigs = _sortedSigs(env, pks);
        vm.expectRevert(BaseExecutionGateway.Paused.selector);
        gateway.executeCommand(env, sigs);
    }

    function testModuleRejectsDirectCalls() public {
        // Module functions must only be callable by the gateway.
        vm.expectRevert(BaseStrategyModule.NotGateway.selector);
        module.topUpPmBuffer(100e6, bytes32(0), bytes32(0), bytes32(uint256(1)));
        vm.expectRevert(BaseStrategyModule.NotGateway.selector);
        module.topUpHlBuffer(100e6, bytes32(0), bytes32(0), bytes32(uint256(1)));
        vm.expectRevert(BaseStrategyModule.NotGateway.selector);
        module.pauseDeployments(bytes32(uint256(1)));
    }
}
