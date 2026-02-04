// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AgentTreasuryCoordinator} from "../src/AgentTreasuryCoordinator.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Base Sepolia USDC
        
        vm.startBroadcast(deployerPrivateKey);
        
        AgentTreasuryCoordinator coordinator = new AgentTreasuryCoordinator(usdc);
        
        vm.stopBroadcast();
    }
}
