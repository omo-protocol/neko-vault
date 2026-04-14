// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

library ContractCodeCheckerLib {
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
}
