// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { Test } from "forge-std/Test.sol";
//solhint-disable-next-line no-console
import { console } from "forge-std/console.sol";
import { WeatherXMMock as WeatherXM} from "src/0.8.25/mocks/WeatherXMMock.sol";
import { RewardPool } from "src/0.8.25/RewardPool.sol";
import { RewardPoolV2 } from "src/0.8.25/mocks/utils/RewardPoolV2.test.sol";
import { RewardsVault } from "src/0.8.25/RewardsVault.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IRewardPool } from "src/0.8.25/interfaces/IRewardPool.sol";
import { RLPReader } from "solidity-rlp/RLPReader.sol";
import { Merkle } from "murky/Merkle.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

bytes32 constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

contract RewardPoolTest is Test {
  IRewardPool public rewardImplementation;
  WeatherXM public weatherXM;
  address internal alice;
  address internal bob;
  address internal treasury;
  address internal owner = address(0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84);
  ERC1967Proxy public proxy;
  RewardPool public wrappedProxyV1;
  RewardPoolV2 public wrappedProxyV2;
  RewardsVault public rewardsVault;

  ERC1967Proxy public mintingManagerProxy;
  // RewardPoolV2 public mintingManagerWrappedProxyV2;

  bytes32 root;
  Merkle m;
  bytes32[100] data;
  bytes resultData;
  bytes resultProofs;
  bytes resultRoot;
  using RLPReader for RLPReader.RLPItem;
  using RLPReader for RLPReader.Iterator;
  using RLPReader for bytes;
  uint8[10] leaves = [3, 6, 8, 13, 16, 34, 45, 67, 87, 92];
  uint256 public constant maxDailyEmission = 14246 * 10 ** 18;

  function setUp() external {
    string[] memory inputs = new string[](2);
    inputs[0] = "cat";
    inputs[1] = "test/0.8.25/scripts/data/data_serialized.txt";
    resultData = vm.ffi(inputs);
    data = abi.decode(resultData, (bytes32[100]));
    string[] memory inputProofs = new string[](2);
    inputProofs[0] = "cat";
    inputProofs[1] = "test/0.8.25/scripts/data/proofs_serialized.txt";
    resultProofs = vm.ffi(inputProofs);
    string[] memory inputRoot = new string[](2);
    inputRoot[0] = "cat";
    inputRoot[1] = "test/0.8.25/scripts/data/root.txt";
    resultRoot = vm.ffi(inputRoot);
    root = abi.decode(resultRoot, (bytes32));
    emit log_bytes(resultRoot.toRlpItem().toBytes());
    m = new Merkle();
    vm.startPrank(owner);
    weatherXM = new WeatherXM("WeatherXM", "WXM");
    vm.label(owner, "Owner");
    alice = address(0x1);
    vm.label(alice, "Alice");
    bob = address(0x2);
    vm.label(bob, "Bob");
    treasury = address(0x3);
    vm.label(treasury, "Treasury");
    rewardImplementation = new RewardPool();
    proxy = new ERC1967Proxy(address(rewardImplementation), "");
    rewardsVault = new RewardsVault(IERC20(weatherXM), owner);
    wrappedProxyV1 = RewardPool(address(proxy));
    wrappedProxyV1.initialize(address(weatherXM), address(rewardsVault), treasury);
    rewardsVault.setRewardDistributor(address(wrappedProxyV1));
    // Transfer the 56M from total supply to the reward pool
    weatherXM.transfer(address(rewardsVault), 56 * 1e6 * 10 ** 18);
    vm.stopPrank();
  }

  function testDeployerHasDefaultAdminRole() public {
    assertEq(wrappedProxyV1.hasRole(0x0000000000000000000000000000000000000000000000000000000000000000, owner), true);
  }

  function testCanUpgrade() public {
    vm.startPrank(owner);
    RewardPoolV2 implementationV2 = new RewardPoolV2();
    wrappedProxyV1.upgradeTo(address(implementationV2));
    // re-wrap the proxy
    wrappedProxyV2 = RewardPoolV2(address(proxy));
    assertEq(wrappedProxyV2.version(), "V2");
    vm.stopPrank();
  }

  function testContructor() public {
    address token = address(wrappedProxyV1.token());

    bool hasDistributorRole = wrappedProxyV1.hasRole(wrappedProxyV1.DISTRIBUTOR_ROLE(), owner);
    bool hasUpgraderRole = wrappedProxyV1.hasRole(wrappedProxyV1.UPGRADER_ROLE(), owner);
    bool hasAdminRole = wrappedProxyV1.hasRole(wrappedProxyV1.DEFAULT_ADMIN_ROLE(), owner);

    assertEq(token, address(weatherXM));
    assertEq(hasDistributorRole, true);
    assertEq(hasUpgraderRole, true);
    assertEq(hasAdminRole, true);
  }

  function testGetRemainingAllocatedRewards() public {
    vm.startPrank(owner);
    wrappedProxyV1.grantRole(DISTRIBUTOR_ROLE, bob);
    vm.stopPrank();
    vm.startPrank(bob);
    wrappedProxyV1.submitMerkleRoot(root, maxDailyEmission, 0);
    for (uint i = 0; i < leaves.length; ++i) {
      RLPReader.RLPItem[] memory rewards = resultData.toRlpItem().toList();
      RLPReader.RLPItem[] memory proofsEncoded = resultProofs.toRlpItem().toList();
      bytes32[] memory _proof = new bytes32[](proofsEncoded[i].toList().length);
      for (uint j = 0; j < proofsEncoded[i].toList().length; ++j) {
        //  emit log_bytes(proofsEncoded[i].toList()[j].toBytes());
        _proof[j] = bytes32(proofsEncoded[i].toList()[j].toBytes());
      }
      uint256 remainingBalance = wrappedProxyV1.getRemainingAllocatedRewards(
        bytesToAddress(rewards[leaves[i]].toList()[0].toBytes()),
        10000000000000000000,
        0,
        _proof
      );
      assertEq(remainingBalance, 10 * 10 ** 18);
    }
    vm.stopPrank();
  }

  function testThrowWhenInvalidProof() public {
    vm.startPrank(owner);
    wrappedProxyV1.grantRole(DISTRIBUTOR_ROLE, bob);
    vm.stopPrank();
    vm.startPrank(bob);
    wrappedProxyV1.submitMerkleRoot(root, maxDailyEmission, 0);
    for (uint i = 0; i < leaves.length; ++i) {
      RLPReader.RLPItem[] memory rewards = resultData.toRlpItem().toList();
      RLPReader.RLPItem[] memory proofsEncoded = resultProofs.toRlpItem().toList();
      bytes32[] memory _proof = new bytes32[](proofsEncoded[i].toList().length);
      for (uint j = 0; j < proofsEncoded[i].toList().length; ++j) {
        //  emit log_bytes(proofsEncoded[i].toList()[j].toBytes());
        _proof[j] = bytes32(proofsEncoded[i].toList()[j].toBytes());
      }
      uint256 remainingBalance = wrappedProxyV1.getRemainingAllocatedRewards(
        bytesToAddress(rewards[leaves[i]].toList()[0].toBytes()),
        10000000000000000000,
        0,
        _proof
      );
      assertEq(remainingBalance, 10 * 10 ** 18);
    }
    vm.stopPrank();
  }

  function testThrowWhenInvalidProofFuzz(address _address) public {
    vm.startPrank(owner);
    wrappedProxyV1.grantRole(DISTRIBUTOR_ROLE, bob);
    vm.stopPrank();
    vm.startPrank(bob);
    wrappedProxyV1.submitMerkleRoot(root, maxDailyEmission, 0);
    RLPReader.RLPItem[] memory rewards = resultData.toRlpItem().toList();
    RLPReader.RLPItem[] memory proofsEncoded = resultProofs.toRlpItem().toList();
    bytes32[] memory _proof = new bytes32[](proofsEncoded[0].toList().length);
    for (uint j = 0; j < proofsEncoded[0].toList().length; ++j) {
      emit log_bytes(proofsEncoded[0].toList()[j].toBytes());
      _proof[j] = bytes32(proofsEncoded[0].toList()[j].toBytes());
    }
    uint256 remainingBalance = wrappedProxyV1.getRemainingAllocatedRewards(
      bytesToAddress(rewards[leaves[0]].toList()[0].toBytes()),
      10000000000000000000,
      0,
      _proof
    );
    vm.stopPrank();
    vm.startPrank(_address);
    vm.expectRevert(bytes("INVALID PROOF"));
    wrappedProxyV1.claim(remainingBalance, 10000000000000000000, 1, _proof);
    vm.stopPrank();
  }

  function testClaimFuzz(uint256 amount) public {
    vm.startPrank(owner);
    wrappedProxyV1.grantRole(DISTRIBUTOR_ROLE, bob);
    vm.stopPrank();
    vm.startPrank(bob);
    wrappedProxyV1.submitMerkleRoot(root, maxDailyEmission, 0);
    RLPReader.RLPItem[] memory rewards = resultData.toRlpItem().toList();
    RLPReader.RLPItem[] memory proofsEncoded = resultProofs.toRlpItem().toList();
    bytes32[] memory _proof = new bytes32[](proofsEncoded[0].toList().length);
    for (uint j = 0; j < proofsEncoded[0].toList().length; ++j) {
      emit log_bytes(proofsEncoded[0].toList()[j].toBytes());
      _proof[j] = bytes32(proofsEncoded[0].toList()[j].toBytes());
    }
    uint256 remainingBalance = wrappedProxyV1.getRemainingAllocatedRewards(
      bytesToAddress(rewards[leaves[0]].toList()[0].toBytes()),
      10000000000000000000,
      0,
      _proof
    );
    vm.stopPrank();
    vm.startPrank(address(bytesToAddress(rewards[leaves[0]].toList()[0].toBytes())));
    if (amount > remainingBalance) {
      vm.expectRevert(IRewardPool.AmountIsOverAvailableRewardsToClaim.selector);
      wrappedProxyV1.claim(amount, 10000000000000000000, 0, _proof);
    } else if (amount == 0) {
      vm.expectRevert(IRewardPool.AmountRequestedIsZero.selector);
      wrappedProxyV1.claim(amount, 10000000000000000000, 0, _proof);
    } else {
      wrappedProxyV1.claim(amount, 10000000000000000000, 0, _proof);
    }
    vm.stopPrank();
  }

  function testCompatabilityOpenZeppelinProver(bytes32[] memory _data, uint256 node) public {
    vm.assume(_data.length > 1);
    vm.assume(node < _data.length);
    root = m.getRoot(_data);
    bytes32[] memory proof = m.getProof(_data, node);
    bytes32 valueToProve = _data[node];
    bool murkyVerified = m.verifyProof(root, proof, valueToProve);
    bool ozVerified = MerkleProof.verify(proof, root, valueToProve);
    assertTrue(murkyVerified == ozVerified);
  }

  function testPuaseUnpause() public {
    vm.startPrank(owner);

    wrappedProxyV1.pause();

    assertEq(wrappedProxyV1.paused(), true);

    wrappedProxyV1.unpause();

    assertEq(wrappedProxyV1.paused(), false);

    vm.stopPrank();
  }

  function testPuaseUnpauseMissingRole() public {
    vm.startPrank(alice);

    vm.expectRevert(
      "AccessControl: account 0x0000000000000000000000000000000000000001 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
    );
    wrappedProxyV1.pause();

    assertEq(wrappedProxyV1.paused(), false);

    vm.stopPrank();
    vm.startPrank(owner);

    wrappedProxyV1.pause();

    vm.stopPrank();
    vm.startPrank(alice);

    vm.expectRevert(
      "AccessControl: account 0x0000000000000000000000000000000000000001 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
    );
    wrappedProxyV1.unpause();

    assertEq(wrappedProxyV1.paused(), true);

    vm.stopPrank();
  }

  function testTransferChangeToTreasury() public {
    vm.startPrank(owner);
    wrappedProxyV1.grantRole(DISTRIBUTOR_ROLE, bob);
    vm.stopPrank();
    vm.startPrank(bob);
    assertEq(weatherXM.balanceOf(address(treasury)), 0);
    uint256 totalRewards = 10246 * 10 ** 18;
    wrappedProxyV1.submitMerkleRoot(root, totalRewards, 0);
    assertEq(weatherXM.balanceOf(address(treasury)), maxDailyEmission - totalRewards);
    assertEq(weatherXM.balanceOf(address(wrappedProxyV1)), totalRewards);
    vm.stopPrank();
  }

  function _getData() internal view returns (bytes32[] memory) {
    bytes32[] memory _data = new bytes32[](data.length);
    uint length = data.length;
    for (uint i = 0; i < length; ++i) {
      _data[i] = data[i];
    }
    return _data;
  }

  function bytesToAddress(bytes memory b) internal pure returns (address addr) {
    assembly {
      addr := mload(add(b, 20))
    }
  }
}
