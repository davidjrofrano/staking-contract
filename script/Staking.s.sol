// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {Staking} from "../src/Staking.sol";

contract StakingScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        /// Mint tokens to recipient
        address stakingToken = 0xC6bDf8654B85ABf446F83b5836935da5Be15EA48;
        // address recipient = 0x8599A6cab9617FFb12E6f11aD119caeE7323a2c4;
        // MockToken token = MockToken(stakingToken);
        // token.mint(recipient, 1e22);

        Staking staking = new Staking(stakingToken);
        staking.initialize();
        staking.startRound();

        vm.stopBroadcast();
    }
}
