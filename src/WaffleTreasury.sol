// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title WaffleTreasury
 * @notice 4명의 팀원이 수익을 25%씩 공평하게 나눠 갖는 금고입니다.
 *         WLD 토큰 기반으로 동작합니다.
 */
contract WaffleTreasury {
    IERC20 public immutable wldToken;

    // 팀원 4명의 지갑 주소
    address[] public payees;

    // 지금까지 이 컨트랙트로 들어온 총 금액
    uint256 public totalReceived;

    // 각 팀원이 이미 찾아간 금액 기록
    mapping(address => uint256) public totalReleased;

    event PaymentReceived(address from, uint256 amount);
    event PaymentReleased(address to, uint256 amount);

    constructor(address[] memory _payees, address _wldToken) {
        require(_payees.length == 4, "Must provide exactly 4 payees");
        require(_wldToken != address(0), "Invalid WLD token address");
        payees = _payees;
        wldToken = IERC20(_wldToken);
    }

    /// @notice WLD 토큰을 금고에 입금하는 함수
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        wldToken.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
        emit PaymentReceived(msg.sender, amount);
    }

    // 내 몫을 인출하는 함수 (팀원 누구나 호출 가능)
    function claim() external {
        require(_isPayee(msg.sender), "You are not a payee");

        // 1인당 총 할당량 = (현재까지 들어온 돈) / 4
        uint256 totalShare = totalReceived / payees.length;

        // 내가 지금 찾아갈 수 있는 돈 = (총 할당량) - (이미 찾아간 돈)
        uint256 payment = totalShare - totalReleased[msg.sender];

        require(payment > 0, "Nothing to claim");

        totalReleased[msg.sender] += payment;

        require(wldToken.transfer(msg.sender, payment), "Transfer failed");

        emit PaymentReleased(msg.sender, payment);
    }

    // 현재 인출 가능한 잔액 조회
    function pendingPayment(address _account) external view returns (uint256) {
        if (!_isPayee(_account)) return 0;
        uint256 totalShare = totalReceived / payees.length;
        return totalShare - totalReleased[_account];
    }

    function _isPayee(address _account) internal view returns (bool) {
        for (uint i = 0; i < payees.length; i++) {
            if (payees[i] == _account) return true;
        }
        return false;
    }
}
