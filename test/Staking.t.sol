// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Staking} from "../src/Staking.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract StakingTest is Test {
    Staking public staking;
    address public stakingAddress;
    MockToken public stakingToken;
    address public stakingTokenAddress;

    address public rewardCharger = makeAddr("rewardCharger");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant STAKE_AMOUNT = 10 ether;
    uint256 constant STAKE_DURATION_1 = 50 days;
    uint256 constant STAKE_DURATION_2 = 100 days;
    uint256 constant STAKE_DURATION_3 = 200 days;

    /* ============ SETUP FUNCTIONS =========== */

    function setUp() public {
        stakingToken = new MockToken();
        staking = new Staking(address(stakingToken));
        stakingAddress = address(staking);
        stakingTokenAddress = address(stakingToken);
    }

    function setupUsers() public {
        deal(stakingTokenAddress, alice, STAKE_AMOUNT);
        deal(stakingTokenAddress, bob, STAKE_AMOUNT);
        deal(stakingTokenAddress, charlie, STAKE_AMOUNT);

        stakingToken.approve(alice, stakingAddress, type(uint256).max);
        stakingToken.approve(bob, stakingAddress, type(uint256).max);
        stakingToken.approve(charlie, stakingAddress, type(uint256).max);
    }

    /* ====== RESTRICTED FUNCTIONS TESTS ====== */

    function test_update_reward_charger() public {
        assertEq(staking.rewardCharger(), address(this));
        vm.expectEmit(true, false, false, false);
        emit Staking.RewardChargerUpdated(rewardCharger);
        staking.updateRewardCharger(rewardCharger);
        assertEq(staking.rewardCharger(), rewardCharger);

        vm.startPrank(rewardCharger);
        vm.expectRevert();
        staking.updateRewardCharger(alice);
        vm.stopPrank();

        vm.expectRevert(Staking.ZeroAddress.selector);
        staking.updateRewardCharger(address(0));
    }

    function test_charge_reward() public {
        staking.updateRewardCharger(rewardCharger);
        deal(stakingTokenAddress, rewardCharger, STAKE_AMOUNT);

        vm.startPrank(rewardCharger);
        stakingToken.approve(stakingAddress, STAKE_AMOUNT);
        vm.expectEmit(false, false, false, true);
        emit Staking.RewardCharged(STAKE_AMOUNT);
        staking.chargeReward(STAKE_AMOUNT);
        assertEq(staking.pendingReward(), STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(alice);
        stakingToken.approve(stakingAddress, STAKE_AMOUNT);
        vm.expectRevert(Staking.NotRewardCharger.selector);
        staking.chargeReward(STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(rewardCharger);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.chargeReward(0);
        vm.stopPrank();
    }

    function test_start_round() public {
        uint256 roundCounter = staking.roundCounter();
        vm.expectEmit(true, false, false, false);
        emit Staking.RoundStarted(1);
        staking.startRound();

        assertEq(staking.roundCounter(), roundCounter + 1);
        assertEq(staking.pendingReward(), 0);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.roundEndTime(), block.timestamp + 1000 days);

        vm.startPrank(alice);
        vm.expectRevert();
        staking.startRound();
        vm.stopPrank();

        staking.updateRewardCharger(rewardCharger);
        deal(stakingTokenAddress, rewardCharger, STAKE_AMOUNT);
        vm.startPrank(rewardCharger);
        stakingToken.approve(stakingAddress, STAKE_AMOUNT);
        staking.chargeReward(STAKE_AMOUNT);
        vm.stopPrank();

        vm.expectRevert(Staking.RoundInProgress.selector);
        staking.startRound();

        vm.warp(block.timestamp + 1001 days);

        staking.startRound();
        assertEq(staking.roundCounter(), 3);
    }

    function test_charge_reward_when_round_in_progress() public {
        staking.updateRewardCharger(rewardCharger);
        deal(stakingTokenAddress, rewardCharger, STAKE_AMOUNT);
        vm.startPrank(rewardCharger);
        stakingToken.approve(stakingAddress, STAKE_AMOUNT);
        staking.chargeReward(STAKE_AMOUNT / 2);
        assertEq(staking.pendingReward(), STAKE_AMOUNT / 2);
        vm.stopPrank();

        staking.startRound();
        assertEq(staking.pendingReward(), 0);
        assertEq(staking.rewardRate(), STAKE_AMOUNT / 2 / 1000 days);
        assertEq(staking.isRoundInProgress(), true);

        vm.startPrank(rewardCharger);
        staking.chargeReward(STAKE_AMOUNT / 2);
        vm.stopPrank();

        assertEq(staking.pendingReward(), 0);
        assertEq(staking.rewardRate(), STAKE_AMOUNT / 1000 days);
        assertEq(staking.isRoundInProgress(), true);
    }

    function test_recover_token() public {
        MockToken mockToken1 = new MockToken();
        deal(address(mockToken1), stakingAddress, STAKE_AMOUNT);

        MockToken mockToken2 = new MockToken();
        deal(address(mockToken2), stakingAddress, STAKE_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Staking.Recovered(address(mockToken1), STAKE_AMOUNT);
        staking.recoverERC20(address(mockToken1), STAKE_AMOUNT);
        assertEq(mockToken1.balanceOf(address(staking)), 0);
        assertEq(mockToken1.balanceOf(address(this)), STAKE_AMOUNT);

        staking.recoverERC20(address(mockToken2), STAKE_AMOUNT);
        assertEq(mockToken2.balanceOf(address(staking)), 0);
        assertEq(mockToken2.balanceOf(address(this)), STAKE_AMOUNT);

        vm.startPrank(alice);
        vm.expectRevert();
        staking.recoverERC20(address(mockToken1), STAKE_AMOUNT);
        vm.stopPrank();

        deal(stakingTokenAddress, stakingAddress, STAKE_AMOUNT);
        vm.expectRevert(Staking.CannotRecoverStakingToken.selector);
        staking.recoverERC20(stakingTokenAddress, STAKE_AMOUNT);
    }

    /* ======= MUTATIVE FUNCTIONS TESTS ======= */

    /**
     * alice stakes day {0} for {50} days and unstaked at day {196}
     * bob stakes day {5} for {100} days and unstaked at day {96}
     * charlie stakes day {55} for {200} days and unstaked at day {196}
     *
     * alice should pay late penalty |=> (196 - 50 - 14) / 700 = 132 / 700
     * bob should pay early penalty |=> (max(100/2, 90)) / (96 - 5) = 90 / 91
     * charlie should pay early penalty |=> (max(200/2, 90)) / (196 - 55) = 100 / 141
     */
    function test_stake_and_unstake() public {
        setupUsers();
        staking.startRound();

        vm.startPrank(alice);
        uint256 aliceStakeId = staking.stake(STAKE_AMOUNT, STAKE_DURATION_1);
        vm.stopPrank();

        Staking.StakeInfo memory info = staking.getStakeInfo(aliceStakeId);
        assertEq(info.amount, STAKE_AMOUNT);
        assertEq(info.duration, STAKE_DURATION_1);
        assertEq(info.rewardPerToken, 0);
        assertEq(info.reward, 0);
        assertEq(info.staker, alice);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);

        vm.warp(block.timestamp + 5 days);

        vm.startPrank(bob);
        uint256 bobStakeId = staking.stake(STAKE_AMOUNT, STAKE_DURATION_2);
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 50 days);

        vm.startPrank(charlie);
        uint256 charlieStakeId = staking.stake(STAKE_AMOUNT, STAKE_DURATION_3);
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 3);
        vm.stopPrank();

        vm.warp(block.timestamp + 41 days);

        uint256 bobAmount = staking.earned(bobStakeId) + STAKE_AMOUNT;
        uint256 bobPenalty = (bobAmount * 90) / 91;
        uint256 bobBalance = stakingToken.balanceOf(bob);
        vm.startPrank(bob);
        staking.unstake(bobStakeId);
        assertEq(
            stakingToken.balanceOf(bob) - bobBalance,
            bobAmount - bobPenalty
        );
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 100 days);

        uint256 charlieAmount = staking.earned(charlieStakeId) + STAKE_AMOUNT;
        uint256 charliePenalty = (charlieAmount * 100) / 141;
        uint256 charlieBalance = stakingToken.balanceOf(charlie);
        vm.startPrank(charlie);
        staking.unstake(charlieStakeId);
        assertEq(
            stakingToken.balanceOf(charlie) - charlieBalance,
            charlieAmount - charliePenalty
        );
        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        vm.stopPrank();

        uint256 aliceAmount = staking.earned(aliceStakeId) + STAKE_AMOUNT;
        uint256 alicePenalty = (aliceAmount * 132) / 700;
        uint256 aliceBalance = stakingToken.balanceOf(alice);
        vm.startPrank(alice);
        staking.unstake(aliceStakeId);
        assertEq(
            stakingToken.balanceOf(alice) - aliceBalance,
            aliceAmount - alicePenalty
        );
        assertEq(staking.totalStaked(), 0);
        vm.stopPrank();
    }
}
