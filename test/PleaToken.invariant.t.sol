// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Drives PleaToken with bounded random calls from a fixed set of actors and keeps an independent model of
///         what every balance and allowance should be. Every call that should fail is made too, and must revert
///         without touching state.
contract PleaTokenHandler is Test {
    PleaToken public immutable token;
    address[] public actors;

    // Model of the token, updated from the call's intended effect, never read back from the token.
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;
    uint256 public ghostBurned;
    uint256 public ghostMaxSupplySeen;
    uint256 public ghostSupplyIncreases;
    uint256 public ghostUnexpectedSuccesses;

    // How many calls of each kind actually did something, so a run that did nothing is visible.
    mapping(bytes32 => uint256) public calls;

    constructor(PleaToken token_, address[] memory actors_, address deployer) {
        token = token_;
        actors = actors_;
        modelBalance[deployer] = token_.INITIAL_SUPPLY();
        ghostMaxSupplySeen = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _afterCall() internal {
        uint256 supply = token.totalSupply();
        if (supply > ghostMaxSupplySeen) ghostSupplyIncreases++;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Successful paths
    // ------------------------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
        calls["transfer"]++;
        _afterCall();
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Sometimes grant the unlimited allowance, which transferFrom never decreases.
        if (amount % 7 == 0) amount = type(uint256).max;
        else amount = bound(amount, 0, token.INITIAL_SUPPLY() * 2);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        modelAllowance[owner][spender] = amount;
        calls["approve"]++;
        _afterCall();
    }

    function increaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 added) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = modelAllowance[owner][spender];
        added = bound(added, 0, type(uint256).max - current);
        vm.prank(owner);
        assertTrue(token.increaseAllowance(spender, added));
        modelAllowance[owner][spender] = current + added;
        calls["increaseAllowance"]++;
        _afterCall();
    }

    function decreaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 subtracted) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = modelAllowance[owner][spender];
        subtracted = bound(subtracted, 0, current);
        vm.prank(owner);
        assertTrue(token.decreaseAllowance(spender, subtracted));
        modelAllowance[owner][spender] = current - subtracted;
        calls["decreaseAllowance"]++;
        _afterCall();
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = modelAllowance[from][spender];
        uint256 cap = token.balanceOf(from);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowed != type(uint256).max) modelAllowance[from][spender] = allowed - amount;
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
        calls["transferFrom"]++;
        _afterCall();
    }

    function burn(uint256 holderSeed, uint256 amount) external {
        address holder = _actor(holderSeed);
        amount = bound(amount, 0, token.balanceOf(holder));
        vm.prank(holder);
        token.burn(amount);
        modelBalance[holder] -= amount;
        ghostBurned += amount;
        calls["burn"]++;
        _afterCall();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Failure paths: each must revert and leave the state alone
    // ------------------------------------------------------------------------------------------------------------

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);
        vm.prank(from);
        try token.transfer(to, amount) {
            ghostUnexpectedSuccesses++;
        } catch {}
        calls["transferTooMuch"]++;
        _afterCall();
    }

    function transferFromBeyondAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        if (allowed == type(uint256).max) return;
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            ghostUnexpectedSuccesses++;
        } catch {}
        calls["transferFromBeyondAllowance"]++;
        _afterCall();
    }

    function burnTooMuch(uint256 holderSeed, uint256 excess) external {
        address holder = _actor(holderSeed);
        uint256 balance = token.balanceOf(holder);
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);
        vm.prank(holder);
        try token.burn(amount) {
            ghostUnexpectedSuccesses++;
        } catch {}
        calls["burnTooMuch"]++;
        _afterCall();
    }

    function decreaseAllowanceBelowZero(uint256 ownerSeed, uint256 spenderSeed, uint256 excess) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        if (current == type(uint256).max) return;
        uint256 amount = current + bound(excess, 1, type(uint256).max - current);
        vm.prank(owner);
        try token.decreaseAllowance(spender, amount) {
            ghostUnexpectedSuccesses++;
        } catch {}
        calls["decreaseAllowanceBelowZero"]++;
        _afterCall();
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            ghostUnexpectedSuccesses++;
        } catch {}
        calls["transferToZero"]++;
        _afterCall();
    }
}

contract PleaTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    PleaToken internal token;
    PleaTokenHandler internal handler;
    address internal deployer = makeAddr("deployer");
    address[] internal actors;

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new PleaTokenHandler(token, actors, deployer);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PleaTokenHandler.transfer.selector;
        selectors[1] = PleaTokenHandler.approve.selector;
        selectors[2] = PleaTokenHandler.increaseAllowance.selector;
        selectors[3] = PleaTokenHandler.decreaseAllowance.selector;
        selectors[4] = PleaTokenHandler.transferFrom.selector;
        selectors[5] = PleaTokenHandler.burn.selector;
        selectors[6] = PleaTokenHandler.transferTooMuch.selector;
        selectors[7] = PleaTokenHandler.transferFromBeyondAllowance.selector;
        selectors[8] = PleaTokenHandler.burnTooMuch.selector;
        selectors[9] = PleaTokenHandler.decreaseAllowanceBelowZero.selector;
        selectors[10] = PleaTokenHandler.transferToZero.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The handler really exercised the token: a suite whose calls all went nowhere would pass vacuously.
    function test_handlerSmoke() public {
        handler.transfer(0, 1, 1_000e18);
        handler.approve(1, 2, 1);
        handler.increaseAllowance(1, 2, 500e18);
        handler.transferFrom(2, 1, 3, 400e18);
        handler.decreaseAllowance(1, 2, 1);
        handler.burn(3, 100e18);
        handler.transferTooMuch(3, 0, 1);
        handler.transferFromBeyondAllowance(2, 1, 3, 1);
        handler.burnTooMuch(1, 1);
        handler.decreaseAllowanceBelowZero(1, 2, 1);
        handler.transferToZero(0, 1);
        assertEq(token.balanceOf(actors[3]), handler.modelBalance(actors[3]));
        assertEq(token.balanceOf(actors[3]), 300e18);
        assertEq(token.balanceOf(actors[1]), 600e18);
        assertEq(token.allowance(actors[1], actors[2]), 100e18);
        assertEq(token.totalSupply(), SUPPLY - 100e18);
        assertEq(handler.ghostBurned(), 100e18);
        assertEq(handler.ghostUnexpectedSuccesses(), 0);
    }

    /// @dev The supply is the initial mint less what holders burned: nothing ever mints.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_supplyIsInitialLessBurned() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned());
        assertLe(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_supplyNeverIncreases() public view {
        assertEq(handler.ghostSupplyIncreases(), 0);
    }

    /// @dev Every token in existence sits with one of the actors; none is created or lost by a transfer.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Each balance equals what the model says it should be after the same calls.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_balancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.modelBalance(actors[i]));
        }
    }

    /// @dev Each allowance equals what the model says: decreased exactly by what was spent, never if unlimited.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_allowancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.modelAllowance(actors[i], actors[j]));
            }
        }
    }

    /// @dev No call that should have failed ever succeeded.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_failurePathsAlwaysRevert() public view {
        assertEq(handler.ghostUnexpectedSuccesses(), 0);
    }

    /// @dev Metadata is constant whatever happened.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_metadataConstant() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "pleaimd");
        assertEq(token.symbol(), "PLEA");
    }
}
