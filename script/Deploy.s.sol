// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BountyBoard} from "../src/BountyBoard.sol";
import {MockBEM} from "../src/MockBEM.sol";

/// 用法见 README_zh.md。chainId 97 部署 MockBEM；chainId 56 使用真实 BEM。
contract Deploy is Script {
    address constant BEM_MAINNET = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        address tokenAddr;
        if (block.chainid == 97 && vm.envOr("MOCK_BEM", address(0)) != address(0)) {
            tokenAddr = vm.envAddress("MOCK_BEM"); // 复用已部署的 MockBEM
        } else if (block.chainid == 97) {
            MockBEM m = new MockBEM();
            m.mint(deployer, 10_000_000e8);
            tokenAddr = address(m);
            console.log("MockBEM:", tokenAddr);
        } else if (block.chainid == 56) {
            tokenAddr = BEM_MAINNET;
        } else revert("unsupported chain");
        BountyBoard b = new BountyBoard(IERC20(tokenAddr));
        vm.stopBroadcast();
        console.log("BountyBoard:", address(b));
        console.log("decimals:", b.tokenDecimals());
    }
}
