// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MultiLegController} from "../controllers/cross_venue/MultiLegController.sol";
import {PtLoopController} from "../controllers/cross_venue/PtLoopController.sol";

/// @title ArchetypeFactory
/// @notice Deploys EIP-1167 clones of Ritual-side controllers by archetype. Stores template
///         addresses (one deploy per chain) and produces per-strategy clones. All clones share
///         the same Base gateway + NAV valuer + adapter signer.
contract ArchetypeFactory {
    enum Archetype {
        MultiLeg,
        PtLoop
    }

    error NotOwner();
    error InvalidArchetype();

    event TemplateSet(Archetype indexed archetype, address template);
    event ArchetypeCloned(
        Archetype indexed archetype, address indexed owner, address indexed clone, bytes32 strategyId
    );

    address public owner;
    address public multiLegTemplate;
    address public ptLoopTemplate;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ Factory admin (can rotate templates).
    /// @param multiLegTemplate_ Pre-deployed `MultiLegController` to clone per-strategy.
    /// @param ptLoopTemplate_   Pre-deployed `PtLoopController` to clone per-strategy.
    /// @dev Templates are passed in pre-deployed so the factory's own initcode stays under the
    ///      EIP-3860 49 KB limit. Deploy order is: (1) templates, (2) this factory.
    constructor(address owner_, address multiLegTemplate_, address ptLoopTemplate_) {
        owner = owner_;
        multiLegTemplate = multiLegTemplate_;
        ptLoopTemplate = ptLoopTemplate_;
        emit TemplateSet(Archetype.MultiLeg, multiLegTemplate_);
        emit TemplateSet(Archetype.PtLoop, ptLoopTemplate_);
    }

    function setTemplate(Archetype a, address template) external onlyOwner {
        if (a == Archetype.MultiLeg) multiLegTemplate = template;
        else if (a == Archetype.PtLoop) ptLoopTemplate = template;
        else revert InvalidArchetype();
        emit TemplateSet(a, template);
    }

    function createMultiLeg(MultiLegController.InitParams calldata p, bytes32 salt) external returns (address clone) {
        clone = Clones.cloneDeterministic(multiLegTemplate, salt);
        MultiLegController(payable(clone)).initialize(p);
        emit ArchetypeCloned(Archetype.MultiLeg, p.owner, clone, p.strategyId);
    }

    function createPtLoop(PtLoopController.InitParams calldata p, bytes32 salt) external returns (address clone) {
        clone = Clones.cloneDeterministic(ptLoopTemplate, salt);
        PtLoopController(payable(clone)).initialize(p);
        emit ArchetypeCloned(Archetype.PtLoop, p.owner, clone, p.strategyId);
    }

    function predict(Archetype a, bytes32 salt) external view returns (address) {
        address t = a == Archetype.MultiLeg ? multiLegTemplate : ptLoopTemplate;
        return Clones.predictDeterministicAddress(t, salt, address(this));
    }
}
