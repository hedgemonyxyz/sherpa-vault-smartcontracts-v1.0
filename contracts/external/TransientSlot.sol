// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (utils/TransientSlot.sol)
// Modified from OpenZeppelin implementation

pragma solidity 0.8.24;

/**
 * @dev Library for reading and writing value-types to specific transient storage slots.
 *
 * Transient slots are often used to store temporary data that is only needed during a transaction.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 *
 * _Available since v5.1._
 */
library TransientSlot {
    /**
     * @dev UDVT that represent a slot holding a boolean.
     */
    type BooleanSlot is bytes32;

    /**
     * @dev Cast a bytes32 to a BooleanSlot.
     */
    function asBoolean(bytes32 slot) internal pure returns (BooleanSlot) {
        return BooleanSlot.wrap(slot);
    }

    /**
     * @dev Load the value held at location `slot` in transient storage.
     */
    function tload(BooleanSlot slot) internal view returns (bool value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /**
     * @dev Store `value` at location `slot` in transient storage.
     */
    function tstore(BooleanSlot slot, bool value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
