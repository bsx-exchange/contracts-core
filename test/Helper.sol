// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {VmSafe} from "forge-std/Vm.sol";

library Helper {
    VmSafe private constant VM = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev add this to exclude from the coverage report
    function test() public pure returns (bool) {
        return true;
    }

    function toArray(bytes memory data) internal pure returns (bytes[] memory) {
        bytes[] memory array = new bytes[](1);
        array[0] = data;
        return array;
    }

    function convertTo18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** 18 / 10 ** decimals;
    }

    function convertFrom18D(uint256 x, uint8 decimals) internal pure returns (uint256) {
        return x * 10 ** decimals / 10 ** 18;
    }

    function signTypedDataHash(IERC5267 _contract, uint256 privateKey, bytes32 structHash)
        public
        view
        returns (bytes memory signature)
    {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            _contract.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
