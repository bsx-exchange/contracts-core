//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract ERC1271 is IERC1271 {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    /// @notice Verifies that the signer is the owner of the signing contract.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        if (ECDSA.recover(hash, signature) == owner) {
            return 0x1626ba7e;
        } else {
            return 0xffffffff;
        }
    }
}
