// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BountyBoard} from "../src/BountyBoard.sol";
import {MockBEM, FeeBEM, ReentrantBEM} from "../src/MockBEM.sol";

contract BountyBoardTest is Test {
    MockBEM bem; BountyBoard board;
    address poster = address(0xA11CE); address worker = address(0xB0B); address other = address(0xCAFE);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ONE = 1e8;

    function setUp() public {
        bem = new MockBEM(); board = new BountyBoard(IERC20(address(bem)));
        bem.mint(poster, 1_000_000 * ONE);
        vm.prank(poster); bem.approve(address(board), type(uint256).max);
    }

    function _create(uint256 amt) internal returns (uint256) {
        vm.prank(poster); return board.createTask(amt, uint64(block.timestamp + 7 days), "ipfs://task");
    }
    function _submit(uint256 id) internal { vm.prank(worker); board.submit(id, "ipfs://work"); }

    function test_Decimals() public view { assertEq(board.tokenDecimals(), 8); }

    function test_CreateEscrowAndPostingFee() public {
        uint256 id = _create(1000 * ONE);
        BountyBoard.Task memory t = board.getTask(id);
        assertEq(t.reward, 995 * ONE);
        assertEq(bem.balanceOf(DEAD), 5 * ONE);
        assertEq(board.totalBurned(), 5 * ONE);
        assertEq(bem.balanceOf(address(board)), 995 * ONE);
        assertEq(uint8(t.status), uint8(BountyBoard.Status.Open));
    }

    function test_HappyPathBurnAmounts() public {
        uint256 id = _create(1000 * ONE); _submit(id);
        vm.expectEmit(true, false, false, true); emit BountyBoard.Burned(id, 99.5e8);
        vm.prank(poster); board.approve(id);
        assertEq(bem.balanceOf(worker), 895.5e8);       // 995 * 90%
        assertEq(bem.balanceOf(DEAD), 5e8 + 99.5e8);
        assertEq(board.totalBurned(), 104.5e8);
        assertEq(bem.balanceOf(address(board)), 0);
        assertEq(board.totalEscrowed(), 0);
    }

    function test_CancelRefundNoBurn() public {
        uint256 id = _create(1000 * ONE);
        uint256 b = bem.balanceOf(poster);
        vm.prank(poster); board.cancel(id);
        assertEq(bem.balanceOf(poster) - b, 995 * ONE);
        assertEq(board.totalBurned(), 5 * ONE);
        vm.prank(poster); vm.expectRevert(BountyBoard.BadStatus.selector); board.cancel(id);
    }

    function test_CannotCancelAfterSubmission() public {
        uint256 id = _create(100 * ONE); _submit(id);
        vm.prank(poster); vm.expectRevert(BountyBoard.BadStatus.selector); board.cancel(id);
    }

    function test_OnlyPosterActions() public {
        uint256 id = _create(100 * ONE); _submit(id);
        vm.startPrank(other);
        vm.expectRevert(BountyBoard.NotPoster.selector); board.approve(id);
        vm.expectRevert(BountyBoard.NotPoster.selector); board.reject(id);
        vm.expectRevert(BountyBoard.NotPoster.selector); board.cancel(id);
        vm.stopPrank();
    }

    function test_TimeoutClaim() public {
        uint256 id = _create(1000 * ONE); _submit(id);
        vm.prank(worker); vm.expectRevert(BountyBoard.TooEarly.selector); board.claim(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(other); vm.expectRevert(BountyBoard.NotWorker.selector); board.claim(id);
        vm.prank(poster); vm.expectRevert(BountyBoard.DeadlinePassed.selector); board.reject(id);
        vm.prank(worker); board.claim(id);
        assertEq(bem.balanceOf(worker), 895.5e8);
    }

    function test_ClaimWorksEvenAfterDeadline() public {
        uint256 id = _create(100 * ONE);
        vm.warp(block.timestamp + 7 days - 1); _submit(id);
        vm.warp(block.timestamp + 4 days);
        vm.prank(poster); vm.expectRevert(BountyBoard.BadStatus.selector); board.reclaim(id);
        vm.prank(worker); board.claim(id);
    }

    function test_RejectThenResubmitAndReclaim() public {
        uint256 id = _create(100 * ONE); _submit(id);
        vm.prank(poster); board.reject(id);
        assertEq(uint8(board.getTask(id).status), uint8(BountyBoard.Status.Open));
        vm.prank(poster); vm.expectRevert(BountyBoard.TooEarly.selector); board.reclaim(id);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(worker); vm.expectRevert(BountyBoard.DeadlinePassed.selector); board.submit(id, "x");
        uint256 b = bem.balanceOf(poster);
        vm.prank(poster); board.reclaim(id);
        assertEq(bem.balanceOf(poster) - b, 99.5e8);
    }

    function test_InvalidCreate() public {
        vm.startPrank(poster);
        vm.expectRevert(BountyBoard.InvalidParams.selector); board.createTask(0, uint64(block.timestamp + 1 days), "u");
        vm.expectRevert(BountyBoard.InvalidParams.selector); board.createTask(1, uint64(block.timestamp + 10), "u");
        vm.expectRevert(BountyBoard.InvalidParams.selector); board.createTask(1e8, uint64(block.timestamp + 1 days), "");
        vm.stopPrank();
    }

    function test_PosterCannotSubmitOwn() public {
        uint256 id = _create(100 * ONE);
        vm.prank(poster); vm.expectRevert(BountyBoard.InvalidParams.selector); board.submit(id, "x");
    }

    function test_DoubleApproveReverts() public {
        uint256 id = _create(100 * ONE); _submit(id);
        vm.startPrank(poster); board.approve(id);
        vm.expectRevert(BountyBoard.BadStatus.selector); board.approve(id); vm.stopPrank();
        vm.prank(worker); vm.expectRevert(BountyBoard.BadStatus.selector); board.claim(id);
    }

    function test_FeeOnTransferToken() public {
        FeeBEM f = new FeeBEM(); BountyBoard b2 = new BountyBoard(IERC20(address(f)));
        f.mint(poster, 1000 * ONE);
        vm.startPrank(poster); f.approve(address(b2), type(uint256).max);
        uint256 id = b2.createTask(1000 * ONE, uint64(block.timestamp + 1 days), "u"); vm.stopPrank();
        // 到账 990，发布费 4.95，托管 985.05
        assertEq(b2.getTask(id).reward, 985.05e8);
        vm.prank(worker); b2.submit(id, "w");
        vm.prank(poster); b2.approve(id);
        assertEq(f.balanceOf(address(b2)), 0); // 无残留、无亏空
    }

    function test_Reentrancy() public {
        ReentrantBEM r = new ReentrantBEM(); BountyBoard b3 = new BountyBoard(IERC20(address(r)));
        r.mint(poster, 1000 * ONE);
        vm.startPrank(poster); r.approve(address(b3), type(uint256).max);
        uint256 id1 = b3.createTask(100 * ONE, uint64(block.timestamp + 1 days), "u");
        uint256 id2 = b3.createTask(100 * ONE, uint64(block.timestamp + 1 days), "u");
        vm.stopPrank();
        vm.prank(worker); b3.submit(id1, "w");
        r.arm(address(b3), id2);
        vm.prank(poster); b3.approve(id1);
        assertTrue(r.reentered()); // 重入调用被拒绝
        assertEq(uint8(b3.getTask(id2).status), uint8(BountyBoard.Status.Open));
    }

    function testFuzz_Accounting(uint96 amt) public {
        vm.assume(amt >= 1000 && amt <= 1_000_000 * ONE);
        uint256 id = _create(amt); _submit(id);
        vm.prank(poster); board.approve(id);
        assertEq(bem.balanceOf(worker) + bem.balanceOf(DEAD), amt);
        assertEq(board.totalBurned(), bem.balanceOf(DEAD));
    }
}
