// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {VaultV2} from "../../src/VaultV2.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFT} from "../../src/ovault/ShareOFT.sol";
import {ShareOFTAdapter} from "../../src/ovault/ShareOFTAdapter.sol";
import {VaultComposerSync} from "../../src/ovault/VaultComposerSync.sol";

/// @title OVaultDeployment Test
/// @notice Tests basic deployment and setup of OVault infrastructure
/// @dev This test verifies that all contracts can be deployed and basic properties work
contract OVaultDeploymentTest is Test {
    address owner = address(0x1);
    address lzEndpoint = address(0x1a44076050125825900e736c501f859c50fE728c); // Mock endpoint

    AssetOFT assetOFT;
    VaultV2 vault;
    ShareOFTAdapter shareAdapter;
    VaultComposerSync composer;
    ShareOFT spokeShareOFT;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy hub infrastructure
        assetOFT = new AssetOFT("USD Tether", "USDT", lzEndpoint, owner);
        vault = new VaultV2(owner, address(assetOFT));
        vault.setName("Morpho USDT Vault");
        vault.setSymbol("mUSDT");

        shareAdapter = new ShareOFTAdapter(address(vault), lzEndpoint, owner);
        composer = new VaultComposerSync(
            address(vault),
            address(assetOFT),
            address(shareAdapter)
        );

        // Deploy spoke infrastructure
        spokeShareOFT = new ShareOFT(
            "Morpho USDT Vault Shares",
            "mUSDT",
            lzEndpoint,
            owner
        );

        vm.stopPrank();
    }

    function testDeployment() public view {
        // Verify AssetOFT
        assertEq(assetOFT.name(), "USD Tether");
        assertEq(assetOFT.symbol(), "USDT");
        assertEq(assetOFT.owner(), owner);

        // Verify VaultV2
        assertEq(vault.owner(), owner);
        assertEq(vault.asset(), address(assetOFT));
        assertEq(vault.name(), "Morpho USDT Vault");
        assertEq(vault.symbol(), "mUSDT");

        // Verify ShareOFTAdapter
        assertEq(shareAdapter.token(), address(vault));
        assertEq(shareAdapter.owner(), owner);

        // Verify VaultComposerSync
        assertEq(address(composer.VAULT()), address(vault));
        assertEq(composer.ASSET_OFT(), address(assetOFT));
        assertEq(composer.SHARE_OFT(), address(shareAdapter));

        // Verify Spoke ShareOFT
        assertEq(spokeShareOFT.name(), "Morpho USDT Vault Shares");
        assertEq(spokeShareOFT.symbol(), "mUSDT");
        assertEq(spokeShareOFT.owner(), owner);
    }

    function testAssetMinting() public {
        vm.prank(owner);
        assetOFT.mint(address(this), 1000e6); // Mint 1000 USDT

        assertEq(assetOFT.balanceOf(address(this)), 1000e6);
    }

    function testVaultDeposit() public {
        // Mint assets
        vm.prank(owner);
        assetOFT.mint(address(this), 1000e6);

        // Approve vault
        assetOFT.approve(address(vault), 1000e6);

        // Deposit
        uint256 shares = vault.deposit(1000e6, address(this));

        assertGt(shares, 0);
        assertEq(vault.balanceOf(address(this)), shares);
    }

    function testShareAdapterLockbox() public {
        // Mint assets and deposit to vault
        vm.prank(owner);
        assetOFT.mint(address(this), 1000e6);
        assetOFT.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, address(this));

        // Approve share adapter
        vault.approve(address(shareAdapter), shares);

        // The share adapter should be able to receive shares
        vault.transfer(address(shareAdapter), shares);

        assertEq(vault.balanceOf(address(shareAdapter)), shares);
        assertEq(vault.balanceOf(address(this)), 0);
    }

    function testComposerAccess() public view {
        // Verify composer has correct vault reference
        assertEq(address(composer.VAULT()), address(vault));
        assertEq(composer.ASSET_OFT(), address(assetOFT));
        assertEq(composer.SHARE_OFT(), address(shareAdapter));
    }
}
