// SPDX-License Identifier: MIT
pragma solidity 0.8.20;

library LibAddressSet {
    struct AddressSet {
        address[] addrs;
        mapping(address => bool) saved;
    }

    function rand(AddressSet storage s, uint256 seed) internal view returns (address) {
        if (s.addrs.length > 0) {
            return s.addrs[seed % s.addrs.length];
        } else {
            return address(0xc0ffee);
        }
    }

    function add(AddressSet storage s, address addr) internal {
        if (!s.saved[addr]) {
            s.addrs.push(addr);
            s.saved[addr] = true;
        }
    }

    function contains(AddressSet storage s, address addr) internal view returns (bool) {
        return s.saved[addr];
    }

    function count(AddressSet storage s) internal view returns (uint256) {
        return s.addrs.length;
    }

    function getAddressAtIndex(AddressSet storage s, uint256 index) public view returns (address) {
        return s.addrs[index];
    }
}
