// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluid, FlowOperatorDefinitions } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperfluidFrameworkDeployer, SuperfluidTester, Superfluid, ConstantFlowAgreementV1, CFAv1Library, SuperTokenFactory } from "../test/SuperfluidTester.sol";
import { ERC1820RegistryCompiled } from "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import { IFlowScheduler } from "./../contracts/interface/IFlowScheduler.sol";
import { FlowScheduler } from "./../contracts/FlowScheduler.sol";
import { FlowSchedulerResolver } from "./../contracts/FlowSchedulerResolver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1820Registry } from "@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol";


/// @title Example Super Token Test
/// @author ctle-vn, SuperfluidTester taken from jtriley.eth
/// @notice For demonstration only. You can delete this file.
contract FlowSchedulerResolverTest is SuperfluidTester {

    SuperfluidFrameworkDeployer internal immutable sfDeployer;
    SuperfluidFrameworkDeployer.Framework internal sf;
    ISuperfluid host;
    ConstantFlowAgreementV1 cfa;
    FlowScheduler internal flowScheduler;
    FlowSchedulerResolver internal flowSchedulerResolver;
    uint256 private _expectedTotalSupply = 0;

    bytes4 constant INVALID_CFA_PERMISSIONS_ERROR_SIG = 0xa3eab6ac;

    // setting expected payloads from Gelato 
    bytes createPayload;
    bytes deletePayload;

    /// @dev This is required by solidity for using the CFAv1Library in the tester
    using CFAv1Library for CFAv1Library.InitData;

    constructor() SuperfluidTester(3) {
        vm.startPrank(admin);
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        sfDeployer = new SuperfluidFrameworkDeployer();
        sf = sfDeployer.getFramework();
        host = sf.host;
        cfa = sf.cfa;
        vm.stopPrank();

        /// @dev Example Flow Scheduler to test
        flowScheduler = new FlowScheduler(host, "");

        /// @dev Example SchedulerflowSchedulerResolver to test
        flowSchedulerResolver = new FlowSchedulerResolver(address(flowScheduler));
    }

    function setUp() public virtual {
        (token, superToken) = sfDeployer.deployWrapperSuperToken("FTT", "FTT", 18, type(uint256).max);

        for (uint32 i = 0; i < N_TESTERS; ++i) {
            token.mint(TEST_ACCOUNTS[i], INIT_TOKEN_BALANCE);

            vm.startPrank(TEST_ACCOUNTS[i]);
            token.approve(address(superToken), INIT_SUPER_TOKEN_BALANCE);
            superToken.upgrade(INIT_SUPER_TOKEN_BALANCE);
            _expectedTotalSupply += INIT_SUPER_TOKEN_BALANCE;
            vm.stopPrank();
        }

        createPayload = abi.encodeCall( FlowScheduler.executeCreateFlow,
            (
                ISuperToken(superToken),
                alice,
                bob,
                "" // not supporting user data until encoding challenges are solved
            )
        );

        deletePayload = abi.encodeCall( FlowScheduler.executeDeleteFlow,
            (
                ISuperToken(superToken),
                alice,
                bob,
                "" // not supporting user data until encoding challenges are solved
            )
        );
    }

    /// @dev expect payload to be empty and non-executable
    function expectUnexecutable() public {
        // Expect canExec to be false
        (bool canExec, bytes memory execPayload) = flowSchedulerResolver.checker(address(superToken), alice, bob);
        assertTrue(!canExec, "canExec - executable when it shouldn't have been");

        // And expect payload to not be executable
        (bool status, ) = address(flowScheduler).call(execPayload);
        assertTrue(!status, "status - unexpected success");
    }

    /// @dev expect payload to the expected and successfully executable
    function expectExecutable(bytes memory expectedPayload) public {
        // Expect canExec to be true
        (bool canExec, bytes memory execPayload) = flowSchedulerResolver.checker(address(superToken), alice, bob);
        assertTrue(canExec, "canExec - not executable when it should have been");
        assertEq(execPayload, expectedPayload, "wrong payload");

        // And expect payload to be executable
        (bool status, ) = address(flowScheduler).call(execPayload);
        assertTrue(status, "status - unexpected failure");
    }

    /// @dev Constants for Testing
    uint32 internal defaultStartDate = uint32(block.timestamp + 1);
    int96 defaultFlowRate = int96(1000);
    uint32 defaultStartMaxDelay = uint32(60);
    uint256 defaultStartAmount = 500;

    function testCreateSchedule() public {
        vm.prank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // shouldn't be given executable payload before defaultStartDate is reached
        (bool canExec, bytes memory execPayload) = flowSchedulerResolver.checker(address(superToken), alice, bob);
        assertTrue(!canExec);
        assertEq("0x", execPayload);
    }

    function testStartStreamWithIncorrectPermissions() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        vm.stopPrank();
        vm.startPrank(admin);

        // -- Shouldn't be executable with no permissions

        // Advance time past defaultStartDate and before defaultStartDate + defaultStartMaxDelay
        vm.warp(defaultStartDate + defaultStartMaxDelay - defaultStartMaxDelay/2 );

        expectUnexecutable();

        vm.stopPrank();
        vm.startPrank(alice);

        // -- Shouldn't be executable with incorrect permissions

        // Give only create permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FLOW_OPERATOR_CREATE, // not 5 or 7
                    type(int96).max, 
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);
        // Advance time past defaultStartDate and before defaultStartDate + defaultStartMaxDelay
        vm.warp(defaultStartDate +
         defaultStartMaxDelay - defaultStartMaxDelay/2 );

        expectUnexecutable();
    }

    function testStartStreamWithTooLittleRateAllowance() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give to little permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    defaultFlowRate - 1, // rate allowed is below what's needed
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // Advance time past defaultStartDate and before defaultStartDate + defaultStartMaxDelay
        vm.warp(defaultStartDate + defaultStartMaxDelay - defaultStartMaxDelay/2 );

        expectUnexecutable();
    }

    function testStartStreamPastMaxDelay() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give full flow permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    type(int96).max,
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // -- Shouldn't be given executable payload if defaultStartDate + defaultStartMaxDelay has been passed

        // Advance time past defaultStartDate + defaultStartMaxDelay
        vm.warp(defaultStartDate + defaultStartMaxDelay + defaultStartMaxDelay/2 );

        expectUnexecutable();
    }

    function testStartStreamBeforeMaxDelay() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give full flow permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    type(int96).max,
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // -- Should be given executable payload if defaultStartDate has been passed but 
        // defaultStartDate + defaultStartMaxDelay has not
        
        // Rewind time to before defaultStartDate + defaultStartMaxDelay
        vm.warp(defaultStartDate + defaultStartMaxDelay - defaultStartMaxDelay/2 );

        expectExecutable(createPayload);
    }

    function testDeleteStreamBeforeEndDate() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give full flow permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    type(int96).max,
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // create the stream
        vm.warp(defaultStartDate + defaultStartMaxDelay/2);
        expectExecutable(createPayload);

        // -- Should not give delete flow payload if defaultEndDate has not been passed

        // Move time to before defaultEndDate
        vm.warp(defaultEndDate - 1);

        expectUnexecutable();
    }

    function testDeleteNonExistantStreamAfterEndDate() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give full flow permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    type(int96).max,
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // -- Should not give delete flow payload if stream to delete does not exist in the first place 

        // Move time to defaultEndDate
        vm.warp(defaultEndDate);

        expectUnexecutable();
    }

    function testDeleteStreamAfterEndDate() public {
        vm.startPrank(alice);
        
        uint32 defaultEndDate = defaultStartDate + uint32(3600);

        flowScheduler.createFlowSchedule(
            superToken,
            bob,
            defaultStartDate,
            defaultStartMaxDelay,
            defaultFlowRate,
            defaultStartAmount,
            defaultEndDate,
            "",
            ""
        );

        // Give ERC20 approval to scheduler
        superToken.approve(address(flowScheduler), type(uint256).max);

        // Give full flow permissions to scheduler
        host.callAgreement(
            cfa,
            abi.encodeCall(
                cfa.updateFlowOperatorPermissions,
                (
                    superToken,
                    address(flowScheduler),
                    FlowOperatorDefinitions.AUTHORIZE_FULL_CONTROL,
                    type(int96).max,
                    new bytes(0)
                )
            ),
            new bytes(0)
        );

        vm.stopPrank();
        vm.startPrank(admin);

        // create the stream
        vm.warp(defaultStartDate + defaultStartMaxDelay/2);
        expectExecutable(createPayload);

        // -- Should give delete flow payload as we've passed defaultEndDate 

        // Move time to defaultEndDate
        vm.warp(defaultEndDate);

        expectExecutable(deletePayload);
    }

}