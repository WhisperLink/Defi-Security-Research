// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Minimal ERC20 used as the "locked" rsETH backing inside the adapters.
contract MockRsETH {
    string public name = "rsETH (mock)";
    string public symbol = "rsETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// A cross-chain message: "release `amount` of rsETH to `to`".
/// `attesters` is the set of DVN signers that vouched for this message.
struct BridgeMessage {
    uint256 amount;
    address to;
    address[] attesters;
}

/// ----------------------------------------------------------------------
/// VULNERABLE adapter: mirrors the Kelp production configuration:
///   * 1-of-1 DVN: a single verifier's attestation is sufficient.
///   * No supply invariant, no rate limit, no pause.
/// If that single DVN is compromised (Lazarus), any forged message executes.
/// ----------------------------------------------------------------------
contract VulnerableOFTAdapter {
    MockRsETH public immutable token;
    address public theDVN; // the single trusted verifier (1-of-1)

    constructor(MockRsETH _token, address _dvn) {
        token = _token;
        theDVN = _dvn;
    }

    /// Executes a verified inbound message (the on-chain `lzReceive` path).
    function lzReceive(BridgeMessage calldata m) external {
        // 1-of-1: accept as long as the one configured DVN is among the attesters.
        bool ok;
        for (uint256 i; i < m.attesters.length; i++) {
            if (m.attesters[i] == theDVN) { ok = true; break; }
        }
        require(ok, "DVN not attested");
        // No cap. No locked>=released invariant. Just release.
        token.transfer(m.to, m.amount);
    }
}

/// ----------------------------------------------------------------------
/// GUARDED adapter: the proposed patch. Three independent controls:
///   (1) M-of-N DVN quorum of DISTINCT known signers.
///   (2) Rolling rate limit on released volume.
///   (3) Supply invariant: cumulative released <= cumulative locked.
///   (+) Pausable guardian circuit breaker.
/// ----------------------------------------------------------------------
contract GuardedOFTAdapter {
    MockRsETH public immutable token;

    mapping(address => bool) public isDVN; // known, independent DVNs
    uint256 public immutable threshold;    // e.g. 2 (of N)

    uint256 public lockedSupply;           // backing legitimately locked here
    uint256 public releasedSupply;         // cumulative released

    uint256 public immutable windowCap;    // max release per window
    uint256 public windowStart;
    uint256 public releasedInWindow;
    uint256 public constant WINDOW = 1 days;

    address public guardian;
    bool public paused;

    error InsufficientDVNQuorum(uint256 got, uint256 need);
    error RateLimited(uint256 requested, uint256 remaining);
    error SupplyInvariantViolated(uint256 released, uint256 locked);
    error Paused();

    constructor(MockRsETH _token, address[] memory dvns, uint256 _threshold, uint256 _windowCap) {
        token = _token;
        for (uint256 i; i < dvns.length; i++) isDVN[dvns[i]] = true;
        threshold = _threshold;
        windowCap = _windowCap;
        guardian = msg.sender;
    }

    /// Legit outbound bridging locks backing here; tracked for the invariant.
    function recordLock(uint256 amount) external { lockedSupply += amount; }

    function setPaused(bool p) external {
        require(msg.sender == guardian, "not guardian");
        paused = p;
    }

    function lzReceive(BridgeMessage calldata m) external {
        if (paused) revert Paused();

        // (1) M-of-N quorum of DISTINCT known DVNs.
        uint256 distinct = _countDistinctKnownDVNs(m.attesters);
        if (distinct < threshold) revert InsufficientDVNQuorum(distinct, threshold);

        // (2) Rolling rate limit.
        if (block.timestamp >= windowStart + WINDOW) {
            windowStart = block.timestamp;
            releasedInWindow = 0;
        }
        if (releasedInWindow + m.amount > windowCap) {
            revert RateLimited(m.amount, windowCap - releasedInWindow);
        }

        // (3) Supply invariant: never release more than is locked.
        if (releasedSupply + m.amount > lockedSupply) {
            revert SupplyInvariantViolated(releasedSupply + m.amount, lockedSupply);
        }

        releasedInWindow += m.amount;
        releasedSupply += m.amount;
        token.transfer(m.to, m.amount);
    }

    function _countDistinctKnownDVNs(address[] calldata attesters) internal view returns (uint256 n) {
        for (uint256 i; i < attesters.length; i++) {
            address a = attesters[i];
            if (!isDVN[a]) continue;
            bool dup;
            for (uint256 j; j < i; j++) {
                if (attesters[j] == a) { dup = true; break; }
            }
            if (!dup) n++;
        }
    }
}
