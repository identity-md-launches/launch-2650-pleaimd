// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Stands in for the project factory: deploys the token from inside a contract so the test can check that
///         the supply lands on `msg.sender` of the constructor, not on the EOA that started the transaction.
contract DeployerProbe {
    PleaToken public token;

    function deploy() external returns (PleaToken) {
        token = new PleaToken();
        return token;
    }
}

contract PleaTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    PleaToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Metadata and initial supply
    // ------------------------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "pleaimd");
        assertEq(token.symbol(), "PLEA");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new PleaToken();
    }

    /// @dev When a contract (the factory) deploys the token, the supply is that contract's, not tx.origin's.
    function test_supplyGoesToTheDeployingContractNotTxOrigin() public {
        DeployerProbe factory = new DeployerProbe();
        vm.prank(alice, alice);
        PleaToken deployed = factory.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
    }

    function test_noConstructorArguments() public pure {
        // The launch manifest supplies no constructor arguments: the creation code is the whole init code.
        assertGt(type(PleaToken).creationCode.length, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------------------------------------------------

    function test_transfer() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 100e18);
        assertTrue(token.transfer(alice, 100e18));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmount() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferHasNoFee() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(bob, 10e18 + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(PleaToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // approve / allowance
    // ------------------------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 42e18);
        assertTrue(token.approve(bob, 42e18));
        assertEq(token.allowance(alice, bob), 42e18);
    }

    function test_approveOverwrites() public {
        vm.startPrank(alice);
        token.approve(bob, 10);
        token.approve(bob, 3);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 3);
    }

    function test_RevertWhen_approveZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(PleaToken.ApproveToZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(alice);
        assertTrue(token.increaseAllowance(bob, 10));
        assertTrue(token.increaseAllowance(bob, 5));
        assertEq(token.allowance(alice, bob), 15);
        assertTrue(token.decreaseAllowance(bob, 4));
        assertEq(token.allowance(alice, bob), 11);
        vm.stopPrank();
    }

    function test_RevertWhen_decreaseAllowanceBelowZero() public {
        vm.startPrank(alice);
        token.approve(bob, 3);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, bob, alice, 3, 4));
        token.decreaseAllowance(bob, 4);
        vm.stopPrank();
    }

    function test_RevertWhen_increaseAllowanceOverflows() public {
        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert();
        token.increaseAllowance(bob, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // transferFrom
    // ------------------------------------------------------------------------------------------------------------

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 50e18);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 20e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 30e18);
        assertTrue(token.transferFrom(deployer, bob, 30e18));

        assertEq(token.balanceOf(bob), 30e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 30e18);
        assertEq(token.allowance(deployer, alice), 20e18);
        assertEq(token.balanceOf(alice), 0, "the spender gained nothing");
    }

    function test_transferFromExactAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 7);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 7));
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), 7);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrease() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 1e18));
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, alice, deployer, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, alice, deployer, 10, 11));
        token.transferFrom(deployer, bob, 11);
    }

    function test_RevertWhen_transferFromExceedsBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(carol, 5);
        vm.prank(carol);
        token.approve(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, carol, 5, 6));
        token.transferFrom(carol, bob, 6);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(PleaToken.TransferToZeroAddress.selector);
        token.transferFrom(deployer, address(0), 1);
    }

    /// @dev Nobody, the deployer included, can pull a holder's tokens without that holder's allowance.
    function test_RevertWhen_deployerPullsFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, deployer, alice, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // burn
    // ------------------------------------------------------------------------------------------------------------

    function test_burnReducesSupplyAndBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 40e18);
        token.burn(40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(), SUPPLY - 40e18);
    }

    function test_RevertWhen_burnExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // No privileged powers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The token exposes no mint, owner, pause, blacklist or upgrade entry point: every such selector is
    ///      unknown to it and reverts, from a stranger and from the deployer alike, and the supply never grows.
    function test_noPrivilegedSelectorsExist() public {
        string[18] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setTransfersEnabled(bool)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_RevertWhen_sendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
    }

    /// @dev Reachable runtime code holds no DELEGATECALL, CALLCODE or SELFDESTRUCT. Mirrors the launch floor's
    ///      scan: PUSH data is skipped and bytes after a terminating opcode are data until the next JUMPDEST.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRevertsAboveBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, deployer, SUPPLY, amount));
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, alice, deployer, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.allowance(deployer, alice), allowed - amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice), token.totalSupply());
    }

    function testFuzz_approveThenRead(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }
}
