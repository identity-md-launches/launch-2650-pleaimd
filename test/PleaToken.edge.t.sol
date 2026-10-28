// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Stands in for the launch factory in one transaction: deploys the token and performs the launch's
///         exact-amount flows (swarm share to the distributor, pool seed to the PoolManager, remainder onward).
contract LaunchFlowProbe {
    function launch(address distributor, address poolManager, address requester, uint256 poolBps)
        external
        returns (PleaToken token)
    {
        token = new PleaToken();
        uint256 supply = token.totalSupply();
        uint256 swarm = supply / 10;
        uint256 pool = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm");
        require(token.transfer(poolManager, pool), "pool");
        require(token.transfer(requester, token.balanceOf(address(this))), "remainder");
    }
}

/// @notice Edge inputs and failure paths beyond the main suite: self-dealing, ordering of checks, zero amounts,
///         the whole supply, the maximum allowance, and atomicity of reverted calls.
contract PleaTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    PleaToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Interface
    // ------------------------------------------------------------------------------------------------------------

    function test_standardSelectors() public view {
        assertEq(token.transfer.selector, bytes4(0xa9059cbb));
        assertEq(token.transferFrom.selector, bytes4(0x23b872dd));
        assertEq(token.approve.selector, bytes4(0x095ea7b3));
        assertEq(token.balanceOf.selector, bytes4(0x70a08231));
        assertEq(token.allowance.selector, bytes4(0xdd62ed3e));
        assertEq(token.totalSupply.selector, bytes4(0x18160ddd));
    }

    function test_RevertWhen_calledWithUnknownSelectorAndEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_RevertWhen_etherSentWithTransfer() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(PleaToken.transfer, (bob, 1)));
        assertFalse(ok, "non-payable functions reject ether");
        assertEq(token.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Self-dealing
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Holding tokens does not grant an allowance over them: transferFrom on your own balance needs one.
    function test_RevertWhen_transferFromSelfWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, alice, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromSelfWithSelfAllowance() public {
        vm.startPrank(alice);
        token.approve(alice, 10e18);
        assertTrue(token.transferFrom(alice, bob, 4e18));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 6e18);
        assertEq(token.balanceOf(bob), 4e18);
    }

    /// @dev Moving tokens back to the same account spends the allowance but leaves the balance where it was.
    function test_transferFromToSameAccountSpendsAllowanceKeepsBalance() public {
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, alice, 7e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.allowance(alice, bob), 3e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_transferToSelfExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1));
        token.transfer(alice, 1_000e18 + 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Order of checks and atomicity
    // ------------------------------------------------------------------------------------------------------------

    /// @dev With neither allowance nor balance, the allowance is reported first.
    function test_RevertWhen_transferFromLacksBothAllowanceAndBalance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, bob, alice, 0, 2_000e18));
        token.transferFrom(alice, deployer, 2_000e18);
    }

    /// @dev A transferFrom that fails on the balance does not spend the allowance.
    function test_failedTransferFromLeavesAllowanceAndBalances() public {
        vm.prank(alice);
        token.approve(bob, 5_000e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 1_000e18, 2_000e18));
        token.transferFrom(alice, bob, 2_000e18);
        assertEq(token.allowance(alice, bob), 5_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev A transferFrom to the zero address fails after the allowance check and leaves it unspent.
    function test_failedTransferFromToZeroLeavesAllowance() public {
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.prank(bob);
        vm.expectRevert(PleaToken.TransferToZeroAddress.selector);
        token.transferFrom(alice, address(0), 5e18);
        assertEq(token.allowance(alice, bob), 5e18);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_RevertWhen_transferToZeroEvenWithZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(PleaToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 0);
    }

    function test_RevertWhen_burnExceedsBalanceByOneWei() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1));
        token.burn(1_000e18 + 1);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Burning cannot reach another holder's balance, whatever allowance the caller holds.
    function test_burnOnlyTouchesCallersBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, bob, 0, 1));
        token.burn(1);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Allowance edges
    // ------------------------------------------------------------------------------------------------------------

    function test_RevertWhen_increaseAllowanceForZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(PleaToken.ApproveToZeroAddress.selector);
        token.increaseAllowance(address(0), 1);
    }

    function test_RevertWhen_decreaseAllowanceForZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(PleaToken.ApproveToZeroAddress.selector);
        token.decreaseAllowance(address(0), 0);
    }

    function test_decreaseAllowanceToExactlyZero() public {
        vm.startPrank(alice);
        token.approve(bob, 9);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 0);
        assertTrue(token.decreaseAllowance(bob, 9));
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
    }

    /// @dev An unlimited allowance stays unlimited and emits no Approval when spent: only the Transfer is logged.
    function test_unlimitedAllowanceSpendEmitsOnlyTransfer() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, bob, 1_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    /// @dev Allowance one below unlimited is finite and decreases.
    function test_allowanceMaxMinusOneIsFinite() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max - 2);
    }

    /// @dev An unlimited allowance still cannot move more than the owner holds.
    function test_RevertWhen_unlimitedAllowanceExceedsBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1));
        token.transferFrom(alice, bob, 1_000e18 + 1);
    }

    /// @dev Allowances are per (owner, spender): one spender's grant is not another's.
    function test_RevertWhen_spendingAnotherSpendersAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, deployer, alice, 0, 1));
        token.transferFrom(alice, deployer, 1);
    }

    /// @dev Reapproving after a spend replaces, not adds to, the remainder.
    function test_approveAfterPartialSpendReplaces() public {
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        token.transferFrom(alice, bob, 4e18);
        vm.prank(alice);
        token.approve(bob, 1e18);
        assertEq(token.allowance(alice, bob), 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, bob, alice, 1e18, 2e18));
        token.transferFrom(alice, bob, 2e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Whole supply and zero amounts
    // ------------------------------------------------------------------------------------------------------------

    function test_burnWholeSupply() public {
        vm.prank(alice);
        token.transfer(deployer, 1_000e18);
        vm.prank(deployer);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(deployer), 0);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_burnZero() public {
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Transfer(bob, address(0), 0);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroAmountWithoutAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    /// @dev The zero address holds nothing and grants nothing: nothing can be pulled out of it.
    function test_RevertWhen_pullingFromZeroAddress() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, bob, address(0), 0, 1));
        token.transferFrom(address(0), bob, 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Launch flows
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The launch's own transfers (factory to distributor and PoolManager, distributor to claimant) move
    ///      exactly what they say: no fee, no burn, no exemption needed.
    function test_launchFlowsAreExact() public {
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address requester = makeAddr("requester");
        LaunchFlowProbe probe = new LaunchFlowProbe();
        PleaToken launched = probe.launch(distributor, poolManager, requester, 6_000);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(poolManager), (SUPPLY * 6_000) / 10_000);
        assertEq(launched.balanceOf(requester), SUPPLY - SUPPLY / 10 - (SUPPLY * 6_000) / 10_000);
        assertEq(launched.balanceOf(address(probe)), 0);

        vm.prank(distributor);
        launched.transfer(alice, SUPPLY / 10);
        assertEq(launched.balanceOf(alice), SUPPLY / 10);
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferBetweenArbitraryHoldersConserves(address from, address to, uint256 seed, uint256 amount)
        public
    {
        from = address(uint160(bound(uint160(from), 1, type(uint160).max)));
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        seed = bound(seed, 0, SUPPLY - 1_000e18);
        vm.prank(deployer);
        token.transfer(from, seed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, fromBefore);
        vm.prank(from);
        token.transfer(to, amount);
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_decreaseAllowance(uint256 start, uint256 sub) public {
        vm.startPrank(alice);
        token.approve(bob, start);
        if (sub > start) {
            vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, bob, alice, start, sub));
            token.decreaseAllowance(bob, sub);
            assertEq(token.allowance(alice, bob), start);
        } else {
            token.decreaseAllowance(bob, sub);
            assertEq(token.allowance(alice, bob), start - sub);
        }
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_increaseAllowanceOverflowReverts(uint256 start, uint256 added) public {
        start = bound(start, 1, type(uint256).max);
        added = bound(added, type(uint256).max - start + 1, type(uint256).max);
        vm.startPrank(alice);
        token.approve(bob, start);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        token.increaseAllowance(bob, added);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), start);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unlimitedAllowanceNeverDecreases(uint256 a, uint256 b) public {
        a = bound(a, 0, 1_000e18);
        b = bound(b, 0, 1_000e18 - a);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.startPrank(bob);
        token.transferFrom(alice, bob, a);
        token.transferFrom(alice, deployer, b);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(alice), 1_000e18 - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotMoveHolderFunds(address stranger, uint256 amount) public {
        vm.assume(stranger != alice);
        amount = bound(amount, 1, 1_000e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, stranger, alice, 0, amount));
        token.transferFrom(alice, stranger, amount);
        assertEq(token.balanceOf(alice), 1_000e18);
    }
}
