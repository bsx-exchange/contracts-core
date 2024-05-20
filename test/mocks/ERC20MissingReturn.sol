// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

/// @notice An implementation of ERC-20 that does not return a boolean in {transfer} and {transferFrom}.
/// @dev See https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca/.
contract ERC20MissingReturn {
    uint8 public decimals = 6;
    string public name = "ERC20MissingReturn";
    string public symbol = "MRT";
    uint256 public totalSupply;

    mapping(address owner => mapping(address spender => uint256 allowance)) internal _allowances;
    mapping(address account => uint256 balance) internal _balances;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function approve(address spender, uint256 value) public returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @dev This function does not return a value, although the ERC-20 standard mandates that it should.
    function transfer(address to, uint256 amount) public {
        _transfer(msg.sender, to, amount);
    }

    /// @dev This function does not return a value, although the ERC-20 standard mandates that it should.
    function transferFrom(address from, address to, uint256 amount) public {
        _transfer(from, to, amount);
        _approve(from, msg.sender, _allowances[from][msg.sender] - amount);
    }

    function burn(address holder, uint256 amount) public {
        _balances[holder] -= amount;
        totalSupply -= amount;
        emit Transfer(holder, address(0), amount);
    }

    function mint(address beneficiary, uint256 amount) public {
        _balances[beneficiary] += amount;
        totalSupply += amount;
        emit Transfer(address(0), beneficiary, amount);
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _approve(address owner, address spender, uint256 value) internal virtual {
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        _balances[from] = _balances[from] - amount;
        _balances[to] = _balances[to] + amount;
        emit Transfer(from, to, amount);
    }
}
