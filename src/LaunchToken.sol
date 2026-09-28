// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token for the StakeLaunch test launch.
/// @dev The launch factory receives the entire supply. There are no administrative entry points.
contract LaunchToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("StakeLaunch", "STL") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
