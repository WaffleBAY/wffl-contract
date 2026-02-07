// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WaffleMarket } from "./WaffleMarket.sol";
import { WaffleLib } from "./libraries/WaffleLib.sol";
import { IWorldID } from "./interfaces/IWorldID.sol";
import { ISignatureTransfer } from "./interfaces/ISignatureTransfer.sol";
import { ByteHasher } from "./libraries/ByteHasher.sol";

contract WaffleFactory is Ownable {

    // 글로벌 설정
    address public immutable worldId;
    string public appId;
    address public worldFoundation;  // 수수료 수령 주소 (3%)
    address public immutable treasury; // 수수료 수령 주소 (2%) - 금고
    address public operator;

    IERC20 public immutable wldToken;
    ISignatureTransfer public immutable permit2;

    // 생성된 마켓 목록
    address[] public markets;
    mapping(address => bool) public isMarket;

    uint256 public marketCount;

    // 이벤트
    event MarketCreated(
        uint256 indexed marketId,
        address indexed marketAddress,
        address indexed seller,
        WaffleLib.MarketType mType
    );
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event FeeRecipientsUpdated(address worldFoundation, address opsWallet);

    constructor(
        address _worldId,
        string memory _appId,
        address _worldFoundation,
        address _treasury,
        address _operator,
        address _wldToken,
        address _permit2
    ) Ownable(msg.sender) {
        worldId = _worldId;
        appId = _appId;
        worldFoundation = _worldFoundation;
        treasury = _treasury;
        operator = _operator;
        wldToken = IERC20(_wldToken);
        permit2 = ISignatureTransfer(_permit2);
    }

    // 마켓 생성 함수 (Permit2 기반 WLD 결제)
    function createMarket(
        uint256 _root,
        uint256 _sellerNullifierHash,
        uint256[8] calldata _sellerProof,
        WaffleLib.MarketType _mType,
        uint256 _ticketPrice,
        uint256 _goalAmount,
        uint256 _preparedQuantity,
        uint256 _duration,
        uint256 _permitAmount,
        uint256 _permitNonce,
        uint256 _permitDeadline,
        bytes calldata _permitSignature
    ) external returns (address) {

        // 판매자 World ID 검증 (배포 시 주석 해제)
        // IWorldID(worldId).verifyProof(
        //     _root, 1,
        //     ByteHasher.hashToField(abi.encodePacked(msg.sender)),
        //     _sellerNullifierHash,
        //     ByteHasher.hashToField(abi.encodePacked(appId)),
        //     _sellerProof
        // );

        // 두 타입 모두 판매자 보증금 필요 (goalAmount × 15%)
        uint256 requiredDeposit = (_goalAmount * 15) / 100;
        require(_permitAmount >= requiredDeposit, "Insufficient seller deposit");

        // Permit2로 seller에게서 WLD pull
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

        WaffleMarket newMarket = new WaffleMarket(
            msg.sender,              // _seller
            worldId,                 // _worldId
            appId,                   // _appId
            worldFoundation,         // _worldFoundation
            treasury,                // _opsWallet (금고 주소)
            operator,                // _operator
            _mType,                  // _mType
            _ticketPrice,            // _ticketPrice
            _goalAmount,             // _goalAmount
            _preparedQuantity,       // _preparedQuantity
            _duration,               // _duration
            _sellerNullifierHash,    // sellerNullifierHash
            address(wldToken),       // _wldToken
            address(permit2),        // _permit2
            _permitAmount            // _depositAmount
        );

        // WLD를 새 마켓으로 전달
        require(wldToken.transfer(address(newMarket), _permitAmount), "WLD transfer to market failed");

        // 마켓 등록
        address marketAddress = address(newMarket);
        markets.push(marketAddress);
        isMarket[marketAddress] = true;

        uint256 currentMarketId = marketCount;
        marketCount++;

        emit MarketCreated(
            currentMarketId,
            marketAddress,
            msg.sender,
            _mType
        );

        return marketAddress;
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 마켓 응모 프록시 (MiniKit은 Factory 주소만 허용)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function enterMarket(
        address _market,
        uint256 _nullifierHash,
        uint256[8] calldata _proof,
        uint256 _permitAmount,
        uint256 _permitNonce,
        uint256 _permitDeadline,
        bytes calldata _permitSignature
    ) external {
        require(isMarket[_market], "Not a valid market");

        // Permit2로 사용자에게서 WLD pull → Factory
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

        // WLD를 마켓으로 전달
        require(wldToken.transfer(_market, _permitAmount), "WLD transfer to market failed");

        // 마켓에 참가 등록 (Factory 권한)
        WaffleMarket(_market).enterViaFactory(msg.sender, _nullifierHash, _proof);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MVP 단순 추첨+정산 프록시 (MiniKit은 Factory만 허용)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function closeDrawAndSettle(address _market) external {
        require(isMarket[_market], "Not a valid market");
        WaffleMarket(_market).closeDrawAndSettle();
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 보증금 환불 프록시 (MiniKit은 Factory만 허용)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    function claimRefund(address _market) external {
        require(isMarket[_market], "Not a valid market");
        WaffleMarket(_market).claimRefundViaFactory(msg.sender);
    }

    // 조회 함수들
    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }

    function getMarket(uint256 _index) external view returns (address) {
        require(_index < markets.length, "Invalid index");
        return markets[_index];
    }

    function getAllMarkets() external view returns (address[] memory) {
        return markets;
    }

    // 설정 변경 (owner만)
    function updateOperator(address _newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = _newOperator;
        emit OperatorUpdated(oldOperator, _newOperator);
    }

    function updateFeeRecipients(
        address _worldFoundation
    ) external onlyOwner {
        worldFoundation = _worldFoundation;
        emit FeeRecipientsUpdated(_worldFoundation, treasury);
    }
}
