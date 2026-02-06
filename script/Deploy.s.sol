// script/Deploy.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/WaffleFactory.sol";

contract DeployFactoryScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address worldIdAddress = vm.envAddress("WORLD_ID_ADDRESS");
        address worldFoundation = vm.envAddress("WORLD_FOUNDATION_ADDRESS");
        address opsWallet = vm.envAddress("OPS_WALLET_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address wldToken = vm.envAddress("WLD_TOKEN_ADDRESS");
        string memory appId = vm.envString("APP_ID");

        // Permit2 canonical address (same on all chains)
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        vm.startBroadcast(deployerPrivateKey);

        WaffleFactory factory = new WaffleFactory(
            worldIdAddress,
            appId,
            worldFoundation,
            opsWallet,  // treasury (immutable)
            operator,
            wldToken,
            permit2
        );

        console.log("WaffleFactory deployed to:", address(factory));

        vm.stopBroadcast();
    }
}
