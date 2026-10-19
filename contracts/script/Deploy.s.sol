// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HonkVerifier, IVerifier} from "../src/Verifier.sol";
import {BorrowHonkVerifier} from "../src/BorrowVerifier.sol";
import {HushfundVault} from "../src/HushfundVault.sol";
import {Poseidon2Yul_BN254} from "../src/vendor/Poseidon2Yul.sol";
import {IPoseidon2} from "../src/vendor/IPoseidon2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {IMorphoVault} from "../src/interfaces/IMorphoPool.sol";

/// @notice Deploys Hushfund from ../config/<network>.json and writes the addresses to ../deployments/<network>.json.
///
///   forge script script/Deploy.s.sol --sig "run(string)" mainnet --rpc-url $MAINNET_RPC_URL --broadcast --verify
///
/// Use --account <keystore name> (cast wallet import) or --ledger rather than a raw private key on mainnet.
contract Deploy is Script {
    struct Cfg {
        uint256 chainId;
        address owner;
        address feeRecipient;
        uint256 feeBps;
        uint256[] denominations;
        uint32 depth;
        address usdc;
        bool mocks;
        address aavePool;
        address aToken;
        address morphoVault;
    }

    function run(string memory network) external {
        require(keccak256(bytes(network)) == keccak256(bytes("mainnet")), "Only Ethereum Mainnet is supported");
        Cfg memory c = _load(network);
        require(c.chainId == 1 && !c.mocks, "Mainnet requires chain ID 1 and real strategies");
        require(block.chainid == c.chainId, "RPC chain id does not match the config file");
        require(c.owner != address(0), "Set `owner` in the config (use a multisig such as Safe on mainnet)");
        require(c.feeRecipient != address(0), "Set `feeRecipient` in the config");
        require(c.denominations.length > 0, "Set at least one value in `denominationsUsdc`");

        vm.startBroadcast();

        require(c.aavePool.code.length > 0 && c.aToken.code.length > 0 && c.morphoVault.code.length > 0, "strategy address has no code");

        Shared memory sh;
        sh.hasher = IPoseidon2(address(new Poseidon2Yul_BN254()));
        sh.withdrawVerifier = IVerifier(address(new HonkVerifier()));
        sh.borrowVerifier = IVerifier(address(new BorrowHonkVerifier()));

        address[] memory vaults = new address[](c.denominations.length);
        for (uint256 i = 0; i < c.denominations.length; i++) {
            vaults[i] = _deployVault(c, sh, c.denominations[i] * 1e6);
            console.log("Vault", c.denominations[i], "USDC:", vaults[i]);
        }

        vm.stopBroadcast();

        _write(network, c, address(sh.hasher), address(sh.withdrawVerifier), address(sh.borrowVerifier), vaults);
    }

    struct Shared {
        IPoseidon2 hasher;
        IVerifier withdrawVerifier;
        IVerifier borrowVerifier;
    }

    function _deployVault(Cfg memory c, Shared memory sh, uint256 denomination) internal returns (address) {
        return address(
            new HushfundVault(
                sh.withdrawVerifier,
                sh.borrowVerifier,
                sh.hasher,
                c.depth,
                denomination,
                IERC20(c.usdc),
                IAavePool(c.aavePool),
                IERC20(c.aToken),
                IMorphoVault(c.morphoVault),
                c.owner,
                c.feeRecipient,
                c.feeBps
            )
        );
    }

    function _load(string memory network) internal view returns (Cfg memory c) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/", network, ".json"));
        c.chainId = vm.parseJsonUint(json, ".chainId");
        c.owner = vm.parseJsonAddress(json, ".owner");
        c.feeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        c.feeBps = vm.parseJsonUint(json, ".withdrawalFeeBps");
        c.denominations = vm.parseJsonUintArray(json, ".denominationsUsdc");
        c.depth = uint32(vm.parseJsonUint(json, ".merkleTreeDepth"));
        c.usdc = vm.parseJsonAddress(json, ".usdc");
        c.mocks = vm.parseJsonBool(json, ".useMockStrategies");
        c.aavePool = vm.parseJsonAddress(json, ".aavePool");
        c.aToken = vm.parseJsonAddress(json, ".aaveAToken");
        c.morphoVault = vm.parseJsonAddress(json, ".morphoVault");
    }

    function _write(
        string memory network,
        Cfg memory c,
        address hasher,
        address withdrawVerifier,
        address borrowVerifier,
        address[] memory vaults
    ) internal {
        string memory list = "[";
        for (uint256 i = 0; i < vaults.length; i++) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"denominationUsdc":',
                vm.toString(c.denominations[i]),
                ',"address":"',
                vm.toString(vaults[i]),
                '"}'
            );
        }
        list = string.concat(list, "]");

        string memory head = string.concat(
            "{\n",
            '  "network": "', network, '",\n',
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "deployBlock": ', vm.toString(block.number), ",\n"
        );
        string memory core = string.concat(
            '  "poseidon2": "', vm.toString(hasher), '",\n',
            '  "withdrawVerifier": "', vm.toString(withdrawVerifier), '",\n',
            '  "borrowVerifier": "', vm.toString(borrowVerifier), '",\n'
        );
        string memory strategies = string.concat(
            '  "aavePool": "', vm.toString(c.aavePool), '",\n',
            '  "aaveAToken": "', vm.toString(c.aToken), '",\n',
            '  "morphoVault": "', vm.toString(c.morphoVault), '",\n'
        );
        string memory out = string.concat(head, core, strategies, '  "vaults": ', list, "\n}\n");
        string memory path = string.concat(vm.projectRoot(), "/../deployments/", network, ".json");
        vm.writeFile(path, out);
        console.log("Wrote", path);
    }
}
