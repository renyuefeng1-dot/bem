// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBEM is ERC20 {
    constructor() ERC20("Mock BEM", "BEM") {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// 转账收取 1% 手续费（销毁）的代币
contract FeeBEM is ERC20 {
    constructor() ERC20("Fee BEM", "fBEM") {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = v / 100;
            super._update(from, address(0), fee);
            v -= fee;
        }
        super._update(from, to, v);
    }
}

interface IBoard { function claim(uint256) external; function cancel(uint256) external; }

/// 转账时尝试重入的恶意代币
contract ReentrantBEM is ERC20 {
    address public board; uint256 public target; bool public attack; bool public reentered;
    constructor() ERC20("R", "R") {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function arm(address b, uint256 id) external { board = b; target = id; attack = true; }
    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (attack && from == board) {
            attack = false;
            try IBoard(board).cancel(target) {} catch { reentered = true; }
        }
    }
}
