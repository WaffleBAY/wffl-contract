// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { WaffleFactory } from "../src/WaffleFactory.sol";
import { WaffleMarket } from "../src/WaffleMarket.sol";
import { IWorldID } from "../src/interfaces/IWorldID.sol";
import { ISignatureTransfer } from "../src/interfaces/ISignatureTransfer.sol";
import { WaffleLib } from "../src/libraries/WaffleLib.sol";
import { MockWLD } from "../src/test/MockWLD.sol";

contract MockWorldID is IWorldID {
    function verifyProof(uint256, uint256, uint256, uint256, uint256, uint256[8] calldata) external view override {}
}

/// @dev Mock Permit2 that simply transfers tokens via transferFrom (no signature verification)
contract MockPermit2 is ISignatureTransfer {
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature */
    ) external override {
        // In test, just do a simple transferFrom (tokens must be pre-approved to this contract)
        (bool success, ) = permit.permitted.token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                owner,
                transferDetails.to,
                transferDetails.requestedAmount
            )
        );
        require(success, "MockPermit2: transferFrom failed");
    }
}

contract WaffleMarketTest is Test {
    WaffleFactory factory;
    WaffleMarket market;
    MockWorldID mockWorldId;
    MockPermit2 mockPermit2;
    MockWLD wld;

    address seller = makeAddr("seller");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address foundation = makeAddr("foundation");
    address ops = makeAddr("ops");
    address operator = makeAddr("operator");

    // 테스트용 seller nullifierHash (World ID 인증 결과)
    uint256 constant SELLER_NULLIFIER = 99999;
    uint256[8] EMPTY_PROOF = [uint256(0),0,0,0,0,0,0,0];

    function setUp() public {
        mockWorldId = new MockWorldID();
        mockPermit2 = new MockPermit2();
        wld = new MockWLD();

        factory = new WaffleFactory(
            address(mockWorldId),
            "app_test",
            foundation,
            ops,
            operator,
            address(wld),
            address(mockPermit2)
        );

        // Mint WLD to test accounts
        wld.mint(seller, 1000 * 1e18);
        wld.mint(user1, 1000 * 1e18);
        wld.mint(user2, 1000 * 1e18);

        // Approve MockPermit2 to spend WLD (simulates Permit2 approval)
        vm.prank(seller);
        wld.approve(address(mockPermit2), type(uint256).max);
        vm.prank(user1);
        wld.approve(address(mockPermit2), type(uint256).max);
        vm.prank(user2);
        wld.approve(address(mockPermit2), type(uint256).max);
    }

    /// @dev Helper to create a market via factory with Permit2
    function _createMarket(
        WaffleLib.MarketType mType,
        uint256 ticket,
        uint256 goal,
        uint256 quantity,
        uint256 duration,
        uint256 depositAmount
    ) internal returns (address) {
        return factory.createMarket(
            1,                          // _root
            SELLER_NULLIFIER,           // _sellerNullifierHash
            EMPTY_PROOF,                // _sellerProof
            mType,
            ticket,
            goal,
            quantity,
            duration,
            depositAmount,              // _permitAmount
            0,                          // _permitNonce
            block.timestamp + 1 hours,  // _permitDeadline
            ""                          // _permitSignature (MockPermit2 ignores this)
        );
    }

    /// @dev Helper to enter a market with Permit2
    function _enterMarket(address marketAddr, uint256 amount) internal {
        WaffleMarket m = WaffleMarket(marketAddr);
        m.enter(
            1,                          // _root
            uint256(uint160(msg.sender)) + block.timestamp, // unique nullifierHash
            EMPTY_PROOF,                // _proof
            amount,                     // _permitAmount
            0,                          // _permitNonce
            block.timestamp + 1 hours,  // _permitDeadline
            ""                          // _permitSignature
        );
    }

    // ━━━━━━━━━━━━━━━ RAFFLE: 전원 당첨 플로우 ━━━━━━━━━━━━━━━
    function testRaffleAllWinFlow() public {
        uint256 goal = 100 * 1e18;  // 100 WLD
        uint256 ticket = 10 * 1e18; // 10 WLD
        uint256 quantity = 2;       // 경품 2개, 참여자 ≤ 2이면 전원 당첨
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100; // 15 WLD

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration, deposit
        );

        market = WaffleMarket(marketAddr);

        // commitment = hash(sellerNullifierHash + CA) 자동 생성 검증
        bytes32 expectedCommitment = keccak256(abi.encodePacked(SELLER_NULLIFIER, marketAddr));
        assertEq(market.commitment(), expectedCommitment);
        assertEq(market.sellerNullifierHash(), SELLER_NULLIFIER);

        // 마켓은 생성 시 바로 OPEN 상태
        vm.stopPrank();

        // 유저 참여 (ticket + PARTICIPANT_DEPOSIT = 10 + 5 = 15 WLD)
        uint256 entryAmount = ticket + 5 * 1e18; // ticket + PARTICIPANT_DEPOSIT
        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");

        // 수수료 검증 (3% → 재단)
        assertEq(wld.balanceOf(foundation), ticket * 3 / 100);

        // 마감 (참여자 1명 ≤ quantity 2 → 전원 당첨, REVEALED 직행)
        vm.warp(block.timestamp + 2 days);
        market.closeEntries();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.REVEALED));

        // 정산
        market.settle();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));

        // 당첨자 보증금 반환
        vm.prank(user1);
        market.claimRefund();
    }

    // ━━━━━━━━━━━━━━━ RAFFLE: 추첨 플로우 (reveal + pick) ━━━━━━━━━━━━━━━
    function testRaffleDrawFlow() public {
        uint256 goal = 100 * 1e18;
        uint256 ticket = 10 * 1e18;
        uint256 quantity = 1;
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration, deposit
        );

        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        // 2명 참여 (quantity=1이므로 추첨 필요)
        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");
        vm.prank(user2);
        market.enter(1, 222, EMPTY_PROOF, entryAmount, 1, block.timestamp + 1 hours, "");

        // 마감 → CLOSED (추첨 필요)
        vm.warp(block.timestamp + 2 days);
        market.closeEntries();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.CLOSED));

        // 100블록 대기 후 reveal
        vm.roll(block.number + 101);
        vm.prank(seller);
        market.revealSecret(1, SELLER_NULLIFIER, EMPTY_PROOF);
        assertTrue(market.secretRevealed());

        // 추첨
        market.pickWinners();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.REVEALED));
        assertEq(market.getWinners().length, 1);

        // 정산 + 환불
        market.settle();
        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
    }

    // ━━━━━━━━━━━━━━━ closeDrawAndSettle: LOTTERY 성공 ━━━━━━━━━━━━━━━
    function testCloseDrawAndSettleLottery() public {
        uint256 goal = 10 * 1e18;   // 10 WLD
        uint256 ticket = 10 * 1e18; // 10 WLD
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.LOTTERY,
            ticket, goal, 0, duration, deposit
        );
        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");
        vm.prank(user2);
        market.enter(1, 222, EMPTY_PROOF, entryAmount, 1, block.timestamp + 1 hours, "");

        // 마감 시간 경과 후 closeDrawAndSettle
        vm.warp(block.timestamp + 2 days);
        market.closeDrawAndSettle();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
        assertEq(market.getWinners().length, 1);
    }

    // ━━━━━━━━━━━━━━━ closeDrawAndSettle: RAFFLE 전원 당첨 ━━━━━━━━━━━━━━━
    function testCloseDrawAndSettleRaffleAllWin() public {
        uint256 goal = 100 * 1e18;
        uint256 ticket = 10 * 1e18;
        uint256 quantity = 5;       // 경품 5개, 참여자 2명 → 전원 당첨
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration, deposit
        );
        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");
        vm.prank(user2);
        market.enter(1, 222, EMPTY_PROOF, entryAmount, 1, block.timestamp + 1 hours, "");

        vm.warp(block.timestamp + 2 days);
        market.closeDrawAndSettle();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
        assertEq(market.getWinners().length, 2); // 전원 당첨
    }

    // ━━━━━━━━━━━━━━━ closeDrawAndSettle: RAFFLE 추첨 ━━━━━━━━━━━━━━━
    function testCloseDrawAndSettleRaffleDraw() public {
        uint256 goal = 100 * 1e18;
        uint256 ticket = 10 * 1e18;
        uint256 quantity = 1;       // 경품 1개, 참여자 2명 → 추첨
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration, deposit
        );
        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");
        vm.prank(user2);
        market.enter(1, 222, EMPTY_PROOF, entryAmount, 1, block.timestamp + 1 hours, "");

        vm.warp(block.timestamp + 2 days);
        market.closeDrawAndSettle();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
        assertEq(market.getWinners().length, 1);
    }

    // ━━━━━━━━━━━━━━━ closeDrawAndSettle via Factory proxy ━━━━━━━━━━━━━━━
    function testCloseDrawAndSettleViaFactory() public {
        uint256 goal = 100 * 1e18;
        uint256 ticket = 10 * 1e18;
        uint256 quantity = 2;
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, quantity, duration, deposit
        );
        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");

        vm.warp(block.timestamp + 2 days);

        // Call via factory proxy
        factory.closeDrawAndSettle(marketAddr);

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.COMPLETED));
    }

    // ━━━━━━━━━━━━━━━ closeDrawAndSettle: LOTTERY 목표 미달 ━━━━━━━━━━━━━━━
    function testCloseDrawAndSettleLotteryFailed() public {
        uint256 goal = 1000 * 1e18;  // 목표 1000 WLD (높게 설정)
        uint256 ticket = 10 * 1e18;
        uint256 duration = 1 days;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.LOTTERY,
            ticket, goal, 0, duration, deposit
        );
        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");

        vm.warp(block.timestamp + 2 days);
        market.closeDrawAndSettle();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.FAILED));
    }

    // ━━━━━━━━━━━━━━━ Reveal 타임아웃 + 슬래싱 ━━━━━━━━━━━━━━━
    function testRevealTimeoutSlashing() public {
        uint256 goal = 100 * 1e18;
        uint256 ticket = 10 * 1e18;
        uint256 deposit = (goal * 15) / 100;

        vm.startPrank(seller);
        address marketAddr = _createMarket(
            WaffleLib.MarketType.RAFFLE,
            ticket, goal, 1, 1 days, deposit
        );

        market = WaffleMarket(marketAddr);
        vm.stopPrank();

        uint256 entryAmount = ticket + 5 * 1e18;

        vm.prank(user1);
        market.enter(1, 111, EMPTY_PROOF, entryAmount, 0, block.timestamp + 1 hours, "");
        vm.prank(user2);
        market.enter(1, 222, EMPTY_PROOF, entryAmount, 1, block.timestamp + 1 hours, "");

        vm.warp(block.timestamp + 2 days);
        market.closeEntries();

        // 150블록 진행 (snapshotBlock + 50 초과)
        vm.roll(block.number + 251);

        uint256 sellerBalBefore = wld.balanceOf(seller);
        uint256 opsBalBefore = wld.balanceOf(ops);

        market.cancelByTimeout();

        assertEq(uint256(market.status()), uint256(WaffleLib.MarketStatus.FAILED));
        // 판매자: 50% 반환, 운영: 50% 슬래싱
        assertGt(wld.balanceOf(seller), sellerBalBefore);
        assertGt(wld.balanceOf(ops), opsBalBefore);
    }
}
