// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {BaseCustodyFactory} from "../../src/factories/BaseCustodyFactory.sol";
import {VaultV2Factory} from "../../src/VaultV2Factory.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {BaseExecutionGateway} from "../../src/base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../../src/base/BaseStrategyModule.sol";
import {BaseOftSender} from "../../src/base/BaseOftSender.sol";
import {UniversalValuerOffchain} from "../../src/valuers/UniversalValuerOffchain.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {CrossVenueCommandLib} from "../../src/base/CrossVenueCommandLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BaseCustodyFactoryTest is Test {
    BaseCustodyFactory factory;
    VaultV2Factory vaultFactory;
    UniversalAdapterEscrowFactory adapterFactory;
    MockERC20 usdc;

    address vaultOwner = address(0xA11CE);
    address valuerOwner = address(0x7EE5); // adapter's Base EOA in production
    address signer1 = address(0x1111);
    address signer2 = address(0x2222);
    bytes32 constant STRAT_ID = keccak256("neko-strat-1");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();
        factory = new BaseCustodyFactory(address(vaultFactory), address(adapterFactory));
    }

    function _defaultParams() internal view returns (BaseCustodyFactory.DeployParams memory p) {
        address[] memory sigs = new address[](2);
        sigs[0] = signer1;
        sigs[1] = signer2;
        p = BaseCustodyFactory.DeployParams({
            vaultOwner: vaultOwner,
            valuerOwner: valuerOwner,
            asset: address(usdc),
            salt: keccak256("s1"),
            strategyId: STRAT_ID,
            strategyDailyLimit: 1_000_000e6,
            gatewaySigners: sigs,
            gatewayThreshold: 2,
            capPmTopUp: 1_000_000e6,
            capHlTopUp: 1_000_000e6,
            capRefillReserve: 10_000_000e6,
            dailyCap: 2_000_000e6,
            gatewayName: "NekoBaseGateway",
            gatewayVersion: "1"
        });
    }

    function testOneTxDeployWiresEverything() public {
        BaseCustodyFactory.DeployParams memory p = _defaultParams();
        BaseCustodyFactory.Deployment memory d = factory.deploy(p);

        assertTrue(d.vault != address(0));
        assertTrue(d.sleeve != address(0));
        assertTrue(d.valuer != address(0));
        assertTrue(d.gateway != address(0));
        assertTrue(d.module != address(0));
        assertTrue(d.oftSender != address(0));
        assertTrue(d.strategyAgent != address(0));

        // Gateway ownership + config.
        BaseExecutionGateway g = BaseExecutionGateway(d.gateway);
        assertEq(g.owner(), vaultOwner);
        assertTrue(g.isSigner(signer1));
        assertTrue(g.isSigner(signer2));
        assertEq(g.threshold(), 2);
        assertEq(g.commandCap(uint8(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER)), 1_000_000e6);
        assertEq(g.commandCap(uint8(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER)), 1_000_000e6);
        assertEq(g.commandCap(uint8(CrossVenueCommandLib.CommandType.REFILL_RESERVE)), 10_000_000e6);
        assertEq(g.dailyCap(), 2_000_000e6);

        // Module wired.
        BaseStrategyModule m = BaseStrategyModule(d.module);
        assertEq(m.owner(), vaultOwner);
        assertEq(m.gateway(), d.gateway);
        assertEq(m.oftSender(), d.oftSender);
        assertEq(m.vault(), d.vault);
        assertEq(m.bufferSource(), d.sleeve);
        assertEq(m.refillSource(), d.module);

        // OFT sender owned by vaultOwner, module authorized.
        BaseOftSender o = BaseOftSender(payable(d.oftSender));
        assertEq(o.owner(), vaultOwner);
        assertTrue(o.authorizedCallers(d.module));

        // Valuer owned by valuerOwner (adapter's Base EOA in production).
        UniversalValuerOffchain v = UniversalValuerOffchain(d.valuer);
        assertEq(v.owner(), valuerOwner);
        assertEq(v.asset(), address(usdc));

        // Vault registered the sleeve as an adapter, vault ownership transferred.
        IVaultV2 vault = IVaultV2(d.vault);
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.curator(), vaultOwner);
        assertTrue(vault.isAdapter(d.sleeve));

        // Sleeve has the strategy activated with the no-op agent.
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(d.sleeve));
        (address agent,,,,, bool active) = sleeve.strategies(STRAT_ID);
        assertEq(agent, d.strategyAgent);
        assertTrue(active);
    }

    function testRejectsZeroAddresses() public {
        BaseCustodyFactory.DeployParams memory p = _defaultParams();
        p.vaultOwner = address(0);
        vm.expectRevert(BaseCustodyFactory.InvalidAddress.selector);
        factory.deploy(p);
    }

    function testRejectsZeroValuerOwner() public {
        BaseCustodyFactory.DeployParams memory p = _defaultParams();
        p.valuerOwner = address(0);
        vm.expectRevert(BaseCustodyFactory.InvalidAddress.selector);
        factory.deploy(p);
    }

    function testRejectsBadThreshold() public {
        BaseCustodyFactory.DeployParams memory p = _defaultParams();
        p.gatewayThreshold = 5;
        vm.expectRevert(BaseCustodyFactory.InvalidConfig.selector);
        factory.deploy(p);
    }
}
