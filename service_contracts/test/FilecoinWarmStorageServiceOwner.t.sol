// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Payments} from "@fws-payments/Payments.sol";
import {Errors} from "../src/Errors.sol";
import {MockERC20, MockPDPVerifier} from "./mocks/SharedMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FilecoinWarmStorageServiceOwnerTest is Test {
    using SafeERC20 for MockERC20;

    // Constants
    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        uint8(27)
    );

    // Contracts
    FilecoinWarmStorageService public serviceContract;
    FilecoinWarmStorageServiceStateView public viewContract;
    ServiceProviderRegistry public providerRegistry;
    MockPDPVerifier public pdpVerifier;
    Payments public payments;
    MockERC20 public usdfcToken;
    SessionKeyRegistry public sessionKeyRegistry;

    // Test accounts
    address public owner;
    address public client;
    address public provider1;
    address public provider2;
    address public provider3;
    address public unauthorizedProvider;
    address public filBeamController;
    address public filBeamBeneficiary;

    // Events
    event DataSetServiceProviderChanged(
        uint256 indexed dataSetId, address indexed oldServiceProvider, address indexed newServiceProvider
    );

    function setUp() public {
        // Setup accounts
        owner = address(this);
        client = address(0x1);
        provider1 = address(0x2);
        provider2 = address(0x3);
        provider3 = address(0x4);
        unauthorizedProvider = address(0x5);
        filBeamController = address(0x6);
        filBeamBeneficiary = address(0x7);

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(client, 100 ether);
        vm.deal(provider1, 100 ether);
        vm.deal(provider2, 100 ether);
        vm.deal(provider3, 100 ether);
        vm.deal(unauthorizedProvider, 100 ether);

        // Deploy contracts
        usdfcToken = new MockERC20();
        pdpVerifier = new MockPDPVerifier();
        sessionKeyRegistry = new SessionKeyRegistry();

        // Deploy provider registry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        providerRegistry = ServiceProviderRegistry(address(registryProxy));

        // Register providers
        registerProvider(provider1, "Provider 1");
        registerProvider(provider2, "Provider 2");
        registerProvider(provider3, "Provider 3");
        registerProvider(unauthorizedProvider, "Unauthorized Provider");

        // Deploy payments contract (no longer upgradeable)
        payments = new Payments();

        // Deploy service contract
        FilecoinWarmStorageService serviceImpl = new FilecoinWarmStorageService(
            address(pdpVerifier),
            address(payments),
            usdfcToken,
            filBeamBeneficiary,
            providerRegistry,
            sessionKeyRegistry
        );

        bytes memory serviceInitData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(1440),
            filBeamController,
            "Test Service",
            "Test Description"
        );
        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), serviceInitData);
        serviceContract = FilecoinWarmStorageService(address(serviceProxy));

        // Deploy view contract
        viewContract = new FilecoinWarmStorageServiceStateView(serviceContract);
        serviceContract.setViewContract(address(viewContract));

        // Approve providers 1, 2, and 3 but not unauthorizedProvider
        uint256 providerId1 = providerRegistry.getProviderIdByAddress(provider1);
        uint256 providerId2 = providerRegistry.getProviderIdByAddress(provider2);
        uint256 providerId3 = providerRegistry.getProviderIdByAddress(provider3);

        serviceContract.addApprovedProvider(providerId1);
        serviceContract.addApprovedProvider(providerId2);
        serviceContract.addApprovedProvider(providerId3);

        // Setup USDFC tokens for client
        usdfcToken.safeTransfer(client, 10000e6);

        // Make signatures pass
        makeSignaturePass(client);
    }

    function registerProvider(address provider, string memory name) internal {
        string[] memory capabilityKeys = new string[](0);
        string[] memory capabilityValues = new string[](0);

        vm.prank(provider);
        providerRegistry.registerProvider{value: 5 ether}(
            provider, // payee
            name,
            string.concat(name, " Description"),
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: false,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 5 * 10 ** 6, // 5 USDFC per TiB per month
                    minProvingPeriodInEpochs: 2880,
                    location: "US",
                    paymentTokenAddress: IERC20(address(0))
                })
            ),
            capabilityKeys,
            capabilityValues
        );
    }

    function makeSignaturePass(address signer) internal {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""), // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function createDataSet(address provider, address payer) internal returns (uint256) {
        string[] memory metadataKeys = new string[](1);
        string[] memory metadataValues = new string[](1);
        metadataKeys[0] = "label";
        metadataValues[0] = "Test Data Set";

        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            payer: payer,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup payment approval
        vm.startPrank(payer);
        payments.setOperatorApproval(usdfcToken, address(serviceContract), true, 1000e6, 1000e6, 365 days);
        usdfcToken.approve(address(payments), 100e6);
        payments.deposit(usdfcToken, payer, 100e6);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(payer);
        vm.prank(provider);
        return pdpVerifier.createDataSet(PDPListener(address(serviceContract)), encodedData);
    }

    function testOwnerFieldSetCorrectlyOnDataSetCreation() public {
        console.log("=== Test: Owner field set correctly on data set creation ===");

        uint256 dataSetId = createDataSet(provider1, client);

        // Check that owner is set to the creator (provider1)
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        assertEq(info.serviceProvider, provider1, "Service provider should be set to creator");
        assertEq(info.payer, client, "Payer should be set correctly");
        assertEq(info.payee, provider1, "Payee should be provider's beneficiary");

        console.log("Service provider field correctly set to creator:", provider1);
    }

    function testStorageProviderChangedUpdatesOnlyOwnerField() public {
        console.log("=== Test: storageProviderChanged updates only owner field ===");

        uint256 dataSetId = createDataSet(provider1, client);

        // Get initial state
        FilecoinWarmStorageService.DataSetInfoView memory infoBefore = viewContract.getDataSet(dataSetId);
        assertEq(infoBefore.serviceProvider, provider1, "Initial owner should be provider1");

        // Change storage provider
        vm.expectEmit(true, true, true, true);
        emit DataSetServiceProviderChanged(dataSetId, provider1, provider2);

        vm.prank(provider2);
        pdpVerifier.changeDataSetServiceProvider(dataSetId, provider2, address(serviceContract), new bytes(0));

        // Check updated state
        FilecoinWarmStorageService.DataSetInfoView memory infoAfter = viewContract.getDataSet(dataSetId);

        assertEq(infoAfter.serviceProvider, provider2, "Service provider should be updated to provider2");
        assertEq(infoAfter.payee, provider1, "Payee should remain unchanged");
        assertEq(infoAfter.payer, client, "Payer should remain unchanged");

        console.log("Service provider updated from", provider1, "to", provider2);
        console.log("Payee remained unchanged:", provider1);
    }

    function testStorageProviderChangedRevertsForUnregisteredProvider() public {
        console.log("=== Test: storageProviderChanged reverts for unregistered provider ===");

        uint256 dataSetId = createDataSet(provider1, client);

        address unregisteredAddress = address(0x999);

        // Try to change to unregistered provider
        vm.prank(address(pdpVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotRegistered.selector, unregisteredAddress));
        serviceContract.storageProviderChanged(dataSetId, provider1, unregisteredAddress, new bytes(0));

        console.log("Correctly reverted for unregistered provider");
    }

    function testStorageProviderChangedRevertsForUnapprovedProvider() public {
        console.log("=== Test: storageProviderChanged reverts for unapproved provider ===");

        uint256 dataSetId = createDataSet(provider1, client);

        uint256 unauthorizedProviderId = providerRegistry.getProviderIdByAddress(unauthorizedProvider);

        // Try to change to unapproved provider
        vm.prank(address(pdpVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ProviderNotApproved.selector, unauthorizedProvider, unauthorizedProviderId)
        );
        serviceContract.storageProviderChanged(dataSetId, provider1, unauthorizedProvider, new bytes(0));

        console.log("Correctly reverted for unapproved provider");
    }

    function testStorageProviderChangedRevertsForWrongOldOwner() public {
        console.log("=== Test: storageProviderChanged reverts for wrong old owner ===");

        uint256 dataSetId = createDataSet(provider1, client);

        // Try to change with wrong old owner
        vm.prank(address(pdpVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OldServiceProviderMismatch.selector,
                dataSetId,
                provider1, // actual owner
                provider3 // wrong old owner passed
            )
        );
        serviceContract.storageProviderChanged(
            dataSetId,
            provider3, // wrong old owner
            provider2,
            new bytes(0)
        );

        console.log("Correctly reverted for wrong old owner");
    }

    function testTerminateServiceUsesOwnerForAuthorization() public {
        console.log("=== Test: terminateService uses owner for authorization ===");

        uint256 dataSetId = createDataSet(provider1, client);

        // Change owner to provider2
        vm.prank(provider2);
        pdpVerifier.changeDataSetServiceProvider(dataSetId, provider2, address(serviceContract), new bytes(0));

        // Provider1 (original creator but no longer owner) should not be able to terminate
        vm.prank(provider1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.CallerNotPayerOrPayee.selector,
                dataSetId,
                client, // payer
                provider2, // current owner
                provider1 // caller
            )
        );
        serviceContract.terminateService(dataSetId);

        // Provider2 (current owner) should be able to terminate
        vm.prank(provider2);
        serviceContract.terminateService(dataSetId);

        console.log("Only current owner (provider2) could terminate, not original creator (provider1)");
    }

    function testMultipleOwnerChanges() public {
        console.log("=== Test: Multiple owner changes ===");

        uint256 dataSetId = createDataSet(provider1, client);

        // First change: provider1 -> provider2
        vm.prank(provider2);
        pdpVerifier.changeDataSetServiceProvider(dataSetId, provider2, address(serviceContract), new bytes(0));

        FilecoinWarmStorageService.DataSetInfoView memory info1 = viewContract.getDataSet(dataSetId);
        assertEq(info1.serviceProvider, provider2, "Service provider should be provider2 after first change");

        // Second change: provider2 -> provider3
        vm.prank(provider3);
        pdpVerifier.changeDataSetServiceProvider(dataSetId, provider3, address(serviceContract), new bytes(0));

        FilecoinWarmStorageService.DataSetInfoView memory info2 = viewContract.getDataSet(dataSetId);
        assertEq(info2.serviceProvider, provider3, "Service provider should be provider3 after second change");
        assertEq(info2.payee, provider1, "Payee should still be original provider1");

        console.log("Service provider changed successfully: provider1 -> provider2 -> provider3");
        console.log("Payee remained as provider1 throughout");
    }
}
