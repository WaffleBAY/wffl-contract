// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { WaffleTreasury } from "../src/WaffleTreasury.sol";
import { WaffleFactory } from "../src/WaffleFactory.sol";
import { MockWLD } from "../src/test/MockWLD.sol";

contract DeploySystem is Script {
    // Permit2 canonical address (same on all chains)
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("APP_ID");

        // World ID Router (from env: mainnet or sepolia)
        address worldIdRouter = vm.envAddress("WORLD_ID_ADDRESS");

        // 지갑 주소 설정
        address deployer = vm.addr(deployerPrivateKey);
        address foundationWallet = vm.envAddress("WORLD_FOUNDATION_ADDRESS");
        address operator = deployer;

        // WLD token address: use env if set, otherwise deploy MockWLD
        address wldToken;
        bool deployMock = vm.envOr("DEPLOY_MOCK_WLD", true);

        address[] memory teamMembers = new address[](4);
        teamMembers[0] = deployer;
        teamMembers[1] = 0xc0Ee55c4d1f05730FFAe7ad09AF5f8c7d5bcD7FC; // 박훈일
        teamMembers[2] = 0xc3555D7DB235D326ced112Db50290bE881FFa4BF; // 오창현
        teamMembers[3] = 0x4986B11281DE2d9Fe721dB0d1250d0e4897a84B1; // 권상현

        vm.startBroadcast(deployerPrivateKey);

        // 0. WLD 토큰 (테스트넷에서는 MockWLD 배포)
        if (deployMock) {
            MockWLD mockWld = new MockWLD();
            wldToken = address(mockWld);
            console.log("MockWLD Deployed at:", wldToken);
            // 테스트용으로 deployer에게 10000 WLD 발행
            mockWld.mint(deployer, 10000 * 1e18);
        } else {
            wldToken = vm.envAddress("WLD_TOKEN_ADDRESS");
            console.log("Using existing WLD at:", wldToken);
        }

        // 1. 금고(Treasury) 배포
        WaffleTreasury treasury = new WaffleTreasury(teamMembers, wldToken);
        console.log("Treasury Deployed at:", address(treasury));

        // 2. 공장(Factory) 배포
        WaffleFactory factory = new WaffleFactory(
            worldIdRouter,
            appId,
            foundationWallet,
            address(treasury),
            operator,
            wldToken,
            PERMIT2
        );
        console.log("Factory Deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
