// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.t.sol";
import {PincerDeployer} from "../src/platform/PincerDeployer.sol";
import {PincerEquityToken} from "../src/platform/PincerEquityToken.sol";
import {TransferPolicy} from "../src/policy/TransferPolicy.sol";
import {LockupRule} from "../src/policy/rules/LockupRule.sol";
import {HolderLimitRule} from "../src/policy/rules/HolderLimitRule.sol";
import {TradingWindowRule} from "../src/policy/rules/TradingWindowRule.sol";
import {FirstRefusalRule} from "../src/policy/rules/FirstRefusalRule.sol";
import {VestingScheduleRule} from "../src/policy/rules/VestingScheduleRule.sol";
import {CheckCodes} from "../src/common/CheckCodes.sol";
import {ClaimTopics} from "../src/common/ClaimTopics.sol";

contract PolicyRulesTest is TestBase {
    function setUp() public override {
        super.setUp();
        _verify(alice, US, 2);
        _verify(bob, GB, 1);
        _verify(carol, KP, 3);
        _verify(dave, SG, 0);
    }

    function _module(PincerEquityToken token, uint256 i) internal view returns (address) {
        return TransferPolicy(address(token.ruleEngine())).modules()[i];
    }

    function _code(PincerEquityToken token, address from, address to, uint256 amount)
        internal
        view
        returns (bytes32 code)
    {
        (, code) = token.canTransfer(from, to, amount);
    }

    function test_RegionAllowList() public {
        bytes2[] memory regions = new bytes2[](2);
        regions[0] = US;
        regions[1] = GB;
        PincerEquityToken token = _deployClass("C", _modules1("REGION", abi.encode(uint8(0), regions)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, bob, 1), CheckCodes.OK);
        assertEq(_code(token, alice, dave, 1), CheckCodes.REGION_BLOCKED);
    }

    function test_RegionBlockList() public {
        bytes2[] memory regions = new bytes2[](1);
        regions[0] = KP;
        PincerEquityToken token = _deployClass("C", _modules1("REGION", abi.encode(uint8(1), regions)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, dave, 1), CheckCodes.OK);
        assertEq(_code(token, alice, carol, 1), CheckCodes.REGION_BLOCKED);
    }

    function test_EligibilityTierAndEmployeeExemption() public {
        PincerEquityToken token = _deployClass("C", _modules1("ELIGIBILITY", abi.encode(uint8(1), true)));
        _mint(token, alice, 100);
        assertEq(_code(token, alice, bob, 1), CheckCodes.OK);
        assertEq(_code(token, alice, dave, 1), CheckCodes.NOT_ELIGIBLE);
        _addClaim(dave, ClaimTopics.EMPLOYEE_OF, abi.encode(COMPANY));
        assertEq(_code(token, alice, dave, 1), CheckCodes.OK);
    }

    function test_HoldingPeriodFifoLots() public {
        bytes memory config =
            abi.encode(uint32(30 days), new bytes32[](0), new uint32[](0), new address[](0), new bytes32[](0));
        PincerEquityToken token = _deployClass("C", _modules1("HOLDING_PERIOD", config));
        LockupRule hp = LockupRule(_module(token, 0));

        _mint(token, alice, 1_000);
        vm.warp(T0 + 10 days);
        _mint(token, alice, 2_000);

        assertEq(_code(token, alice, bob, 1), CheckCodes.HOLDING_PERIOD_ACTIVE);
        vm.warp(T0 + 30 days); // only the earliest lot has now aged past 30 days
        assertEq(token.unlockedBalanceOf(alice), 1_000);
        assertEq(_code(token, alice, bob, 1_001), CheckCodes.HOLDING_PERIOD_ACTIVE);

        vm.prank(alice);
        token.transfer(bob, 1_000);
        assertEq(hp.lotsOf(alice).length, 1);
        assertEq(hp.lotsOf(alice)[0].amount, 2_000);
        // Bob gets a fresh lot when shares arrive, with its own lockup clock starting from zero.
        assertEq(_code(token, bob, alice, 1), CheckCodes.HOLDING_PERIOD_ACTIVE);
    }

    function test_HoldingPeriodSourceOverride() public {
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = "OFFERING";
        uint32[] memory periods = new uint32[](1);
        periods[0] = 90 days;
        address[] memory ops = new address[](1);
        ops[0] = address(offerings);
        bytes memory config = abi.encode(uint32(0), sources, periods, ops, sources);
        PincerEquityToken token = _deployClass("C", _modules1("HOLDING_PERIOD", config));
        _mint(token, alice, 500); // unlabelled mints default to ISSUANCE, which carries no lockup in this setup
        assertEq(_code(token, alice, bob, 500), CheckCodes.OK);
        LockupRule hp = LockupRule(_module(token, 0));
        assertEq(hp.periodFor("OFFERING"), 90 days);
        assertEq(hp.operatorSource(address(offerings)), bytes32("OFFERING"));
    }

    function test_HolderCap() public {
        PincerEquityToken token = _deployClass("C", _modules1("HOLDER_CAP", abi.encode(uint32(2))));
        _mint(token, alice, 100);
        _mint(token, bob, 100);
        assertEq(HolderLimitRule(_module(token, 0)).holderCount(), 2);
        assertEq(_code(token, alice, dave, 10), CheckCodes.HOLDER_CAP_REACHED);
        assertEq(_code(token, alice, bob, 10), CheckCodes.OK);
        // Dave joins while Alice leaves, so the holder count never goes past the cap and the move is allowed.
        assertEq(_code(token, alice, dave, 100), CheckCodes.OK);
        vm.prank(alice);
        token.transfer(dave, 100);
        assertEq(HolderLimitRule(_module(token, 0)).holderCount(), 2);
    }

    function test_TransferWindow() public {
        TradingWindowRule.Window[] memory w = new TradingWindowRule.Window[](1);
        w[0] = TradingWindowRule.Window({opensAt: uint40(T0 + 1 days), closesAt: uint40(T0 + 2 days)});
        PincerEquityToken token = _deployClass("C", _modules1("TRANSFER_WINDOW", abi.encode(w, true, address(windows))));
        _mint(token, alice, 100); // mints are never blocked by this rule
        assertEq(_code(token, alice, bob, 1), CheckCodes.WINDOW_CLOSED);
        assertEq(_code(token, alice, address(windows), 1), CheckCodes.OK);
        vm.warp(T0 + 1 days);
        assertEq(_code(token, alice, bob, 1), CheckCodes.OK);
        vm.warp(T0 + 2 days);
        assertEq(_code(token, alice, bob, 1), CheckCodes.WINDOW_CLOSED);
    }

    function test_ROFRNoticeWaiveAndExercise() public {
        address[] memory venues = new address[](1);
        venues[0] = address(windows);
        PincerEquityToken token = _deployClass("C", _modules1("ROFR", abi.encode(treasury, uint32(14 days), venues)));
        FirstRefusalRule rofr = FirstRefusalRule(_module(token, 0));
        _mint(token, alice, 100);

        assertEq(_code(token, alice, bob, 10), CheckCodes.ROFR_PENDING);
        vm.prank(alice);
        rofr.propose(bob, 10);
        assertEq(_code(token, alice, bob, 10), CheckCodes.ROFR_PENDING);
        vm.warp(T0 + 14 days);
        assertEq(_code(token, alice, bob, 11), CheckCodes.ROFR_PENDING);
        vm.prank(alice);
        token.transfer(bob, 10);
        assertEq(_code(token, alice, bob, 1), CheckCodes.ROFR_PENDING); // the proposal was consumed by that transfer

        vm.prank(alice);
        rofr.propose(dave, 5);
        vm.prank(treasury);
        rofr.waive(alice, dave);
        assertEq(_code(token, alice, dave, 5), CheckCodes.OK);

        vm.prank(alice);
        rofr.propose(bob, 20);
        vm.prank(treasury);
        rofr.exercise(alice, bob);
        vm.warp(T0 + 44 days);
        assertEq(_code(token, alice, bob, 20), CheckCodes.ROFR_PENDING);
        assertEq(_code(token, alice, address(windows), 20), CheckCodes.OK);
    }

    function test_MaxOwnership() public {
        address[] memory exempt = new address[](1);
        exempt[0] = alice;
        PincerEquityToken token =
            _deployClass("C", _modules1("MAX_OWNERSHIP", abi.encode(uint16(1_000), false, exempt)));
        _mint(token, alice, 1_000); // applyToMints is false: mints skip the ceiling, as in a cap table import
        assertEq(_code(token, alice, bob, 100), CheckCodes.OK);
        assertEq(_code(token, alice, bob, 101), CheckCodes.MAX_OWNERSHIP_EXCEEDED);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(_code(token, alice, bob, 1), CheckCodes.MAX_OWNERSHIP_EXCEEDED);
    }

    function test_EmployeeVesting() public {
        PincerEquityToken token =
            _deployClass("C", _modules1("EMPLOYEE_VESTING", abi.encode(uint8(0), abi.encode(true))));
        VestingScheduleRule vest = VestingScheduleRule(_module(token, 0));
        _mint(token, alice, 4_000);

        VestingScheduleRule.Grant[] memory grants = new VestingScheduleRule.Grant[](1);
        grants[0] = VestingScheduleRule.Grant({
            start: uint64(block.timestamp), cliff: 365 days, duration: 4 * 365 days, total: 4_000, accelerated: false
        });
        vm.prank(alice);
        vm.expectRevert(VestingScheduleRule.NotRegistrar.selector);
        vest.addGrants(alice, grants);
        vm.prank(registrar);
        vest.addGrants(alice, grants);

        assertEq(_code(token, alice, bob, 1), CheckCodes.UNVESTED);
        assertEq(token.unlockedBalanceOf(alice), 0);
        vm.warp(T0 + 365 days);
        assertEq(token.unlockedBalanceOf(alice), 1_000);
        assertEq(_code(token, alice, bob, 1_000), CheckCodes.OK);
        assertEq(_code(token, alice, bob, 1_001), CheckCodes.UNVESTED);

        _timelocked(
            address(token.ruleEngine()),
            abi.encodeCall(
                TransferPolicy.configureModule, (address(vest), abi.encode(uint8(1), abi.encode(alice, uint256(0))))
            )
        );
        assertEq(_code(token, alice, bob, 4_000), CheckCodes.OK);
    }

    function test_ModuleChangesNeedTimelock() public {
        PincerEquityToken token = _plainClass("C");
        TransferPolicy engine = TransferPolicy(address(token.ruleEngine()));
        vm.prank(issuerAdmin);
        vm.expectRevert();
        engine.removeModule(address(1));

        _mint(token, alice, 100);
        assertEq(_code(token, alice, dave, 1), CheckCodes.OK);
        // addModule only accepts a rule bound to this policy; this one is unbound, so the execute call below reverts.
        HolderLimitRule rogue = new HolderLimitRule();
        bytes memory data = abi.encodeCall(TransferPolicy.addModule, (address(rogue), abi.encode(uint32(1))));
        vm.prank(signer1);
        bytes32 id = timelock.propose(address(engine), 0, data, "rogue");
        vm.prank(signer2);
        timelock.approve(id);
        assertEq(timelock.action(id).eta, T0 + 24 hours);
        vm.warp(T0 + 24 hours);
        vm.expectRevert();
        timelock.execute(id);
    }

    function test_FirstFailingModuleWins() public {
        bytes2[] memory regions = new bytes2[](1);
        regions[0] = US;
        PincerDeployer.ModuleInit[] memory m = new PincerDeployer.ModuleInit[](2);
        m[0] = PincerDeployer.ModuleInit("REGION", abi.encode(uint8(0), regions));
        m[1] = PincerDeployer.ModuleInit("ELIGIBILITY", abi.encode(uint8(5), false));
        PincerEquityToken token = _deployClass("C", m);
        assertEq(_code(token, address(0), dave, 1), CheckCodes.REGION_BLOCKED);
        assertEq(_code(token, address(0), alice, 1), CheckCodes.NOT_ELIGIBLE);
    }
}
