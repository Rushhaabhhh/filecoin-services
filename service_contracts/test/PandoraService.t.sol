// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console, Vm} from "forge-std/Test.sol";
import {PDPListener, PDPVerifier} from "@pdp/PDPVerifier.sol";
import {PandoraService} from "../src/PandoraService.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Cids} from "@pdp/Cids.sol";
import {Payments, IValidator} from "@fws-payments/Payments.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Mock implementation of the USDFC token
contract MockERC20 is IERC20, IERC20Metadata {
    string private _name = "USD Filecoin";
    string private _symbol = "USDFC";
    uint8 private _decimals = 6;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor() {
        _mint(msg.sender, 1000000 * 10 ** _decimals); // Mint 1 million tokens to deployer
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

// MockPDPVerifier is used to simulate the PDPVerifier for our tests
contract MockPDPVerifier {
    uint256 public nextDataSetId = 1;

    // Track data set storage providers for testing
    mapping(uint256 => address) public dataSetStorageProviders;

    event DataSetCreated(uint256 indexed setId, address indexed owner);
    event DataSetStorageProviderChanged(
        uint256 indexed setId, address indexed oldStorageProvider, address indexed newStorageProvider
    );

    // Basic implementation to create data sets and call the listener
    function createDataSet(address listenerAddr, bytes calldata extraData) public payable returns (uint256) {
        uint256 setId = nextDataSetId++;

        // Call the listener if specified
        if (listenerAddr != address(0)) {
            PDPListener(listenerAddr).dataSetCreated(setId, msg.sender, extraData);
        }

        // Track storage provider
        dataSetStorageProviders[setId] = msg.sender;

        emit DataSetCreated(setId, msg.sender);
        return setId;
    }

    /**
     * @notice Simulates storage provider change for testing purposes
     * @dev This function mimics the PDPVerifier's claimDataSetOwnership functionality
     * @param dataSetId The ID of the data set
     * @param newStorageProvider The new storage provider address
     * @param listenerAddr The listener contract address
     * @param extraData Additional data to pass to the listener
     */
    function changeDataSetStorageProvider(
        uint256 dataSetId,
        address newStorageProvider,
        address listenerAddr,
        bytes calldata extraData
    ) external {
        require(dataSetStorageProviders[dataSetId] != address(0), "Data set does not exist");
        require(newStorageProvider != address(0), "New storage provider cannot be zero address");

        address oldStorageProvider = dataSetStorageProviders[dataSetId];
        require(
            oldStorageProvider != newStorageProvider,
            "New storage provider must be different from current storage provider"
        );

        // Update storage provider
        dataSetStorageProviders[dataSetId] = newStorageProvider;

        // Call the listener's storageProviderChanged function
        if (listenerAddr != address(0)) {
            PDPListener(listenerAddr).storageProviderChanged(
                dataSetId, oldStorageProvider, newStorageProvider, extraData
            );
        }

        emit DataSetStorageProviderChanged(dataSetId, oldStorageProvider, newStorageProvider);
    }

    /**
     * @notice Get the current storage provider of a data set
     * @param dataSetId The ID of the data set
     * @return The current storage provider address
     */
    function getDataSetStorageProvider(uint256 dataSetId) external view returns (address) {
        return dataSetStorageProviders[dataSetId];
    }
}

contract PandoraServiceTest is Test {
    // Testing Constants
    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    // Contracts
    PandoraService public pdpServiceWithPayments;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;

    // Test accounts
    address public deployer;
    address public client;
    address public storageProvider;

    // Additional test accounts for registry tests
    address public sp1;
    address public sp2;
    address public sp3;

    // Test parameters
    uint256 public initialOperatorCommissionBps = 500; // 5%
    uint256 public dataSetId;
    bytes public extraData;

    // Test URLs and peer IDs for registry
    string public validServiceUrl = "https://sp1.example.com";
    string public validServiceUrl2 = "http://sp2.example.com:8080";
    bytes public validPeerId = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070809";
    bytes public validPeerId2 = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070810";

    // Events from Payments contract to verify
    event RailCreated(
        uint256 indexed railId,
        address indexed payer,
        address indexed payee,
        address token,
        address operator,
        address validator,
        address serviceFeeRecipient,
        uint256 commissionRateBps
    );

    // Registry events to verify
    event ProviderRegistered(address indexed provider, string serviceURL, bytes peerId);
    event ProviderApproved(address indexed provider, uint256 indexed providerId);
    event ProviderRejected(address indexed provider);
    event ProviderRemoved(address indexed provider, uint256 indexed providerId);

    // Storage provider change event to verify
    event DataSetStorageProviderChanged(
        uint256 indexed dataSetId, address indexed oldStorageProvider, address indexed newStorageProvider
    );

    function setUp() public {
        // Setup test accounts
        deployer = address(this);
        client = address(0xf1);
        storageProvider = address(0xf2);

        // Additional accounts for registry tests
        sp1 = address(0xf3);
        sp2 = address(0xf4);
        sp3 = address(0xf5);

        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(client, 100 ether);
        vm.deal(storageProvider, 100 ether);
        vm.deal(sp1, 100 ether);
        vm.deal(sp2, 100 ether);
        vm.deal(sp3, 100 ether);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Transfer tokens to client for payment
        mockUSDFC.transfer(client, 10000 * 10 ** mockUSDFC.decimals());

        // Deploy PandoraService with proxy
        PandoraService pdpServiceImpl = new PandoraService();
        bytes memory initializeData = abi.encodeWithSelector(
            PandoraService.initialize.selector,
            address(mockPDPVerifier),
            address(payments),
            address(mockUSDFC),
            initialOperatorCommissionBps,
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy pdpServiceProxy = new MyERC1967Proxy(address(pdpServiceImpl), initializeData);
        pdpServiceWithPayments = PandoraService(address(pdpServiceProxy));
    }

    function makeSignaturePass(address signer) public {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""), // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function testInitialState() public view {
        assertEq(
            pdpServiceWithPayments.pdpVerifierAddress(),
            address(mockPDPVerifier),
            "PDP verifier address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.paymentsContractAddress(),
            address(payments),
            "Payments contract address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.usdfcTokenAddress(),
            address(mockUSDFC),
            "USDFC token address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.operatorCommissionBps(),
            initialOperatorCommissionBps,
            "Operator commission should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.basicServiceCommissionBps(),
            0, // 0%
            "Basic service commission should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.cdnServiceCommissionBps(),
            4000, // 40%
            "CDN service commission should be set correctly"
        );
        assertEq(pdpServiceWithPayments.getMaxProvingPeriod(), 2880, "Max proving period should be set correctly");
        assertEq(pdpServiceWithPayments.challengeWindow(), 60, "Challenge window size should be set correctly");
        assertEq(
            pdpServiceWithPayments.maxProvingPeriod(),
            2880,
            "Max proving period storage variable should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.challengeWindowSize(),
            60,
            "Challenge window size storage variable should be set correctly"
        );
        assertEq(pdpServiceWithPayments.tokenDecimals(), mockUSDFC.decimals(), "Token decimals should be correct");

        // Check fee constants are correctly calculated based on token decimals
        uint256 expectedDataSetCreationFee = (1 * 10 ** mockUSDFC.decimals()) / 10; // 0.1 USDFC
        assertEq(
            pdpServiceWithPayments.DATA_SET_CREATION_FEE(),
            expectedDataSetCreationFee,
            "Data set creation fee should be set correctly"
        );
    }

    function testCreateDataSetCreatesRailAndChargesFee() public {
        // First approve the storage provider
        vm.prank(storageProvider);
        pdpServiceWithPayments.registerServiceProvider("https://sp.example.com/pdp", "https://sp.example.com/retrieve");
        pdpServiceWithPayments.approveServiceProvider(storageProvider);

        // Prepare ExtraData
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: true
        });

        // Encode the extra data
        extraData = abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for the one-time fee
        uint256 depositAmount = 10 * pdpServiceWithPayments.DATA_SET_CREATION_FEE(); // 10x the required fee
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        // Get account balances before creating data set
        (uint256 clientFundsBefore,) = getAccountInfo(address(mockUSDFC), client);
        (uint256 spFundsBefore,) = getAccountInfo(address(mockUSDFC), storageProvider);

        // Expect RailCreated event when creating the data set
        vm.expectEmit(true, true, true, true);
        emit PandoraService.DataSetRailCreated(1, 1, client, storageProvider, true);

        // Create a data set as the storage provider
        makeSignaturePass(client);
        vm.startPrank(storageProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), extraData);
        vm.stopPrank();

        // Get the rail ID from the PDP service
        uint256 railId = pdpServiceWithPayments.getDataSetRailId(newDataSetId);

        // Verify a valid rail ID was created
        assertTrue(railId > 0, "Rail ID should be non-zero");

        // Verify data set info was stored correctly
        (address payer, address payee) = pdpServiceWithPayments.getDataSetParties(newDataSetId);
        assertEq(payer, client, "Payer should be set to client");
        assertEq(payee, storageProvider, "Payee should be set to storage provider");

        // Verify metadata was stored correctly
        string memory metadata = pdpServiceWithPayments.getDataSetMetadata(newDataSetId);
        assertEq(metadata, "Test Data Set", "Metadata should be stored correctly");

        // Verify data set info
        PandoraService.DataSetInfo memory dataSetInfo = pdpServiceWithPayments.getDataSet(newDataSetId);
        assertEq(dataSetInfo.railId, railId, "Rail ID should match");
        assertEq(dataSetInfo.payer, client, "Payer should match");
        assertEq(dataSetInfo.payee, storageProvider, "Payee should match");
        assertEq(dataSetInfo.withCDN, true, "withCDN should be true");

        // Verify withCDN was stored correctly
        bool withCDN = pdpServiceWithPayments.getDataSetWithCDN(newDataSetId);
        assertTrue(withCDN, "withCDN should be true");

        // Verify the rail in the actual Payments contract
        Payments.RailView memory rail = payments.getRail(railId);

        assertEq(rail.token, address(mockUSDFC), "Token should be USDFC");
        assertEq(rail.from, client, "From address should be client");
        assertEq(rail.to, storageProvider, "To address should be storage provider");
        assertEq(rail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(rail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(rail.commissionRateBps, 4000, "Commission rate should match the CDN service rate (40%)");

        // Verify lockupFixed is 0 since the one-time payment was made
        assertEq(rail.lockupFixed, 0, "Lockup fixed should be 0 after one-time payment");

        // Verify initial payment rate is 0 (will be updated when roots are added)
        assertEq(rail.paymentRate, 0, "Initial payment rate should be 0");

        // Get account balances after creating data set
        (uint256 clientFundsAfter,) = getAccountInfo(address(mockUSDFC), client);
        (uint256 spFundsAfter,) = getAccountInfo(address(mockUSDFC), storageProvider);

        // Calculate expected client balance
        uint256 expectedClientFundsAfter = clientFundsBefore - pdpServiceWithPayments.DATA_SET_CREATION_FEE();

        // Verify balances changed correctly (one-time fee transferred)
        assertEq(
            clientFundsAfter, expectedClientFundsAfter, "Client funds should decrease by the data set creation fee"
        );
        assertTrue(spFundsAfter > spFundsBefore, "Storage provider funds should increase");
    }

    function testCreateDataSetNoCDN() public {
        // First approve the storage provider
        vm.prank(storageProvider);
        pdpServiceWithPayments.registerServiceProvider("https://sp.example.com/pdp", "https://sp.example.com/retrieve");
        pdpServiceWithPayments.approveServiceProvider(storageProvider);

        // Prepare ExtraData
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: false
        });

        // Encode the extra data
        extraData = abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for the one-time fee
        uint256 depositAmount = 10 * pdpServiceWithPayments.DATA_SET_CREATION_FEE(); // 10x the required fee
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        // Expect RailCreated event when creating the data set
        vm.expectEmit(true, true, true, true);
        emit PandoraService.DataSetRailCreated(1, 1, client, storageProvider, false);

        // Create a data set as the storage provider
        makeSignaturePass(client);
        vm.startPrank(storageProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), extraData);
        vm.stopPrank();

        // Verify withCDN was stored correctly
        bool withCDN = pdpServiceWithPayments.getDataSetWithCDN(newDataSetId);
        assertFalse(withCDN, "withCDN should be false");

        // Verify the commission rate was set correctly for basic service (no CDN)
        uint256 railId = pdpServiceWithPayments.getDataSetRailId(newDataSetId);
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(rail.commissionRateBps, 0, "Commission rate should be 0% for basic service (no CDN)");
    }

    // Helper function to get account info from the Payments contract
    function getAccountInfo(address token, address owner)
        internal
        view
        returns (uint256 funds, uint256 lockupCurrent)
    {
        (funds, lockupCurrent,,) = payments.accounts(token, owner);
        return (funds, lockupCurrent);
    }

    // Constants for calculations
    uint256 constant COMMISSION_MAX_BPS = 10000;

    function testGlobalParameters() public view {
        // These parameters should be the same as in SimplePDPService
        assertEq(pdpServiceWithPayments.getMaxProvingPeriod(), 2880, "Max proving period should be 2880 epochs");
        assertEq(pdpServiceWithPayments.challengeWindow(), 60, "Challenge window should be 60 epochs");
        assertEq(pdpServiceWithPayments.getChallengesPerProof(), 5, "Challenges per proof should be 5");
    }

    // ===== Storage Provider Registry Tests =====

    function testRegisterServiceProvider() public {
        vm.startPrank(sp1);

        vm.expectEmit(true, false, false, true);
        emit ProviderRegistered(sp1, validServiceUrl, validPeerId);

        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        vm.stopPrank();

        // Verify pending registration
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertEq(pending.serviceURL, validServiceUrl, "Provider service URL should match");
        assertEq(pending.peerId, validPeerId, "Peer ID should match");
        assertEq(pending.registeredAt, block.number, "Registration epoch should match");
    }

    function testCannotRegisterTwiceWhilePending() public {
        vm.startPrank(sp1);

        // First registration
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        // Try to register again
        vm.expectRevert("Registration already pending");
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        vm.stopPrank();
    }

    function testCannotRegisterIfAlreadyApproved() public {
        // Register and approve SP1
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Try to register again
        vm.prank(sp1);
        vm.expectRevert("Provider already approved");
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);
    }

    function testApproveServiceProvider() public {
        // SP registers
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        // Get the registration block from pending info
        PandoraService.PendingProviderInfo memory pendingInfo = pdpServiceWithPayments.getPendingProvider(sp1);
        uint256 registrationBlock = pendingInfo.registeredAt;

        vm.roll(block.number + 10); // Advance blocks
        uint256 approvalBlock = block.number;

        // Owner approves
        vm.expectEmit(true, true, false, false);
        emit ProviderApproved(sp1, 1);

        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Verify approval
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "SP should be approved");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 1, "SP should have ID 1");

        // Verify SP info
        PandoraService.ApprovedProviderInfo memory info = pdpServiceWithPayments.getApprovedProvider(1);
        assertEq(info.storageProvider, sp1, "Storage provider should match");
        assertEq(info.serviceURL, validServiceUrl, "Provider service URL should match");
        assertEq(info.peerId, validPeerId, "Peer ID should match");
        assertEq(info.registeredAt, registrationBlock, "Registration epoch should match");
        assertEq(info.approvedAt, approvalBlock, "Approval epoch should match");

        // Verify pending registration cleared
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertEq(pending.registeredAt, 0, "Pending registration should be cleared");
    }

    function testApproveMultipleProviders() public {
        // Multiple SPs register
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        // Approve both
        pdpServiceWithPayments.approveServiceProvider(sp1);
        pdpServiceWithPayments.approveServiceProvider(sp2);

        // Verify IDs assigned sequentially
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 1, "SP1 should have ID 1");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp2), 2, "SP2 should have ID 2");
        assertEq(pdpServiceWithPayments.nextServiceProviderId(), 3, "Next ID should be 3");
    }

    function testOnlyOwnerCanApprove() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        pdpServiceWithPayments.approveServiceProvider(sp1);
    }

    function testCannotApproveNonExistentRegistration() public {
        vm.expectRevert("No pending registration found");
        pdpServiceWithPayments.approveServiceProvider(sp1);
    }

    function testCannotApproveAlreadyApprovedProvider() public {
        // Register and approve
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Try to approve again (would need to re-register first, but we test the check)
        vm.expectRevert("Provider already approved");
        pdpServiceWithPayments.approveServiceProvider(sp1);
    }

    function testRejectServiceProvider() public {
        // SP registers
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        // Owner rejects
        vm.expectEmit(true, false, false, false);
        emit ProviderRejected(sp1);

        pdpServiceWithPayments.rejectServiceProvider(sp1);

        // Verify not approved
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp1), "SP should not be approved");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 0, "SP should have no ID");

        // Verify pending registration cleared
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertEq(pending.registeredAt, 0, "Pending registration should be cleared");
    }

    function testCanReregisterAfterRejection() public {
        // Register and reject
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.rejectServiceProvider(sp1);

        // Register again with different URLs
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        // Verify new registration
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertTrue(pending.registeredAt > 0, "New pending registration should exist");
        assertEq(pending.serviceURL, validServiceUrl2, "New provider service URL should match");
    }

    function testOnlyOwnerCanReject() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        pdpServiceWithPayments.rejectServiceProvider(sp1);
    }

    function testCannotRejectNonExistentRegistration() public {
        vm.expectRevert("No pending registration found");
        pdpServiceWithPayments.rejectServiceProvider(sp1);
    }

    // ===== Removal Tests =====

    function testRemoveServiceProvider() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Verify SP is approved
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "SP should be approved");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 1, "SP should have ID 1");

        // Owner removes the provider
        vm.expectEmit(true, true, false, false);
        emit ProviderRemoved(sp1, 1);

        pdpServiceWithPayments.removeServiceProvider(1);

        // Verify SP is no longer approved
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp1), "SP should not be approved");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 0, "SP should have no ID");
    }

    function testOnlyOwnerCanRemove() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Try to remove as non-owner
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        pdpServiceWithPayments.removeServiceProvider(1);
    }

    function testRemovedProviderCannotCreateDataSet() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Remove the provider
        pdpServiceWithPayments.removeServiceProvider(1);

        // Prepare extra data
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: false
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 10e6);
        payments.deposit(address(mockUSDFC), client, 10e6);
        vm.stopPrank();

        // Try to create data set as removed SP
        makeSignaturePass(client);
        vm.prank(sp1);
        vm.expectRevert();
        mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), encodedData);
    }

    function testCanReregisterAfterRemoval() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Remove the provider
        pdpServiceWithPayments.removeServiceProvider(1);

        // Should be able to register again
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        // Verify new registration
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertTrue(pending.registeredAt > 0, "New pending registration should exist");
        assertEq(pending.serviceURL, validServiceUrl2, "New provider service URL should match");
    }

    function testNonWhitelistedProviderCannotCreateDataSet() public {
        // Prepare extra data
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: false
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 10e6);
        payments.deposit(address(mockUSDFC), client, 10e6);
        vm.stopPrank();

        // Try to create data set as non-approved SP
        makeSignaturePass(client);
        vm.prank(sp1);
        vm.expectRevert();
        mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), encodedData);
    }

    function testWhitelistedProviderCanCreateDataSet() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Prepare extra data
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: false
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 10e6);
        payments.deposit(address(mockUSDFC), client, 10e6);
        vm.stopPrank();

        // Create data set as approved SP
        makeSignaturePass(client);
        vm.prank(sp1);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), encodedData);

        // Verify data set was created
        assertTrue(newDataSetId > 0, "Data set should be created");
    }

    function testGetApprovedProvider() public {
        // Register and approve
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Get provider info
        PandoraService.ApprovedProviderInfo memory info = pdpServiceWithPayments.getApprovedProvider(1);
        assertEq(info.storageProvider, sp1, "Storage provider should match");
        assertEq(info.serviceURL, validServiceUrl, "Provider service URL should match");
    }

    function testGetApprovedProviderInvalidId() public {
        vm.expectRevert("Invalid provider ID");
        pdpServiceWithPayments.getApprovedProvider(0);

        vm.expectRevert("Invalid provider ID");
        pdpServiceWithPayments.getApprovedProvider(1); // No providers approved yet

        // Approve one provider
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        vm.expectRevert("Invalid provider ID");
        pdpServiceWithPayments.getApprovedProvider(2); // Only ID 1 exists
    }

    function testIsProviderApproved() public {
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp1), "Should not be approved initially");

        // Register and approve
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "Should be approved after approval");
    }

    function testGetPendingProvider() public {
        // No pending registration
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertEq(pending.registeredAt, 0, "Should have no pending registration");

        // Register
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        // Check pending
        pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertTrue(pending.registeredAt > 0, "Should have pending registration");
        assertEq(pending.serviceURL, validServiceUrl, "Provider service URL should match");
    }

    function testGetProviderIdByAddress() public {
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 0, "Should have no ID initially");

        // Register and approve
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 1, "Should have ID 1 after approval");
    }

    // Additional comprehensive tests for removeServiceProvider

    function testRemoveServiceProviderAfterReregistration() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Remove the provider
        pdpServiceWithPayments.removeServiceProvider(1);

        // SP re-registers with different URLs
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        // Approve again
        pdpServiceWithPayments.approveServiceProvider(sp1);
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 2, "SP should have new ID 2");

        // Remove again
        pdpServiceWithPayments.removeServiceProvider(2);
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp1), "SP should not be approved");
    }

    function testRemoveMultipleProviders() public {
        // Register and approve multiple SPs
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);

        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        vm.prank(sp3);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp3.example.com", hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070811"
        );

        // Approve all
        pdpServiceWithPayments.approveServiceProvider(sp1);
        pdpServiceWithPayments.approveServiceProvider(sp2);
        pdpServiceWithPayments.approveServiceProvider(sp3);

        // Remove sp2
        pdpServiceWithPayments.removeServiceProvider(2);

        // Verify sp1 and sp3 are still approved
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "SP1 should still be approved");
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp3), "SP3 should still be approved");
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp2), "SP2 should not be approved");

        // Verify IDs
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), 1, "SP1 should still have ID 1");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp2), 0, "SP2 should have no ID");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp3), 3, "SP3 should still have ID 3");
    }

    function testRemoveProviderWithPendingRegistration() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Remove the provider
        pdpServiceWithPayments.removeServiceProvider(1);

        // SP tries to register again while removed
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);

        // Verify SP has pending registration but is not approved
        assertFalse(pdpServiceWithPayments.isProviderApproved(sp1), "SP should not be approved");
        PandoraService.PendingProviderInfo memory pending = pdpServiceWithPayments.getPendingProvider(sp1);
        assertTrue(pending.registeredAt > 0, "Should have pending registration");
        assertEq(pending.serviceURL, validServiceUrl2, "Pending URL should match new registration");
    }

    function testRemoveProviderInvalidId() public {
        // Try to remove with ID 0
        vm.expectRevert("Invalid provider ID");
        pdpServiceWithPayments.removeServiceProvider(0);

        // Try to remove with non-existent ID
        vm.expectRevert("Invalid provider ID");
        pdpServiceWithPayments.removeServiceProvider(999);
    }

    function testCannotRemoveAlreadyRemovedProvider() public {
        // Register and approve SP
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        // Remove the provider
        pdpServiceWithPayments.removeServiceProvider(1);

        // Try to remove again
        vm.expectRevert("Provider not found");
        pdpServiceWithPayments.removeServiceProvider(1);
    }

    function testGetAllApprovedProvidersAfterRemoval() public {
        // Register and approve three providers
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl2, validPeerId2);
        pdpServiceWithPayments.approveServiceProvider(sp2);

        vm.prank(sp3);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp3.example.com", hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070811"
        );
        pdpServiceWithPayments.approveServiceProvider(sp3);

        // Verify all three are approved
        PandoraService.ApprovedProviderInfo[] memory providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 3, "Should have three approved providers");
        assertEq(providers[0].storageProvider, sp1, "First provider should be sp1");
        assertEq(providers[1].storageProvider, sp2, "Second provider should be sp2");
        assertEq(providers[2].storageProvider, sp3, "Third provider should be sp3");

        // Remove the middle provider (sp2 with ID 2)
        pdpServiceWithPayments.removeServiceProvider(2);

        // Get all approved providers again - should only return active providers
        providers = pdpServiceWithPayments.getAllApprovedProviders();

        // Should only have 2 elements now (removed provider filtered out)
        assertEq(providers.length, 2, "Array should only contain active providers");
        assertEq(providers[0].storageProvider, sp1, "First provider should still be sp1");
        assertEq(providers[1].storageProvider, sp3, "Second provider should be sp3 (sp2 filtered out)");

        // Verify the URLs are correct for remaining providers
        assertEq(providers[0].serviceURL, validServiceUrl, "SP1 provider service URL should be correct");
        assertEq(providers[1].serviceURL, "https://sp3.example.com", "SP3 provider service URL should be correct");

        // Edge case 1: Remove all providers
        pdpServiceWithPayments.removeServiceProvider(1);
        pdpServiceWithPayments.removeServiceProvider(3);

        providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 0, "Should return empty array when all providers removed");
    }

    function testGetAllApprovedProvidersNoProviders() public {
        // Edge case: No providers have been registered/approved
        PandoraService.ApprovedProviderInfo[] memory providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 0, "Should return empty array when no providers registered");
    }

    function testGetAllApprovedProvidersSingleProvider() public {
        // Edge case: Only one approved provider
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(validServiceUrl, validPeerId);
        pdpServiceWithPayments.approveServiceProvider(sp1);

        PandoraService.ApprovedProviderInfo[] memory providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 1, "Should have one approved provider");
        assertEq(providers[0].storageProvider, sp1, "Provider should be sp1");
        assertEq(providers[0].serviceURL, validServiceUrl, "Provider service URL should match");

        // Remove the single provider
        pdpServiceWithPayments.removeServiceProvider(1);

        providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 0, "Should return empty array after removing single provider");
    }

    function testGetAllApprovedProvidersManyRemoved() public {
        // Edge case: Many providers removed, only few remain
        // Register and approve 5 providers
        address[5] memory sps = [sp1, sp2, sp3, address(0xf6), address(0xf7)];
        string[5] memory serviceUrls = [
            "https://sp1.example.com",
            "https://sp2.example.com",
            "https://sp3.example.com",
            "https://sp4.example.com",
            "https://sp5.example.com"
        ];

        bytes[5] memory peerIds;
        peerIds[0] = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070801";
        peerIds[1] = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070802";
        peerIds[2] = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070803";
        peerIds[3] = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070804";
        peerIds[4] = hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070805";

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(sps[i]);
            pdpServiceWithPayments.registerServiceProvider(serviceUrls[i], peerIds[i]);
            pdpServiceWithPayments.approveServiceProvider(sps[i]);
        }

        // Verify all 5 are approved
        PandoraService.ApprovedProviderInfo[] memory providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 5, "Should have five approved providers");

        // Remove providers 1, 3, and 4 (keeping 2 and 5)
        pdpServiceWithPayments.removeServiceProvider(1);
        pdpServiceWithPayments.removeServiceProvider(3);
        pdpServiceWithPayments.removeServiceProvider(4);

        // Should only return providers 2 and 5
        providers = pdpServiceWithPayments.getAllApprovedProviders();
        assertEq(providers.length, 2, "Should only have two active providers");
        assertEq(providers[0].storageProvider, sp2, "First active provider should be sp2");
        assertEq(providers[1].storageProvider, address(0xf7), "Second active provider should be sp5");
        assertEq(providers[0].serviceURL, serviceUrls[1], "SP2 URL should match");
        assertEq(providers[1].serviceURL, serviceUrls[4], "SP5 URL should match");
    }

    // ===== Client-Data Set Tracking Tests =====
    function createDataSetForClient(address provider, address clientAddress, string memory metadata)
        internal
        returns (uint256)
    {
        // Register and approve provider if not already approved
        if (!pdpServiceWithPayments.isProviderApproved(provider)) {
            vm.prank(provider);
            pdpServiceWithPayments.registerServiceProvider(
                "https://provider.example.com", hex"122019e5f1b0e1e7c1c1b1a1b1c1d1e1f1010203040506070850"
            );
            pdpServiceWithPayments.approveServiceProvider(provider);
        }

        // Prepare extra data
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: metadata,
            payer: clientAddress,
            withCDN: false,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(address(mockUSDFC), clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), encodedData);
    }

    function testGetClientDataSets_EmptyClient() public view {
        // Test with a client that has no data sets
        PandoraService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        assertEq(dataSets.length, 0, "Should return empty array for client with no data sets");
    }

    function testGetClientDataSets_SingleDataSet() public {
        // Create a single data set for the client
        string memory metadata = "Test metadata";

        createDataSetForClient(sp1, client, metadata);

        // Get data sets
        PandoraService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 1, "Should return one data set");
        assertEq(dataSets[0].payer, client, "Payer should match");
        assertEq(dataSets[0].payee, sp1, "Payee should match");
        assertEq(dataSets[0].metadata, metadata, "Metadata should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");
        assertGt(dataSets[0].railId, 0, "Rail ID should be set");
    }

    function testGetClientDataSets_MultipleDataSets() public {
        // Create multiple data sets for the client
        createDataSetForClient(sp1, client, "Metadata 1");
        createDataSetForClient(sp2, client, "Metadata 2");

        // Get data sets
        PandoraService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 2, "Should return two data sets");

        // Check first data set
        assertEq(dataSets[0].payer, client, "First data set payer should match");
        assertEq(dataSets[0].payee, sp1, "First data set payee should match");
        assertEq(dataSets[0].metadata, "Metadata 1", "First data set metadata should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");

        // Check second data set
        assertEq(dataSets[1].payer, client, "Second data set payer should match");
        assertEq(dataSets[1].payee, sp2, "Second data set payee should match");
        assertEq(dataSets[1].metadata, "Metadata 2", "Second data set metadata should match");
        assertEq(dataSets[1].clientDataSetId, 1, "Second data set ID should be 1");
    }

    // ===== Data Set Storage Provider Change Tests =====

    /**
     * @notice Helper function to create a data set and return its ID
     * @dev This function sets up the necessary state for storage provider change testing
     * @param provider The storage provider address
     * @param clientAddress The client address
     * @param metadata The data set metadata
     * @return The created data set ID
     */
    function createDataSetForStorageProviderTest(address provider, address clientAddress, string memory metadata)
        internal
        returns (uint256)
    {
        // Register and approve provider if not already approved
        if (!pdpServiceWithPayments.isProviderApproved(provider)) {
            vm.prank(provider);
            pdpServiceWithPayments.registerServiceProvider(
                "https://provider.example.com/pdp", "https://provider.example.com/retrieve"
            );
            pdpServiceWithPayments.approveServiceProvider(provider);
        }

        // Prepare extra data
        PandoraService.DataSetCreateData memory createData = PandoraService.DataSetCreateData({
            metadata: metadata,
            payer: clientAddress,
            withCDN: false,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(address(mockUSDFC), clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(address(pdpServiceWithPayments), encodedData);
    }

    /**
     * @notice Test successful storage provider change between two approved providers
     * @dev Verifies only the data set's payee is updated, event is emitted, and registry state is unchanged.
     */
    function testStorageProviderChangedSuccessDecoupled() public {
        // Register and approve two providers
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp2.example.com/pdp", "https://sp2.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp2);

        // Create a data set with sp1 as the storage provider
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");

        // Registry state before
        bool sp1ApprovedBefore = pdpServiceWithPayments.isProviderApproved(sp1);
        bool sp2ApprovedBefore = pdpServiceWithPayments.isProviderApproved(sp2);
        uint256 sp1IdBefore = pdpServiceWithPayments.getProviderIdByAddress(sp1);
        uint256 sp2IdBefore = pdpServiceWithPayments.getProviderIdByAddress(sp2);

        // Change storage provider from sp1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit DataSetStorageProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetStorageProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);

        // Only the data set's payee is updated
        (address payer, address payee) = pdpServiceWithPayments.getDataSetParties(testDataSetId);
        assertEq(payee, sp2, "Payee should be updated to new storage provider");

        // Registry state is unchanged
        assertEq(pdpServiceWithPayments.isProviderApproved(sp1), sp1ApprovedBefore, "sp1 registry state unchanged");
        assertEq(pdpServiceWithPayments.isProviderApproved(sp2), sp2ApprovedBefore, "sp2 registry state unchanged");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp1), sp1IdBefore, "sp1 provider ID unchanged");
        assertEq(pdpServiceWithPayments.getProviderIdByAddress(sp2), sp2IdBefore, "sp2 provider ID unchanged");
    }

    /**
     * @notice Test storage provider change reverts if new storage provider is not an approved provider
     */
    function testStorageProviderChangedRevertsIfNewStorageProviderNotApproved() public {
        // Register and approve sp1
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        // Create a data set with sp1 as the storage provider
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");
        // Use an unapproved address for the new storage provider
        address unapproved = address(0x9999);
        assertFalse(pdpServiceWithPayments.isProviderApproved(unapproved), "Unapproved should not be approved");
        // Attempt storage provider change
        bytes memory testExtraData = new bytes(0);
        vm.prank(unapproved);
        vm.expectRevert("New storage provider must be an approved provider");
        mockPDPVerifier.changeDataSetStorageProvider(
            testDataSetId, unapproved, address(pdpServiceWithPayments), testExtraData
        );
        // Registry state is unchanged
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "sp1 should remain approved");
    }

    /**
     * @notice Test storage provider change reverts if new storage provider is zero address
     */
    function testStorageProviderChangedRevertsIfNewStorageProviderZeroAddress() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        vm.prank(sp1);
        vm.expectRevert("New storage provider cannot be zero address");
        mockPDPVerifier.changeDataSetStorageProvider(
            testDataSetId, address(0), address(pdpServiceWithPayments), testExtraData
        );
    }

    /**
     * @notice Test storage provider change reverts if old storage provider mismatch
     */
    function testStorageProviderChangedRevertsIfOldStorageProviderMismatch() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp2.example.com/pdp", "https://sp2.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp2);
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as PDPVerifier with wrong old storage provider
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert("Old storage provider mismatch");
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp2, sp2, testExtraData);
    }

    /**
     * @notice Test storage provider change reverts if called by unauthorized address
     */
    function testStorageProviderChangedRevertsIfUnauthorizedCaller() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp2.example.com/pdp", "https://sp2.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp2);
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as sp2 (not PDPVerifier)
        vm.prank(sp2);
        vm.expectRevert("Caller is not the PDP verifier");
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp1, sp2, testExtraData);
    }

    /**
     * @notice Test multiple data sets per provider: only the targeted data set's payee is updated
     */
    function testMultipleDataSetsPerProviderStorageProviderChange() public {
        // Register and approve two providers
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp2.example.com/pdp", "https://sp2.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp2);
        // Create two data sets for sp1
        uint256 ps1 = createDataSetForStorageProviderTest(sp1, client, "Data Set 1");
        uint256 ps2 = createDataSetForStorageProviderTest(sp1, client, "Data Set 2");
        // Change storage provider of ps1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit DataSetStorageProviderChanged(ps1, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetStorageProvider(ps1, sp2, address(pdpServiceWithPayments), testExtraData);
        // ps1 payee updated, ps2 payee unchanged
        (, address payee1) = pdpServiceWithPayments.getDataSetParties(ps1);
        (, address payee2) = pdpServiceWithPayments.getDataSetParties(ps2);
        assertEq(payee1, sp2, "ps1 payee should be sp2");
        assertEq(payee2, sp1, "ps2 payee should remain sp1");
        // Registry state unchanged
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp1), "sp1 remains approved");
        assertTrue(pdpServiceWithPayments.isProviderApproved(sp2), "sp2 remains approved");
    }

    /**
     * @notice Test storage provider change works with arbitrary extra data
     */
    function testStorageProviderChangedWithArbitraryExtraData() public {
        vm.prank(sp1);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp1.example.com/pdp", "https://sp1.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp1);
        vm.prank(sp2);
        pdpServiceWithPayments.registerServiceProvider(
            "https://sp2.example.com/pdp", "https://sp2.example.com/retrieve"
        );
        pdpServiceWithPayments.approveServiceProvider(sp2);
        uint256 testDataSetId = createDataSetForStorageProviderTest(sp1, client, "Test Data Set");
        // Use arbitrary extra data
        bytes memory testExtraData = abi.encode("arbitrary", 123, address(this));
        vm.expectEmit(true, true, true, true);
        emit DataSetStorageProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetStorageProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);
        (, address payee) = pdpServiceWithPayments.getDataSetParties(testDataSetId);
        assertEq(payee, sp2, "Payee should be updated to new storage provider");
    }
}

contract SignatureCheckingService is PandoraService {
    constructor() {}

    function doRecoverSigner(bytes32 messageHash, bytes memory signature) public pure returns (address) {
        return recoverSigner(messageHash, signature);
    }
}

contract PandoraServiceSignatureTest is Test {
    // Contracts
    SignatureCheckingService public pdpService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;

    // Test accounts with known private keys
    address public payer;
    uint256 public payerPrivateKey;
    address public creator;
    address public wrongSigner;
    uint256 public wrongSignerPrivateKey;

    function setUp() public {
        // Set up test accounts with known private keys
        payerPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        payer = vm.addr(payerPrivateKey);

        wrongSignerPrivateKey = 0x9876543210987654321098765432109876543210987654321098765432109876;
        wrongSigner = vm.addr(wrongSignerPrivateKey);

        creator = address(0xf2);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Deploy and initialize the service
        SignatureCheckingService serviceImpl = new SignatureCheckingService();
        bytes memory initData = abi.encodeWithSelector(
            PandoraService.initialize.selector,
            address(mockPDPVerifier),
            address(payments),
            address(mockUSDFC),
            0, // 0% commission
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), initData);
        pdpService = SignatureCheckingService(address(serviceProxy));

        // Fund the payer
        mockUSDFC.transfer(payer, 1000 * 10 ** 6); // 1000 USDFC
    }

    // Test the recoverSigner function indirectly through signature verification
    function testRecoverSignerWithValidSignature() public view {
        // Create the message hash that should be signed
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign the message hash with the payer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPrivateKey, messageHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Test that the signature verifies correctly
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, validSignature);
        assertEq(recoveredSigner, payer, "Should recover the correct signer address");
    }

    function testRecoverSignerWithWrongSigner() public view {
        // Create the message hash
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign with wrong signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongSignerPrivateKey, messageHash);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);

        // Test that the signature recovers the wrong signer (not the expected payer)
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, wrongSignature);
        assertEq(recoveredSigner, wrongSigner, "Should recover the wrong signer address");
        assertTrue(recoveredSigner != payer, "Should not recover the expected payer address");
    }

    function testRecoverSignerInvalidLength() public {
        bytes32 messageHash = keccak256(abi.encode(42));
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes16(0)); // Wrong length (48 bytes instead of 65)

        vm.expectRevert("Invalid signature length");
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }

    function testRecoverSignerInvalidVValue() public {
        bytes32 messageHash = keccak256(abi.encode(42));

        // Create signature with invalid v value
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        uint8 v = 25; // Invalid v value (should be 27 or 28)
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert("Unsupported signature 'v' value, we don't handle rare wrapped case");
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }
}

// Test contract for upgrade scenarios
contract PandoraServiceUpgradeTest is Test {
    PandoraService public pandoraService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;

    address public deployer;

    function setUp() public {
        deployer = address(this);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Deploy PandoraService with original initialize (without proving period params)
        // This simulates an existing deployed contract before the upgrade
        PandoraService pandoraImpl = new PandoraService();
        bytes memory initData = abi.encodeWithSelector(
            PandoraService.initialize.selector,
            address(mockPDPVerifier),
            address(payments),
            address(mockUSDFC),
            0, // 0% commission
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy pandoraProxy = new MyERC1967Proxy(address(pandoraImpl), initData);
        pandoraService = PandoraService(address(pandoraProxy));
    }

    function testInitializeV2() public {
        // Test that we can call initializeV2 to set new proving period parameters
        uint64 newMaxProvingPeriod = 120; // 2 hours
        uint256 newChallengeWindowSize = 30;

        // This should work since we're using reinitializer(2)
        pandoraService.initializeV2(newMaxProvingPeriod, newChallengeWindowSize);

        // Verify the values were set correctly
        assertEq(pandoraService.maxProvingPeriod(), newMaxProvingPeriod, "Max proving period should be updated");
        assertEq(
            pandoraService.challengeWindowSize(), newChallengeWindowSize, "Challenge window size should be updated"
        );
        assertEq(
            pandoraService.getMaxProvingPeriod(), newMaxProvingPeriod, "getMaxProvingPeriod should return updated value"
        );
        assertEq(
            pandoraService.challengeWindow(), newChallengeWindowSize, "challengeWindow should return updated value"
        );
    }

    function testInitializeV2WithInvalidParameters() public {
        // Test that initializeV2 validates parameters correctly

        // Test zero max proving period
        vm.expectRevert("Max proving period must be greater than zero");
        pandoraService.initializeV2(0, 30);

        // Test zero challenge window size
        vm.expectRevert("Invalid challenge window size");
        pandoraService.initializeV2(120, 0);

        // Test challenge window size >= max proving period
        vm.expectRevert("Invalid challenge window size");
        pandoraService.initializeV2(120, 120);

        vm.expectRevert("Invalid challenge window size");
        pandoraService.initializeV2(120, 150);
    }

    function testInitializeV2OnlyOnce() public {
        // Test that initializeV2 can only be called once
        pandoraService.initializeV2(120, 30);

        // Second call should fail - expecting the InvalidInitialization() custom error
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        pandoraService.initializeV2(240, 60);
    }

    function testVersioning() public {
        // Test that VERSION constant is accessible and has expected value
        string memory version = pandoraService.VERSION();
        assertEq(version, "0.1.0", "VERSION should be 0.1.0");
    }

    function testMigrate() public {
        // Test migrate function for versioning
        // Note: This would typically be called during a proxy upgrade via upgradeToAndCall
        // We're testing the function directly here for simplicity

        // Start recording logs
        vm.recordLogs();

        // Simulate calling migrate during upgrade (called by proxy)
        vm.prank(address(pandoraService));
        pandoraService.migrate();

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the ContractUpgraded event (reinitializer also emits Initialized event)
        bytes32 expectedTopic = keccak256("ContractUpgraded(string,address)");
        bool foundEvent = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) {
                // Decode and verify the event data
                (string memory version, address implementation) = abi.decode(logs[i].data, (string, address));
                assertEq(version, "0.1.0", "Version should be 0.1.0");
                assertTrue(implementation != address(0), "Implementation address should not be zero");
                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "Should emit ContractUpgraded event");
    }

    function testMigrateOnlyCallableDuringUpgrade() public {
        // Test that migrate can only be called by the contract itself
        vm.expectRevert("Only callable by self during upgrade");
        pandoraService.migrate();
    }

    function testMigrateOnlyOnce() public {
        // Test that migrate can only be called once per reinitializer version
        vm.prank(address(pandoraService));
        pandoraService.migrate();

        // Second call should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vm.prank(address(pandoraService));
        pandoraService.migrate();
    }

    // Event declaration for testing (must match the contract's event)
    event ContractUpgraded(string version, address implementation);
}
