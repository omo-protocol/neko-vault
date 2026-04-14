// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

library ContractCodeCheckerLib {
    bytes10 private constant EIP1167_PREFIX = 0x363d3d373d3d3d363d73;
    bytes15 private constant EIP1167_SUFFIX = 0x5af43d82803e903d91602b57fd5bf3;

    function containsDelegatecallOpcode(address target) internal view returns (bool) {
        uint256 size = target.code.length;
        bytes memory code = new bytes(size);
        assembly {
            extcodecopy(target, add(code, 0x20), 0, size)
        }

        for (uint256 i; i < size; i++) {
            uint8 opcode = uint8(code[i]);
            if (opcode == 0xf4) return true;
            if (opcode >= 0x60 && opcode <= 0x7f) {
                unchecked {
                    i += opcode - 0x5f;
                }
            }
        }

        return false;
    }

    function containsPushedSelector(address target, bytes4 selector) internal view returns (bool) {
        bytes memory code = target.code;
        uint256 size = code.length;

        for (uint256 i; i < size; i++) {
            uint8 opcode = uint8(code[i]);
            if (opcode == 0x63 && i + 4 < size) {
                bytes4 pushedSelector =
                    bytes4(bytes.concat(code[i + 1], code[i + 2], code[i + 3], code[i + 4]));
                if (pushedSelector == selector) return true;
            }
            if (opcode >= 0x60 && opcode <= 0x7f) {
                unchecked {
                    i += opcode - 0x5f;
                }
            }
        }

        return false;
    }

    function cloneImplementation(address target) internal view returns (address implementation) {
        if (target.code.length != 45) return address(0);

        bytes memory code = new bytes(45);
        assembly {
            extcodecopy(target, add(code, 0x20), 0, 45)
            implementation := shr(96, mload(add(code, 0x2a)))
        }

        bytes10 prefix;
        bytes15 suffix;
        assembly {
            prefix := mload(add(code, 0x20))
            suffix := mload(add(code, 0x3e))
        }
        if (prefix != EIP1167_PREFIX || suffix != EIP1167_SUFFIX) {
            return address(0);
        }
    }
}
