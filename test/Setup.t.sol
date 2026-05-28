// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";

/// @notice Smoke tests — prove the full system wires up correctly and
///         a tanda reaches ACTIVE with payout order assigned via the
///         standard `_fillAndStart` helper.
contract SetupTest is MitandaTestBase {
    function test_systemDeploys() public {
        assertTrue(address(manager) != address(0));
        assertTrue(manager.isAllowedToken(address(usdc)));
        (uint256 activeId,) = manager.getActiveCollection();
        assertEq(activeId, 1);
    }

    function test_fillAndStartFlow() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed1")));

        Tanda t = Tanda(tandaAddr);
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE));
        assertTrue(t.payoutOrderAssigned());
        assertEq(t.getPayoutOrder().length, 3);
    }
}
