// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {Staking} from "../src/Staking.sol";

contract StakingScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address stakingToken = vm.envAddress("STAKING_TOKEN");

        Staking staking = new Staking(stakingToken);
        staking.startRound();

        console.log("Staking deployed at:", address(staking));

        vm.stopBroadcast();
    }
}
