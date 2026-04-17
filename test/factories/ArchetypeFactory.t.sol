// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ArchetypeFactory} from "../../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../../src/controllers/cross_venue/MultiLegController.sol";
import {PtLoopController, PtLoopConfig} from "../../src/controllers/cross_venue/PtLoopController.sol";
// Templates deployed separately + passed into the factory (EIP-3860 initcode limit workaround).
import {LegConfig} from "../../src/controllers/cross_venue/MultiLegTypes.sol";
import {Side, MarginMode} from "../../src/controllers/cross_venue/SharedVenueTypes.sol";
import {CrossVenueCommandLib} from "../../src/base/CrossVenueCommandLib.sol";

contract ArchetypeFactoryTest is Test {
    ArchetypeFactory factory;
    address factoryOwner = address(0xF0F0);
    address stratOwner = address(0xA11CE);
    address baseVault = address(0xBA5E);
    address baseAsset = address(0x1DC);
    address executor = address(0xE2EC);

    function setUp() public {
        address mlTemplate = address(new MultiLegController());
        address ptTemplate = address(new PtLoopController());
        factory = new ArchetypeFactory(factoryOwner, mlTemplate, ptTemplate);
    }

    function testTemplatesDeployed() public view {
        assertTrue(factory.multiLegTemplate() != address(0));
        assertTrue(factory.ptLoopTemplate() != address(0));
    }

    function _minMultiLeg() internal view returns (MultiLegController.InitParams memory p) {
        LegConfig[] memory ls = new LegConfig[](2);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"),
            marketRef: bytes32(uint256(1)),
            weightBps: int16(5000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: bytes32(uint256(2)),
            marginMode: MarginMode.Isolated
        });
        ls[1] = LegConfig({
            venue: keccak256("HYPERLIQUID-PERP"),
            marketRef: bytes32(uint256(3)),
            weightBps: int16(-10_000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: true,
            maxSlippageBps: 30,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: bytes32(uint256(4)),
            marginMode: MarginMode.Isolated
        });
        p = MultiLegController.InitParams({
            owner: stratOwner,
            vaultManager: stratOwner,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: keccak256("ml-test"),
            adapterUrl: "https://a",
            executor: executor,
            legs: ls,
            bufferStalenessSeconds: 1 hours,
            minCycleNotionalUsd: 1,
            maxCycleNotionalUsd: 10,
            envelopeTtlSeconds: 1 hours,
            kellySigner: address(0),
            reserveDestinationRef: bytes32(uint256(9))
        });
    }

    function testCreateMultiLegClone() public {
        address clone = factory.createMultiLeg(_minMultiLeg(), keccak256("salt-1"));
        assertEq(MultiLegController(payable(clone)).legCount(), 2);
        assertEq(factory.predict(ArchetypeFactory.Archetype.MultiLeg, keccak256("salt-1")), clone);
    }

    function testCreatePtLoopClone() public {
        PtLoopController.InitParams memory p = PtLoopController.InitParams({
            owner: stratOwner,
            vaultManager: stratOwner,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: keccak256("pt-1"),
            adapterUrl: "https://a",
            executor: executor,
            cfg: PtLoopConfig({
                marketRef: bytes32(uint256(1)),
                maxSlippageBps: 30,
                maxLoops: 5,
                loopNotionalUsd: 1,
                bufferTargetUsd: 10,
                bufferMinUsd: 1,
                destinationRef: bytes32(uint256(2)),
                bufferStalenessSeconds: 1 hours,
                envelopeTtlSeconds: 1 hours
            }),
            topUpCommandType: CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER
        });
        address clone = factory.createPtLoop(p, keccak256("salt-3"));
        assertEq(PtLoopController(payable(clone)).owner(), stratOwner);
    }

    function testCollisionOnSameSalt() public {
        MultiLegController.InitParams memory p = _minMultiLeg();
        factory.createMultiLeg(p, keccak256("dup"));
        vm.expectRevert();
        factory.createMultiLeg(p, keccak256("dup"));
    }

    function testOnlyOwnerCanSetTemplate() public {
        vm.expectRevert(ArchetypeFactory.NotOwner.selector);
        factory.setTemplate(ArchetypeFactory.Archetype.MultiLeg, address(0x1234));

        vm.prank(factoryOwner);
        factory.setTemplate(ArchetypeFactory.Archetype.MultiLeg, address(0x1234));
        assertEq(factory.multiLegTemplate(), address(0x1234));
    }
}
