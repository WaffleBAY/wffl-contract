// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWLD
/// @notice Mock WLD token for testnet deployment and unit tests
contract MockWLD is ERC20 {
    constructor() ERC20("Mock Worldcoin", "WLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
