// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWorldID } from "./interfaces/IWorldID.sol";
import { ISignatureTransfer } from "./interfaces/ISignatureTransfer.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleMarket is ReentrancyGuard {

    // ━━━━━━━━━━━━━━━ 마켓 기본 정보 ━━━━━━━━━━━━━━━
    address public immutable seller;
    address public immutable factory;
    address public immutable worldId;
    uint256 public immutable externalNullifier;

    IERC20 public immutable wldToken;
    ISignatureTransfer public immutable permit2;

    address public worldFoundation;     // 3% 수수료 → Worldcoin 재단
    address public opsWallet;           // 2% 수수료 → 운영 (WaffleTreasury)
    address public operator;            // 운영자 주소

    // ━━━━━━━━━━━━━━━ 마켓 타입 ━━━━━━━━━━━━━━━
    WaffleLib.MarketType public mType;

    // ━━━━━━━━━━━━━━━ 경제 모델 ━━━━━━━━━━━━━━━
    uint256 public ticketPrice;
    uint256 public constant PARTICIPANT_DEPOSIT = 5 * 1e18; // 5 WLD
    uint256 public sellerDeposit;       // 판매자 보증금 (LOTTERY/RAFFLE 모두, goalAmount × 15%)
    uint256 public prizePool;           // 티켓 가격의 95% 누적

    // ━━━━━━━━━━━━━━━ 조건 ━━━━━━━━━━━━━━━
    uint256 public goalAmount;          // LOTTERY: 목표 금액 / RAFFLE: 보증금 계산 기준
    uint256 public preparedQuantity;    // RAFFLE 전용: 경품 수량
    uint256 public endTime;             // 응모 마감 시간

    // ━━━━━━━━━━━━━━━ 상태 ━━━━━━━━━━━━━━━
    WaffleLib.MarketStatus public status;
    address[] public participants;
    address[] public winners;

    // ━━━━━━━━━━━━━━━ 난수 생성 (Commit-Reveal) ━━━━━━━━━━━━━━━
    uint256 public immutable sellerNullifierHash;
    bytes32 public immutable commitment;
    uint256 public nullifierHashSum;

    uint256 public snapshotBlock;
    bool public secretRevealed;
    uint256 public snapshotPrevrandao;

    uint256 public constant REVEAL_BLOCK_TIMEOUT = 50;

    // ━━━━━━━━━━━━━━━ 참가자 정보 ━━━━━━━━━━━━━━━
    mapping(address => WaffleLib.ParticipantInfo) public participantInfos;
    mapping(uint256 => bool) public nullifierHashes;

    // ━━━━━━━━━━━━━━━ 이벤트 ━━━━━━━━━━━━━━━
    event MarketOpen();
    event Entered(address indexed participant);
    event SecretRevealed(uint256 nullifierHash);
    event WinnerSelected(address[] winners);
    event Settled();
    event MarketFailed(string reason);

    // ━━━━━━━━━━━━━━━ 생성자 (Factory가 호출) ━━━━━━━━━━━━━━━
    constructor(
        address _seller,
        address _worldId,
        string memory _appId,
        address _worldFoundation,
        address _opsWallet,
        address _operator,
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration,
        uint256 _sellerNullifierHash,
        address _wldToken,
        address _permit2,
        uint256 _depositAmount
    ) {
        seller = _seller;
        factory = msg.sender;
        worldId = _worldId;
        externalNullifier = ByteHasher.hashToField(abi.encodePacked(_appId));
        worldFoundation = _worldFoundation;
        opsWallet = _opsWallet;
        operator = _operator;

        wldToken = IERC20(_wldToken);
        permit2 = ISignatureTransfer(_permit2);

        mType = _mType;
        ticketPrice = _ticketPrice;
        goalAmount = _goalAmount;
        preparedQuantity = _preparedQuantity;

        // 두 타입 모두 판매자 보증금 필요 (goalAmount × 15%)
        uint256 requiredDeposit = (_goalAmount * 15) / 100;
        if (_depositAmount < requiredDeposit) {
            revert WaffleLib.InsufficientFunds();
        }
        sellerDeposit = _depositAmount;

        // 🔐 sellerNullifierHash 저장
        sellerNullifierHash = _sellerNullifierHash;

        // 🔐 Commitment 자동 생성: hash(sellerNullifierHash + CA)
        commitment = keccak256(abi.encodePacked(_sellerNullifierHash, address(this)));

        endTime = block.timestamp + _duration;
        status = WaffleLib.MarketStatus.OPEN;
        emit MarketOpen();
    }

    // ━━━━━━━━━━━━━━━ Modifiers ━━━━━━━━━━━━━━━
    modifier onlySeller() {
        if (msg.sender != seller) revert WaffleLib.Unauthorized();
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 2: 마켓 오픈
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function openMarket() external onlySeller {
        if (status != WaffleLib.MarketStatus.CREATED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CREATED);

        status = WaffleLib.MarketStatus.OPEN;
        emit MarketOpen();
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 2: 응모 (Permit2 기반 WLD 결제)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function enter(
        uint256 _root,
        uint256 _nullifierHash,
        uint256[8] calldata _proof,
        uint256 _permitAmount,
        uint256 _permitNonce,
        uint256 _permitDeadline,
        bytes calldata _permitSignature
    ) external nonReentrant {
        if (status != WaffleLib.MarketStatus.OPEN)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);
        if (block.timestamp >= endTime)
            revert WaffleLib.TimeExpired();

        uint256 requiredAmount = ticketPrice + PARTICIPANT_DEPOSIT;
        if (_permitAmount != requiredAmount)
            revert WaffleLib.InsufficientFunds();

        if (nullifierHashes[_nullifierHash])
            revert WaffleLib.AlreadyParticipated();

        // WorldID 검증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _nullifierHash, externalNullifier, _proof
        // );

        // Permit2로 WLD 토큰 pull
        permit2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(wldToken),
                    amount: _permitAmount
                }),
                nonce: _permitNonce,
                deadline: _permitDeadline
            }),
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: _permitAmount
            }),
            msg.sender,
            _permitSignature
        );

        nullifierHashes[_nullifierHash] = true;
        participants.push(msg.sender);
        nullifierHashSum ^= _nullifierHash;

        participantInfos[msg.sender] = WaffleLib.ParticipantInfo({
            hasEntered: true,
            isWinner: false,
            paidAmount: _permitAmount,
            depositRefunded: false
        });

        // 수수료 분배: ticketPrice 기준 3% 재단, 2% 운영, 95% Pool
        uint256 feeWorld = (ticketPrice * 3) / 100;
        uint256 feeOps = (ticketPrice * 2) / 100;
        uint256 toPool = ticketPrice - feeWorld - feeOps;

        prizePool += toPool;

        _safeTransferWLD(worldFoundation, feeWorld);
        _safeTransferWLD(opsWallet, feeOps);

        emit Entered(msg.sender);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 2b: 응모 (Factory 프록시 - WLD는 Factory가 미리 전송)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function enterViaFactory(
        address _participant,
        uint256 _nullifierHash,
        uint256[8] calldata _proof
    ) external onlyFactory nonReentrant {
        if (status != WaffleLib.MarketStatus.OPEN)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);
        if (block.timestamp >= endTime)
            revert WaffleLib.TimeExpired();

        if (nullifierHashes[_nullifierHash])
            revert WaffleLib.AlreadyParticipated();

        nullifierHashes[_nullifierHash] = true;
        participants.push(_participant);
        nullifierHashSum ^= _nullifierHash;

        uint256 requiredAmount = ticketPrice + PARTICIPANT_DEPOSIT;

        participantInfos[_participant] = WaffleLib.ParticipantInfo({
            hasEntered: true,
            isWinner: false,
            paidAmount: requiredAmount,
            depositRefunded: false
        });

        // 수수료 분배: ticketPrice 기준 3% 재단, 2% 운영, 95% Pool
        uint256 feeWorld = (ticketPrice * 3) / 100;
        uint256 feeOps = (ticketPrice * 2) / 100;
        uint256 toPool = ticketPrice - feeWorld - feeOps;

        prizePool += toPool;

        _safeTransferWLD(worldFoundation, feeWorld);
        _safeTransferWLD(opsWallet, feeOps);

        emit Entered(_participant);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 3: 응모 마감
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function closeEntries() external nonReentrant {
        if (block.timestamp < endTime)
            revert WaffleLib.TimeNotReached();
        if (status != WaffleLib.MarketStatus.OPEN)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.OPEN);

        snapshotBlock = block.number + 100;

        if (mType == WaffleLib.MarketType.LOTTERY) {
            if (prizePool >= goalAmount) {
                // 목표 달성 → CLOSED → Phase 4 진행
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                // 목표 미달 → FAILED
                status = WaffleLib.MarketStatus.FAILED;
                // 판매자 보증금 반환
                uint256 deposit = sellerDeposit;
                sellerDeposit = 0;
                _safeTransferWLD(seller, deposit);
                emit MarketFailed("Goal not reached");
            }
        } else {
            // RAFFLE
            if (participants.length > preparedQuantity) {
                // 참여자 > 준비 수량 → 추첨 필요 → Phase 4 진행
                status = WaffleLib.MarketStatus.CLOSED;
            } else {
                // 참여자 ≤ 준비 수량 → 전원 당첨! Phase 4 스킵
                status = WaffleLib.MarketStatus.REVEALED;
                winners = participants;
                for (uint256 i = 0; i < participants.length; i++) {
                    participantInfos[participants[i]].isWinner = true;
                }
                emit WinnerSelected(winners);
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: Reveal
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function revealSecret(
        uint256 _root,
        uint256 _nullifierHash,
        uint256[8] calldata _proof
    ) external onlySeller {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);

        if (block.number < snapshotBlock)
            revert WaffleLib.TimeNotReached();

        if (block.number > snapshotBlock + REVEAL_BLOCK_TIMEOUT)
            revert WaffleLib.TimeExpired();

        // World ID 재인증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _nullifierHash, externalNullifier, _proof
        // );

        bytes32 computedCommitment = keccak256(abi.encodePacked(_nullifierHash, address(this)));
        if (computedCommitment != commitment)
            revert WaffleLib.VerificationFailed();

        secretRevealed = true;
        snapshotPrevrandao = block.prevrandao;

        emit SecretRevealed(_nullifierHash);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: 추첨
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function pickWinners() external nonReentrant {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);
        if (!secretRevealed)
            revert WaffleLib.VerificationFailed();

        uint256 randomness = uint256(keccak256(abi.encodePacked(
            snapshotPrevrandao,
            sellerNullifierHash,
            nullifierHashSum
        )));

        uint256 winnerCount = (mType == WaffleLib.MarketType.LOTTERY) ? 1 : preparedQuantity;
        if (winnerCount > participants.length) winnerCount = participants.length;

        address[] memory tempPool = participants;
        uint256 poolSize = tempPool.length;

        for (uint256 i = 0; i < winnerCount; i++) {
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(randomness, i))) % poolSize;
            address winner = tempPool[randomIndex];

            winners.push(winner);
            participantInfos[winner].isWinner = true;

            tempPool[randomIndex] = tempPool[poolSize - 1];
            poolSize--;
        }

        status = WaffleLib.MarketStatus.REVEALED;
        emit WinnerSelected(winners);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 4: Reveal 타임아웃
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function cancelByTimeout() external nonReentrant {
        if (status != WaffleLib.MarketStatus.CLOSED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.CLOSED);

        if (secretRevealed) revert WaffleLib.Unauthorized();

        if (block.number <= snapshotBlock + REVEAL_BLOCK_TIMEOUT)
            revert WaffleLib.TimeNotReached();

        status = WaffleLib.MarketStatus.FAILED;

        // 판매자 보증금 50% 슬래싱
        uint256 slashAmount = sellerDeposit / 2;
        uint256 returnAmount = sellerDeposit - slashAmount;
        sellerDeposit = 0;

        _safeTransferWLD(opsWallet, slashAmount);
        _safeTransferWLD(seller, returnAmount);

        emit MarketFailed("Reveal Timeout");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Phase 5: 정산
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function settle() external nonReentrant {
        if (status != WaffleLib.MarketStatus.REVEALED)
            revert WaffleLib.InvalidState(status, WaffleLib.MarketStatus.REVEALED);

        if (mType == WaffleLib.MarketType.LOTTERY) {
            uint256 winnerPrize = (prizePool * 95) / 100;
            uint256 opsFee = prizePool - winnerPrize;

            _safeTransferWLD(winners[0], winnerPrize);
            _safeTransferWLD(opsWallet, opsFee);
            _safeTransferWLD(seller, sellerDeposit);
        } else {
            _safeTransferWLD(seller, prizePool + sellerDeposit);
        }

        prizePool = 0;
        sellerDeposit = 0;
        status = WaffleLib.MarketStatus.COMPLETED;
        emit Settled();
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 환불 / 보증금 반환
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function claimRefund() external nonReentrant {
        WaffleLib.ParticipantInfo storage info = participantInfos[msg.sender];

        if (!info.hasEntered || info.depositRefunded)
            revert WaffleLib.Unauthorized();

        uint256 refundAmount = 0;

        if (status == WaffleLib.MarketStatus.FAILED) {
            uint256 poolShare = prizePool / participants.length;
            refundAmount = PARTICIPANT_DEPOSIT + poolShare;
        }
        else if (status == WaffleLib.MarketStatus.COMPLETED) {
            refundAmount = PARTICIPANT_DEPOSIT;
        }

        if (refundAmount == 0) revert WaffleLib.InsufficientFunds();

        info.depositRefunded = true;
        _safeTransferWLD(msg.sender, refundAmount);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MVP 단순 추첨+정산 (closeEntries + pickWinners + settle 통합)
    // commit-reveal 없이 block.prevrandao 기반 랜덤
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function closeDrawAndSettle() external nonReentrant {
        require(block.timestamp >= endTime, "Not expired");
        require(status == WaffleLib.MarketStatus.OPEN, "Not open");

        if (mType == WaffleLib.MarketType.LOTTERY) {
            if (prizePool < goalAmount) {
                // 목표 미달 → FAILED
                status = WaffleLib.MarketStatus.FAILED;
                uint256 deposit = sellerDeposit;
                sellerDeposit = 0;
                _safeTransferWLD(seller, deposit);
                emit MarketFailed("Goal not reached");
                return;
            }
            // 당첨자 1명 추첨
            uint256 seed = uint256(keccak256(abi.encodePacked(
                block.prevrandao, block.timestamp, participants.length
            )));
            uint256 winnerIdx = seed % participants.length;
            winners.push(participants[winnerIdx]);
            participantInfos[participants[winnerIdx]].isWinner = true;
            emit WinnerSelected(winners);

            // 정산: 95% winner, 5% ops, seller deposit 반환
            uint256 winnerPrize = (prizePool * 95) / 100;
            uint256 opsFee = prizePool - winnerPrize;
            _safeTransferWLD(winners[0], winnerPrize);
            _safeTransferWLD(opsWallet, opsFee);
            _safeTransferWLD(seller, sellerDeposit);
        } else {
            // RAFFLE
            if (participants.length <= preparedQuantity) {
                // 전원 당첨
                for (uint256 i = 0; i < participants.length; i++) {
                    winners.push(participants[i]);
                    participantInfos[participants[i]].isWinner = true;
                }
            } else {
                // 랜덤 추첨
                uint256 seed = uint256(keccak256(abi.encodePacked(
                    block.prevrandao, block.timestamp, participants.length
                )));
                address[] memory tempPool = participants;
                uint256 poolSize = tempPool.length;
                for (uint256 i = 0; i < preparedQuantity; i++) {
                    uint256 idx = uint256(keccak256(abi.encodePacked(seed, i))) % poolSize;
                    winners.push(tempPool[idx]);
                    participantInfos[tempPool[idx]].isWinner = true;
                    tempPool[idx] = tempPool[poolSize - 1];
                    poolSize--;
                }
            }
            emit WinnerSelected(winners);
            // RAFFLE 정산: pool + deposit → seller
            _safeTransferWLD(seller, prizePool + sellerDeposit);
        }

        prizePool = 0;
        sellerDeposit = 0;
        status = WaffleLib.MarketStatus.COMPLETED;
        emit Settled();
    }

    // ━━━━━━━━━━━━━━━ 조회 함수 ━━━━━━━━━━━━━━━
    function getParticipants() external view returns (address[] memory) {
        return participants;
    }

    function getWinners() external view returns (address[] memory) {
        return winners;
    }

    // ━━━━━━━━━━━━━━━ 내부 함수 ━━━━━━━━━━━━━━━
    function _safeTransferWLD(address to, uint256 value) internal {
        if (value == 0) return;
        require(wldToken.transfer(to, value), "WLD transfer failed");
    }
}
