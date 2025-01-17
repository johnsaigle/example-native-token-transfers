// SPDX-License-Identifier: Apache 2
pragma solidity >=0.8.8 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/Manager.sol";
import "../src/interfaces/IManager.sol";
import "../src/interfaces/IRateLimiter.sol";
import "../src/interfaces/IManagerEvents.sol";
import "../src/interfaces/IRateLimiterEvents.sol";
import "../src/libraries/external/OwnableUpgradeable.sol";
import "../src/libraries/external/Initializable.sol";
import "../src/libraries/Implementation.sol";
import {Utils} from "./libraries/Utils.sol";
import {DummyToken, DummyTokenMintAndBurn} from "./Manager.t.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import "../src/libraries/EndpointStructs.sol";
import "./mocks/MockManager.sol";
import "./mocks/MockEndpoints.sol";

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "wormhole-solidity-sdk/interfaces/IWormhole.sol";
import "wormhole-solidity-sdk/testing/helpers/WormholeSimulator.sol";
import "wormhole-solidity-sdk/Utils.sol";

contract TestUpgrades is Test, IManagerEvents, IRateLimiterEvents {
    Manager managerChain1;
    Manager managerChain2;

    using NormalizedAmountLib for uint256;
    using NormalizedAmountLib for NormalizedAmount;

    uint16 constant chainId1 = 7;
    uint16 constant chainId2 = 100;

    uint16 constant SENDING_CHAIN_ID = 1;
    uint256 constant DEVNET_GUARDIAN_PK =
        0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0;
    WormholeSimulator guardian;
    uint256 initialBlockTimestamp;
    uint8 constant FAST_CONSISTENCY_LEVEL = 200;

    WormholeEndpoint wormholeEndpointChain1;
    WormholeEndpoint wormholeEndpointChain2;
    address userA = address(0x123);
    address userB = address(0x456);
    address userC = address(0x789);
    address userD = address(0xABC);

    address relayer = address(0x28D8F1Be96f97C1387e94A53e00eCcFb4E75175a);
    IWormhole wormhole = IWormhole(0x706abc4E45D419950511e474C7B9Ed348A4a716c);

    function setUp() public virtual {
        string memory url = "https://ethereum-goerli.publicnode.com";
        vm.createSelectFork(url);
        initialBlockTimestamp = vm.getBlockTimestamp();

        guardian = new WormholeSimulator(address(wormhole), DEVNET_GUARDIAN_PK);

        vm.chainId(chainId1);
        DummyToken t1 = new DummyToken();
        Manager implementation =
            new MockManagerContract(address(t1), Manager.Mode.LOCKING, chainId1, 1 days);

        managerChain1 = MockManagerContract(address(new ERC1967Proxy(address(implementation), "")));
        managerChain1.initialize();

        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointContract(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain1 = MockWormholeEndpointContract(
            address(new ERC1967Proxy(address(wormholeEndpointChain1Implementation), ""))
        );
        wormholeEndpointChain1.initialize();

        managerChain1.setEndpoint(address(wormholeEndpointChain1));
        managerChain1.setOutboundLimit(type(uint64).max);
        managerChain1.setInboundLimit(type(uint64).max, chainId2);

        // Chain 2 setup
        vm.chainId(chainId2);
        DummyToken t2 = new DummyTokenMintAndBurn();
        Manager implementationChain2 =
            new MockManagerContract(address(t2), Manager.Mode.BURNING, chainId2, 1 days);

        managerChain2 =
            MockManagerContract(address(new ERC1967Proxy(address(implementationChain2), "")));
        managerChain2.initialize();

        WormholeEndpoint wormholeEndpointChain2Implementation = new MockWormholeEndpointContract(
            address(managerChain2),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain2 = MockWormholeEndpointContract(
            address(new ERC1967Proxy(address(wormholeEndpointChain2Implementation), ""))
        );
        wormholeEndpointChain2.initialize();

        managerChain2.setEndpoint(address(wormholeEndpointChain2));
        managerChain2.setOutboundLimit(type(uint64).max);
        managerChain2.setInboundLimit(type(uint64).max, chainId1);

        // Register sibling contracts for the manager and endpoint. Endpoints and manager each have the concept of siblings here.
        managerChain1.setSibling(chainId2, bytes32(uint256(uint160(address(managerChain2)))));
        managerChain2.setSibling(chainId1, bytes32(uint256(uint160(address(managerChain1)))));

        wormholeEndpointChain1.setWormholeSibling(
            chainId2, bytes32(uint256(uint160((address(wormholeEndpointChain2)))))
        );
        wormholeEndpointChain2.setWormholeSibling(
            chainId1, bytes32(uint256(uint160(address(wormholeEndpointChain1))))
        );

        managerChain1.setThreshold(1);
        managerChain2.setThreshold(1);
        vm.chainId(chainId1);
    }

    function test_basicUpgradeManager() public {
        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation = new MockManagerContract(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );
        managerChain1.upgrade(address(newImplementation));

        basicFunctionality();
    }

    //Upgradability stuff for endpoints is real borked because of some missing implementation. Test this later once fixed.
    function test_basicUpgradeEndpoint() public {
        // Basic call to upgrade with the same contact as well
        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointContract(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        basicFunctionality();
    }

    // Confirm that we can handle multiple upgrades as a manager
    function test_doubleUpgradeManager() public {
        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation = new MockManagerContract(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );
        managerChain1.upgrade(address(newImplementation));
        basicFunctionality();

        newImplementation = new MockManagerContract(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );
        managerChain1.upgrade(address(newImplementation));

        basicFunctionality();
    }

    //Upgradability stuff for endpoints is real borked because of some missing implementation. Test this later once fixed.
    function test_doubleUpgradeEndpoint() public {
        // Basic call to upgrade with the same contact as well
        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointContract(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        basicFunctionality();

        // Basic call to upgrade with the same contact as well
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        basicFunctionality();
    }

    function test_storageSlotManager() public {
        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation = new MockManagerStorageLayoutChange(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );
        managerChain1.upgrade(address(newImplementation));

        address oldOwner = managerChain1.owner();
        MockManagerStorageLayoutChange(address(managerChain1)).setData();

        // If we overrode something important, it would probably break here
        basicFunctionality();

        require(oldOwner == managerChain1.owner(), "Owner changed in an unintended way.");
    }

    function test_storageSlotEndpoint() public {
        // Basic call to upgrade with the same contact as ewll
        WormholeEndpoint newImplementation = new MockWormholeEndpointLayoutChange(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain1.upgrade(address(newImplementation));

        address oldOwner = managerChain1.owner();
        MockWormholeEndpointLayoutChange(address(wormholeEndpointChain1)).setData();

        // If we overrode something important, it would probably break here
        basicFunctionality();

        require(oldOwner == managerChain1.owner(), "Owner changed in an unintended way.");
    }

    function test_callMigrateManager() public {
        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation = new MockManagerMigrateBasic(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );

        vm.expectRevert("Proper migrate called");
        managerChain1.upgrade(address(newImplementation));

        basicFunctionality();
    }

    //Upgradability stuff for endpoints is real borked because of some missing implementation. Test this later once fixed.
    function test_callMigrateEndpoint() public {
        // Basic call to upgrade with the same contact as well
        MockWormholeEndpointMigrateBasic wormholeEndpointChain1Implementation = new MockWormholeEndpointMigrateBasic(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );

        vm.expectRevert("Proper migrate called");
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        basicFunctionality();
    }

    function test_immutableBlockUpdateFailureManager() public {
        DummyToken tnew = new DummyToken();

        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation =
            new MockManagerImmutableCheck(address(tnew), Manager.Mode.LOCKING, chainId1, 1 days);

        vm.expectRevert(); // Reverts with a panic on the assert. So, no way to tell WHY this happened.
        managerChain1.upgrade(address(newImplementation));

        require(managerChain1.token() != address(tnew), "Token updated when it shouldn't be");

        basicFunctionality();
    }

    function test_immutableBlockUpdateFailureEndpoint() public {
        // Don't allow upgrade to work with a change immutable

        address oldManager = wormholeEndpointChain1.manager();
        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointMigrateBasic(
            address(managerChain2),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );

        vm.expectRevert(); // Reverts with a panic on the assert. So, no way to tell WHY this happened.
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        require(
            wormholeEndpointChain1.manager() == oldManager, "Manager updated when it shouldn't be"
        );
    }

    function test_immutableBlockUpdateSuccessManager() public {
        DummyToken tnew = new DummyToken();

        // Basic call to upgrade with the same contact as ewll
        Manager newImplementation = new MockManagerImmutableRemoveCheck(
            address(tnew), Manager.Mode.LOCKING, chainId1, 1 days
        );

        // Allow an upgrade, since we enabled the ability to edit the immutables within the code
        managerChain1.upgrade(address(newImplementation));
        require(managerChain1.token() == address(tnew), "Token not updated");

        basicFunctionality();
    }

    function test_immutableBlockUpdateSuccessEndpoint() public {
        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointImmutableAllow(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );

        //vm.expectRevert(); // Reverts with a panic on the assert. So, no way to tell WHY this happened.
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));

        require(
            wormholeEndpointChain1.manager() == address(managerChain1),
            "Manager updated when it shouldn't be"
        );
    }

    function test_authManager() public {
        // User not owner so this should fail
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, userA)
        );
        managerChain1.upgrade(address(0x1));

        // Basic call to upgrade so that we can get the real implementation.
        Manager newImplementation = new MockManagerContract(
            address(managerChain1.token()), Manager.Mode.LOCKING, chainId1, 1 days
        );
        managerChain1.upgrade(address(newImplementation));

        basicFunctionality(); // Ensure that the upgrade was proper

        vm.expectRevert(abi.encodeWithSelector(Implementation.NotMigrating.selector));
        managerChain1.migrate();

        // Test if we can 'migrate' from this point
        // Migrate without delegatecall
        vm.expectRevert(abi.encodeWithSelector(Implementation.OnlyDelegateCall.selector));
        newImplementation.migrate();

        // Transfer the ownership - shouldn't have permission for that
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, userA)
        );
        managerChain1.transferOwnership(address(0x1));

        // Should fail because it's already initialized
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        managerChain1.initialize();

        // Should fail because we're calling the implementation directly instead of the proxy.
        vm.expectRevert(Implementation.OnlyDelegateCall.selector);
        newImplementation.initialize();
    }

    function test_authEndpoint() public {
        // User not owner so this should fail
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, userA)
        );
        wormholeEndpointChain1.upgrade(address(0x01));

        // Basic call so that we can easily see what the new endpoint is.
        WormholeEndpoint wormholeEndpointChain1Implementation = new MockWormholeEndpointContract(
            address(managerChain1),
            address(wormhole),
            address(relayer),
            address(0x0),
            FAST_CONSISTENCY_LEVEL
        );
        wormholeEndpointChain1.upgrade(address(wormholeEndpointChain1Implementation));
        basicFunctionality(); // Ensure that the upgrade was proper

        // Test if we can 'migrate' from this point
        // Migrate without delegatecall
        vm.expectRevert(abi.encodeWithSelector(Implementation.OnlyDelegateCall.selector));
        wormholeEndpointChain1Implementation.migrate();

        // Migrate - should fail since we're executing something outside of a migration
        vm.expectRevert(abi.encodeWithSelector(Implementation.NotMigrating.selector));
        wormholeEndpointChain1.migrate();

        // Transfer the ownership - shouldn't have permission for that
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, userA)
        );
        wormholeEndpointChain1.transferOwnership(address(0x1));

        // Force remove user from ownership
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, userA)
        );
        wormholeEndpointChain1.renounceOwnership();

        // Should fail because it's already initialized
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wormholeEndpointChain1.initialize();

        // // Should fail because we're calling the implementation directly instead of the proxy.
        vm.expectRevert(Implementation.OnlyDelegateCall.selector);
        wormholeEndpointChain1Implementation.initialize();
    }

    function basicFunctionality() public {
        vm.chainId(chainId1);

        // Setting up the transfer
        DummyToken token1 = DummyToken(managerChain1.token());
        DummyToken token2 = DummyTokenMintAndBurn(managerChain2.token());

        uint8 decimals = token1.decimals();
        uint256 sendingAmount = 5 * 10 ** decimals;
        token1.mintDummy(address(userA), 5 * 10 ** decimals);
        vm.startPrank(userA);
        token1.approve(address(managerChain1), sendingAmount);

        vm.recordLogs();

        // Send token through standard means (not relayer)
        {
            uint256 managerBalanceBefore = token1.balanceOf(address(managerChain1));
            uint256 userBalanceBefore = token1.balanceOf(address(userA));
            managerChain1.transfer(
                sendingAmount,
                chainId2,
                bytes32(uint256(uint160(userB))),
                false,
                encodeEndpointInstruction(true)
            );

            // Balance check on funds going in and out working as expected
            uint256 managerBalanceAfter = token1.balanceOf(address(managerChain1));
            uint256 userBalanceAfter = token1.balanceOf(address(userB));
            require(
                managerBalanceBefore + sendingAmount == managerBalanceAfter,
                "Should be locking the tokens"
            );
            require(
                userBalanceBefore - sendingAmount == userBalanceAfter,
                "User should have sent tokens"
            );
        }

        vm.stopPrank();

        // Get and sign the log to go down the other pipe. Thank you to whoever wrote this code in the past!
        Vm.Log[] memory entries = guardian.fetchWormholeMessageFromLog(vm.getRecordedLogs());
        bytes[] memory encodedVMs = new bytes[](entries.length);
        for (uint256 i = 0; i < encodedVMs.length; i++) {
            encodedVMs[i] = guardian.fetchSignedMessageFromLogs(entries[i], chainId1);
        }

        // Chain2 verification and checks
        vm.chainId(chainId2);

        vm.expectRevert(); // Wrong chain receiving the signed VAA
        wormholeEndpointChain1.receiveMessage(encodedVMs[0]);
        {
            uint256 supplyBefore = token2.totalSupply();
            wormholeEndpointChain2.receiveMessage(encodedVMs[0]);
            uint256 supplyAfter = token2.totalSupply();

            require(sendingAmount + supplyBefore == supplyAfter, "Supplies dont match");
            require(token2.balanceOf(userB) == sendingAmount, "User didn't receive tokens");
            require(token2.balanceOf(address(managerChain2)) == 0, "Manager has unintended funds");
        }

        // Can't resubmit the same message twice
        vm.expectRevert(); // TransferAlreadyCompleted error
        wormholeEndpointChain2.receiveMessage(encodedVMs[0]);

        // Go back the other way from a THIRD user
        vm.prank(userB);
        token2.transfer(userC, sendingAmount);

        vm.startPrank(userC);

        token2.approve(address(managerChain2), sendingAmount);
        vm.recordLogs();

        // Supply checks on the transfer
        {
            uint256 supplyBefore = token2.totalSupply();
            managerChain2.transfer(
                sendingAmount,
                chainId1,
                bytes32(uint256(uint160(userD))),
                false,
                encodeEndpointInstruction(true)
            );

            uint256 supplyAfter = token2.totalSupply();

            require(sendingAmount - supplyBefore == supplyAfter, "Supplies don't match");
            require(token2.balanceOf(userB) == 0, "OG user receive tokens");
            require(token2.balanceOf(userC) == 0, "Sending user didn't receive tokens");
            require(
                token2.balanceOf(address(managerChain2)) == 0,
                "Manager didn't receive unintended funds"
            );
        }

        // Get and sign the log to go down the other pipe. Thank you to whoever wrote this code in the past!
        entries = guardian.fetchWormholeMessageFromLog(vm.getRecordedLogs());
        encodedVMs = new bytes[](entries.length);
        for (uint256 i = 0; i < encodedVMs.length; i++) {
            encodedVMs[i] = guardian.fetchSignedMessageFromLogs(entries[i], chainId2);
        }

        // Chain1 verification and checks with the receiving of the message
        vm.chainId(chainId1);

        {
            uint256 supplyBefore = token1.totalSupply();
            uint256 userDBalanceBefore = token1.balanceOf(userD);
            wormholeEndpointChain1.receiveMessage(encodedVMs[0]);

            uint256 supplyAfter = token1.totalSupply();

            require(supplyBefore == supplyAfter, "Supplies don't match between operations");
            require(token1.balanceOf(userB) == 0, "OG user receive tokens");
            require(token1.balanceOf(userC) == 0, "Sending user didn't receive tokens");
            require(
                token1.balanceOf(userD) == sendingAmount + userDBalanceBefore, "User received funds"
            );
        }

        vm.stopPrank();
    }

    function encodeEndpointInstruction(bool relayer_off) public view returns (bytes memory) {
        WormholeEndpoint.WormholeEndpointInstruction memory instruction =
            WormholeEndpoint.WormholeEndpointInstruction(relayer_off);
        bytes memory encodedInstructionWormhole =
            wormholeEndpointChain1.encodeWormholeEndpointInstruction(instruction);
        EndpointStructs.EndpointInstruction memory EndpointInstruction =
            EndpointStructs.EndpointInstruction({index: 0, payload: encodedInstructionWormhole});
        EndpointStructs.EndpointInstruction[] memory EndpointInstructions =
            new EndpointStructs.EndpointInstruction[](1);
        EndpointInstructions[0] = EndpointInstruction;
        return EndpointStructs.encodeEndpointInstructions(EndpointInstructions);
    }
}

contract TestInitialize is Test {
    function setUp() public {}

    Manager managerChain1;
    Manager managerChain2;

    using NormalizedAmountLib for uint256;
    using NormalizedAmountLib for NormalizedAmount;

    uint16 constant chainId1 = 7;

    uint256 constant DEVNET_GUARDIAN_PK =
        0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0;

    WormholeEndpoint wormholeEndpointChain1;
    address userA = address(0x123);

    address relayer = address(0x28D8F1Be96f97C1387e94A53e00eCcFb4E75175a);
    IWormhole wormhole = IWormhole(0x706abc4E45D419950511e474C7B9Ed348A4a716c);

    function test_doubleInitialize() public {
        string memory url = "https://ethereum-goerli.publicnode.com";
        vm.createSelectFork(url);

        vm.chainId(chainId1);
        DummyToken t1 = new DummyToken();
        Manager implementation =
            new MockManagerContract(address(t1), Manager.Mode.LOCKING, chainId1, 1 days);

        managerChain1 = MockManagerContract(address(new ERC1967Proxy(address(implementation), "")));

        // Initialize once
        managerChain1.initialize();

        // Initialize twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        managerChain1.initialize();
    }

    function test_cannotFrontrunInitialize() public {
        string memory url = "https://ethereum-goerli.publicnode.com";
        vm.createSelectFork(url);

        vm.chainId(chainId1);
        DummyToken t1 = new DummyToken();
        Manager implementation =
            new MockManagerContract(address(t1), Manager.Mode.LOCKING, chainId1, 1 days);

        managerChain1 = MockManagerContract(address(new ERC1967Proxy(address(implementation), "")));

        // Attempt to initialize the contract from a non-deployer account.
        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSignature("UnexpectedOwner(address,address)", address(this), userA)
        );
        managerChain1.initialize();
    }
}
