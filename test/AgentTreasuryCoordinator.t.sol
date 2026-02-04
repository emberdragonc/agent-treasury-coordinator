// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {AgentTreasuryCoordinator} from "../src/AgentTreasuryCoordinator.sol";

// Mock USDC for testing
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract AgentTreasuryCoordinatorTest is Test {
    AgentTreasuryCoordinator public coordinator;
    MockUSDC public usdc;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    uint256 public constant INITIAL_BALANCE = 10000e6; // 10,000 USDC

    function setUp() public {
        usdc = new MockUSDC();
        coordinator = new AgentTreasuryCoordinator(address(usdc));

        // Fund test accounts
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
    }

    // ============ createEscrow Tests ============

    function test_CreateEscrow() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        (address depositor, address beneficiary, uint256 amount, uint256 deadline, bool released, bool refunded) = coordinator.getEscrow(escrowId);
        
        assertEq(depositor, alice);
        assertEq(beneficiary, bob);
        assertGt(amount, 0);
        assertEq(deadline, block.timestamp + 1 days);
        assertFalse(released);
        assertFalse(refunded);
        vm.stopPrank();
    }

    function test_CreateEscrow_CollectsFee() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        (, , uint256 amount, , , ) = coordinator.getEscrow(escrowId);
        
        // 0.5% fee means 995 USDC net
        assertEq(amount, 995e6);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateEscrow_ZeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        vm.expectRevert(AgentTreasuryCoordinator.InvalidAmount.selector);
        coordinator.createEscrow(bob, 0, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateEscrow_PastDeadline() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        vm.expectRevert(AgentTreasuryCoordinator.InvalidDeadline.selector);
        coordinator.createEscrow(bob, 1000e6, block.timestamp - 1);
        vm.stopPrank();
    }

    // ============ releaseEscrow Tests ============

    function test_ReleaseEscrow() public {
        // Create escrow
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        
        // Release
        coordinator.releaseEscrow(escrowId);
        
        (, , , , bool released, ) = coordinator.getEscrow(escrowId);
        assertTrue(released);
        
        // Bob should have received the funds
        assertGt(usdc.balanceOf(bob), bobBalanceBefore);
        vm.stopPrank();
    }

    function test_ReleaseEscrow_IncreasesReputation() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        uint256 aliceRepBefore = coordinator.reputation(alice);
        uint256 bobRepBefore = coordinator.reputation(bob);
        
        coordinator.releaseEscrow(escrowId);
        
        assertGt(coordinator.reputation(alice), aliceRepBefore);
        assertGt(coordinator.reputation(bob), bobRepBefore);
        vm.stopPrank();
    }

    function test_RevertWhen_ReleaseEscrow_NotDepositor() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(AgentTreasuryCoordinator.NotAuthorized.selector);
        coordinator.releaseEscrow(escrowId);
    }

    // ============ refundEscrow Tests ============

    function test_RefundEscrow() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        // Warp past deadline
        vm.warp(block.timestamp + 2 days);
        
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        
        coordinator.refundEscrow(escrowId);
        
        (, , , , , bool refunded) = coordinator.getEscrow(escrowId);
        assertTrue(refunded);
        assertGt(usdc.balanceOf(alice), aliceBalanceBefore);
        vm.stopPrank();
    }

    function test_RevertWhen_RefundEscrow_BeforeDeadline() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 1000e6);
        uint256 escrowId = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        // Try to refund before deadline
        vm.expectRevert(AgentTreasuryCoordinator.DeadlineNotPassed.selector);
        coordinator.refundEscrow(escrowId);
        vm.stopPrank();
    }

    // ============ batchRelease Tests ============

    function test_BatchRelease() public {
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 3000e6);
        
        uint256[] memory escrowIds = new uint256[](3);
        escrowIds[0] = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        escrowIds[1] = coordinator.createEscrow(charlie, 1000e6, block.timestamp + 1 days);
        escrowIds[2] = coordinator.createEscrow(bob, 1000e6, block.timestamp + 1 days);
        
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 charlieBalanceBefore = usdc.balanceOf(charlie);
        
        coordinator.batchRelease(escrowIds);
        
        // Check all released
        for (uint256 i = 0; i < escrowIds.length; i++) {
            (, , , , bool released, ) = coordinator.getEscrow(escrowIds[i]);
            assertTrue(released);
        }
        
        assertGt(usdc.balanceOf(bob), bobBalanceBefore);
        assertGt(usdc.balanceOf(charlie), charlieBalanceBefore);
        vm.stopPrank();
    }

    // ============ Fee Calculation Tests ============

    function test_FeeDecreasesWithReputation() public {
        // Initial fee (no reputation)
        uint256 initialFee = coordinator.calculateFee(alice, 1000e6);
        
        // Build reputation through escrows
        vm.startPrank(alice);
        usdc.approve(address(coordinator), 5000e6);
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 escrowId = coordinator.createEscrow(bob, 100e6, block.timestamp + 1 days);
            coordinator.releaseEscrow(escrowId);
        }
        vm.stopPrank();
        
        // Fee should be lower now
        uint256 laterFee = coordinator.calculateFee(alice, 1000e6);
        assertLt(laterFee, initialFee);
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreateEscrow(uint256 amount, uint256 deadlineOffset) public {
        // Bound inputs
        amount = bound(amount, 1e6, 1000000e6); // 1 to 1M USDC
        deadlineOffset = bound(deadlineOffset, 1, 365 days);
        
        usdc.mint(alice, amount);
        
        vm.startPrank(alice);
        usdc.approve(address(coordinator), amount);
        
        uint256 escrowId = coordinator.createEscrow(bob, amount, block.timestamp + deadlineOffset);
        
        (address depositor, , , , , ) = coordinator.getEscrow(escrowId);
        assertEq(depositor, alice);
        vm.stopPrank();
    }

    function testFuzz_BatchRelease(uint8 numEscrows) public {
        numEscrows = uint8(bound(numEscrows, 1, 20));
        
        uint256 totalAmount = uint256(numEscrows) * 100e6;
        usdc.mint(alice, totalAmount);
        
        vm.startPrank(alice);
        usdc.approve(address(coordinator), totalAmount);
        
        uint256[] memory escrowIds = new uint256[](numEscrows);
        for (uint256 i = 0; i < numEscrows; i++) {
            escrowIds[i] = coordinator.createEscrow(bob, 100e6, block.timestamp + 1 days);
        }
        
        coordinator.batchRelease(escrowIds);
        
        for (uint256 i = 0; i < numEscrows; i++) {
            (, , , , bool released, ) = coordinator.getEscrow(escrowIds[i]);
            assertTrue(released);
        }
        vm.stopPrank();
    }
}
