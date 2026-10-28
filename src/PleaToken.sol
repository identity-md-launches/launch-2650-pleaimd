// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title pleaimd (PLEA)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 PLEA (18 decimals) is minted once, in the
///         constructor, to the deployer (`msg.sender`). Nothing can mint afterwards, nothing can pause, freeze,
///         block or seize a holder, and there is no owner or other privileged role.
/// @dev Self-contained implementation of ERC-20 (EIP-20) with no external dependencies. The contract is named
///      `PleaToken`; the token's own name is "pleaimd" and its symbol "PLEA", returned by `name()` and
///      `symbol()`. The supply is fixed at deployment and can only ever shrink through `burn`.
contract PleaToken {
    // ------------------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Token name.
    string public constant name = "pleaimd";

    /// @notice Token symbol.
    string public constant symbol = "PLEA";

    /// @notice Token decimals.
    uint8 public constant decimals = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 PLEA with 18 decimals. Minted once in the
    ///         constructor; `totalSupply()` starts here and can only decrease through `burn`.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ------------------------------------------------------------------------------------------------------------
    // Events (EIP-20)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Emitted when `value` tokens move from `from` to `to`. `from` is the zero address on mint and
    ///         `to` is the zero address on burn.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` tokens while holding only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to spend `needed` of `owner`'s tokens while allowed only `allowance`.
    error InsufficientAllowance(address spender, address owner, uint256 allowance, uint256 needed);

    /// @notice Tokens may not be transferred to the zero address; use `burn` to destroy them.
    error TransferToZeroAddress();

    /// @notice An allowance may not be granted to the zero address.
    error ApproveToZeroAddress();

    // ------------------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Current number of tokens in existence.
    uint256 public totalSupply;

    /// @notice Balance of each account.
    mapping(address account => uint256) public balanceOf;

    /// @notice Remaining number of tokens `spender` may move on behalf of `owner`.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ------------------------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Mints the whole supply to the deployer. In the launch, the deployer is the project factory, which
    ///         then distributes the supply (swarm share, pool seed, remainder) itself. No constructor arguments.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-20
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Moves `amount` tokens from the caller to `to`.
    /// @return True on success. Reverts, never returns false.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Moves `amount` tokens from `from` to `to` using the caller's allowance from `from`.
    ///         An allowance of `type(uint256).max` is treated as unlimited and is not decreased.
    /// @return True on success. Reverts, never returns false.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    /// @dev Setting a non-zero allowance over an existing non-zero one has the well-known EIP-20 race; callers
    ///      that care should set it to zero first, or use `increaseAllowance` / `decreaseAllowance`.
    /// @return True on success. Reverts, never returns false.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `addedValue`.
    /// @return True on success.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtractedValue`. Reverts if the current
    ///         allowance is smaller than `subtractedValue`.
    /// @return True on success.
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) {
            revert InsufficientAllowance(spender, msg.sender, current, subtractedValue);
        }
        unchecked {
            _approve(msg.sender, spender, current - subtractedValue);
        }
        return true;
    }

    /// @notice Destroys `amount` of the caller's own tokens, reducing `totalSupply`. Only the holder can burn
    ///         its balance; there is no `burnFrom` and no privileged burn.
    function burn(uint256 amount) external {
        uint256 balance = balanceOf[msg.sender];
        if (balance < amount) revert InsufficientBalance(msg.sender, balance, amount);
        unchecked {
            balanceOf[msg.sender] = balance - amount;
            // The supply is the sum of all balances, so it is at least `amount` here.
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // The sum of all balances never exceeds totalSupply, which fits in uint256.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ApproveToZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, owner, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
