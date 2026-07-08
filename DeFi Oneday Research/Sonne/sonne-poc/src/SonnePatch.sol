// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// Self-contained model of the Compound V2 fork "empty market donation" bug and
/// its fix. MiniCToken mirrors Compound's exchange-rate math:
///   exchangeRate = (cash + borrows - reserves) / totalSupply
/// With a near-empty market (tiny totalSupply), a direct token DONATION (a plain
/// transfer, no mint) inflates `cash` while totalSupply stays tiny, so the rate
/// explodes and a few wei of cToken counts as enormous collateral.
///
/// The fix: seed the market at creation with a burned initial supply, so
/// totalSupply is never manipulably small and a donation only dilutes into the
/// (unredeemable) burned share instead of the attacker's position.

contract MockToken {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory s) { symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _m(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _m(f, to, a); return true;
    }
    function _m(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "bal"); balanceOf[f] -= a; balanceOf[to] += a; }
}

contract MiniCToken {
    MockToken public immutable underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public constant INITIAL_RATE = 2e26; // matches Sonne's soVELO initial rate

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    constructor(MockToken u) { underlying = u; }

    function exchangeRate() public view returns (uint256) {
        if (totalSupply == 0) return INITIAL_RATE;
        return underlying.balanceOf(address(this)) * 1e18 / totalSupply;
    }

    function mint(uint256 underlyingAmt) public returns (uint256 tokens) {
        tokens = underlyingAmt * 1e18 / exchangeRate();
        underlying.transferFrom(msg.sender, address(this), underlyingAmt);
        totalSupply += tokens;
        balanceOf[msg.sender] += tokens;
    }

    /// THE FIX: seed the market with a burned initial supply (sent to dead addr).
    function seedAndBurn(uint256 underlyingAmt) external {
        uint256 tokens = mint(underlyingAmt);
        balanceOf[msg.sender] -= tokens;
        balanceOf[DEAD] += tokens; // burned: never redeemable
    }

    function redeemUnderlying(uint256 underlyingAmt) external {
        uint256 tokens = underlyingAmt * 1e18 / exchangeRate();
        balanceOf[msg.sender] -= tokens;
        totalSupply -= tokens;
        underlying.transfer(msg.sender, underlyingAmt);
    }

    /// Collateral value of a user, in underlying units (what the lending market reads).
    function collateralValue(address u) public view returns (uint256) {
        return balanceOf[u] * exchangeRate() / 1e18;
    }
}

/// Minimal money market: lets you borrow `loan` up to your soVELO collateral value
/// (assume 1:1 price and 100% CF for clarity; only the collateral math matters).
contract MiniLend {
    MockToken public immutable loan;
    MiniCToken public immutable coll;
    error Undercollateralized(uint256 want, uint256 max);

    constructor(MockToken _loan, MiniCToken _coll) { loan = _loan; coll = _coll; }

    function borrow(uint256 amount) external {
        uint256 max = coll.collateralValue(msg.sender);
        if (amount > max) revert Undercollateralized(amount, max);
        loan.transfer(msg.sender, amount);
    }
}
