// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EarnStableCoin} from "./../../src/EarnStableCoin.sol";
import {DeployEarnStableCoin} from "./../../script/DeployEarnStableCoin.s.sol";
import {HelperConfig} from "./../../script/HelperConfig.s.sol";

contract EarnStableCoin__UnitTest is Test {
    // configuration
    DeployEarnStableCoin deployment;
    HelperConfig helperConfig;

    // contracts
    EarnStableCoin token;

    // helpers
    address USER = makeAddr("user");

    // modifiers
    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
            _;
        }
    }

    modifier funded(address account) {
        // fund user with eth
        deal(account, 1000 ether);
        _;
    }

    modifier minted(address account) {
        uint256 amount = 1000 ether;
        address owner = token.owner();

        vm.prank(owner);
        token.mint(USER, amount);
        _;
    }

    function setUp() external virtual {
        deployment = new DeployEarnStableCoin();
        token = deployment.run();
    }

    /**
     * INITIALIZATION
     */
    function test__unit__EarnStableCoin__Initialization() public view {
        assertEq(token.name(), "EarnStableCoin");
        assertEq(token.symbol(), "ESC");
        assertEq(token.decimals(), 18);
    }

    /**
     * CONSTRUCTOR
     */
    function test__unit__EarnStableCoin__Constructor() public {
        EarnStableCoin esc = new EarnStableCoin();
        assertEq(esc.owner(), address(this));
    }

    /**
     * MINT TOKENS
     */
    function test__unit__EarnStableCoin__Mint() public {
        uint256 amount = 1000 ether;
        address owner = token.owner();

        vm.prank(owner);
        token.mint(USER, amount);

        assertEq(token.balanceOf(USER), amount);
    }

    function test__unit__EarnStableCoin__RevertsWehn__MintZeroAmount() public {
        address owner = token.owner();

        vm.expectRevert(EarnStableCoin.EarnStableCoin__MustBeMoreThanZero.selector);

        vm.prank(owner);
        token.mint(USER, 0);
    }

    function test__unit__EarnStableCoin__RevertsWehn__MintToZeroAddress() public {
        address owner = token.owner();

        vm.expectRevert(EarnStableCoin.EarnStableCoin__NotZeroAddress.selector);

        vm.prank(owner);
        token.mint(address(0), 1000 ether);
    }

    /**
     * BURN TOKENS
     */
    function test__unit__EarnStableCoin__Burn() public {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 30 ether;
        address owner = token.owner();

        // fund contract
        vm.prank(owner);
        token.mint(owner, mintAmount);
        assertEq(token.balanceOf(owner), mintAmount);

        // burn tokens
        vm.prank(owner);
        token.burn(burnAmount);

        assertEq(token.balanceOf(owner), mintAmount - burnAmount);
    }

    function test__unit__EarnStableCoin__RevertsWehn__BurnZeroAmount() public {
        uint256 mintAmount = 100 ether;
        address owner = token.owner();

        // fund contract
        vm.prank(owner);
        token.mint(owner, mintAmount);
        assertEq(token.balanceOf(owner), mintAmount);

        // test revert
        vm.expectRevert(EarnStableCoin.EarnStableCoin__MustBeMoreThanZero.selector);

        // burn tokens
        vm.prank(owner);
        token.burn(0);
    }

    function test__unit__EarnStableCoin__RevertsWehn__BurnTooManyTokens() public {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 110 ether;
        address owner = token.owner();

        // fund contract
        vm.prank(owner);
        token.mint(owner, mintAmount);
        assertEq(token.balanceOf(owner), mintAmount);

        // test revert
        vm.expectRevert(EarnStableCoin.EarnStableCoin__BurnAmountExceedsBalance.selector);

        // burn tokens
        vm.prank(owner);
        token.burn(burnAmount);
    }
}
