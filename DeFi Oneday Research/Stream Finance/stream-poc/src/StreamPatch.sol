// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Minimal 18-decimal ERC20 for the self-contained patch demo.
contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) { symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; _move(f, to, a); return true;
    }
    function _move(address f, address to, uint256 a) internal {
        require(balanceOf[f] >= a, "bal"); balanceOf[f] -= a; balanceOf[to] += a;
    }
}

interface IOracle {
    function price() external view returns (uint256); // loan units per 1 collateral unit, 1e36-scaled
}

/// The vulnerable design: a FIXED price that ignores the real market.
/// This is what the Stream xUSD/USDC market used (oracle stuck near $1.27).
contract HardcodedOracle is IOracle {
    uint256 public immutable fixedPrice;
    constructor(uint256 p) { fixedPrice = p; }
    function price() external view returns (uint256) { return fixedPrice; }
}

/// Patch (1): an oracle that actually tracks the collateral's market price.
contract MarketPriceOracle is IOracle {
    uint256 public p;
    function set(uint256 _p) external { p = _p; }
    function price() external view returns (uint256) { return p; }
}

/// Patch (3): sanity-bounded oracle. Serves the nominal price ONLY while it stays
/// within `maxDevBps` of an independent backing/redemption feed; otherwise it
/// reverts, freezing new borrows instead of silently minting bad debt.
contract SanityBoundedOracle is IOracle {
    uint256 public immutable nominal;   // e.g. hardcoded $1.27
    IOracle public immutable backing;   // independent backing/redemption feed
    uint256 public immutable maxDevBps;
    error OracleDeviation(uint256 nominal, uint256 backing);
    constructor(uint256 _nominal, IOracle _backing, uint256 _maxDevBps) {
        nominal = _nominal; backing = _backing; maxDevBps = _maxDevBps;
    }
    function price() external view returns (uint256) {
        uint256 b = backing.price();
        uint256 diff = nominal > b ? nominal - b : b - nominal;
        if (diff * 10_000 > b * maxDevBps) revert OracleDeviation(nominal, b);
        return nominal;
    }
}

/// Minimal Morpho-style isolated lending market (loan vs collateral) whose only
/// risk input is the oracle. Mirrors how Morpho decides health/liquidatability.
contract MiniLend {
    MockToken public immutable loan;
    MockToken public immutable collateral;
    IOracle public immutable oracle;
    uint256 public immutable lltv; // 1e18

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    error Unhealthy();
    error Healthy();

    constructor(MockToken _loan, MockToken _coll, IOracle _oracle, uint256 _lltv) {
        loan = _loan; collateral = _coll; oracle = _oracle; lltv = _lltv;
    }

    function supply(uint256 a) external { loan.transferFrom(msg.sender, address(this), a); }

    function depositCollateral(uint256 a) external {
        collateral.transferFrom(msg.sender, address(this), a);
        collateralOf[msg.sender] += a;
    }

    function borrow(uint256 a) external {
        debtOf[msg.sender] += a;
        if (!_healthy(msg.sender)) revert Unhealthy();
        loan.transfer(msg.sender, a);
    }

    /// Liquidatable when debt exceeds the LLTV-weighted oracle value of collateral.
    function liquidate(address user) external {
        if (_healthy(user)) revert Healthy();
        // seize all collateral, clear debt (simplified)
        collateralOf[user] = 0;
        debtOf[user] = 0;
    }

    function collateralValue(address u) public view returns (uint256) {
        return collateralOf[u] * oracle.price() / 1e36; // in loan units
    }

    function _healthy(address u) internal view returns (bool) {
        return debtOf[u] <= collateralValue(u) * lltv / 1e18;
    }

    function isHealthy(address u) external view returns (bool) { return _healthy(u); }
}
