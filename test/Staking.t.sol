// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Staking} from "../src/Staking.sol";

contract StakingTest is Test {
    Staking public staking;
    address public stakingToken =
        address(0x0000000000000000000000000000000000000000);

    function setUp() public {
        // staking = new Staking(stakingToken);
    }

    function test_stake() public {
        // staking.stake(100 ether, 100 days);
        // assertEq(staking.balanceOf(address(this)), 100 ether);
    }
}
