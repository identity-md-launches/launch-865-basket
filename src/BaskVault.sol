// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "./FullMath.sol";

interface IStockToken {
    function decimals() external view returns (uint8);
    function uid() external view returns (bytes32);
    function oraclePaused() external view returns (bool);
}

interface IStockFactory {
    function tokenAddress(bytes32 uid) external view returns (address);
}

interface IFeed {
    function decimals() external view returns (uint8);
    function aggregator() external view returns (address);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Basket's immutable index vault for Stock Tokens on Robinhood Chain (4663).
contract BaskVault {
    using FullMath for uint256;

    string public constant name = "Basket";
    string public constant symbol = "BASK";
    uint8 public constant decimals = 18;
    address public constant STOCK_FACTORY = 0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046;
    uint256 public constant MAX_ASSETS = 64;
    uint256 public constant MAX_NAV_CAP = 10_000_000_000e18;
    uint256 public constant LOCKED_SHARES = 1e15;
    uint256 public constant PROPOSAL_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;

    enum Reason {
        OK,
        Genesis,
        OpeningDelay,
        Paused,
        NotListed,
        Closed,
        Unreadable,
        OwedUnderfunded,
        MarketClosed,
        MarketStale,
        InvalidPrice,
        Short,
        ZeroNAV,
        NAVCap,
        AssetCap,
        BucketCap
    }

    enum Kind {
        List,
        Feed,
        Band,
        Reopen,
        Guardian,
        NAVCap
    }

    struct Asset {
        address token;
        address feed;
        bool open;
        uint256 minAnswer;
        uint256 maxAnswer;
        uint256 listedAt;
        uint256 probationUntil;
    }

    struct Proposal {
        Kind kind;
        address token;
        address target;
        uint256 value;
        uint256 readyAt;
        uint256 closeNonce;
        bool active;
    }

    struct Deficit {
        uint256 amount;
        uint256 since;
    }

    struct AssetView {
        address token;
        address feed;
        int256 answer;
        uint256 updatedAt;
        uint256 minAnswer;
        uint256 maxAnswer;
        bool open;
        bool probation;
        uint256 listedAt;
        uint256 managed;
        bool short;
        bool readable;
        uint256 totalOwed;
    }

    error Unauthorized();
    error Reentrancy();
    error InvalidAddress();
    error InvalidInput();
    error InvalidAsset(address token);
    error InvalidFeed(address feed);
    error ProposalUnavailable();
    error ProposalNotReady();
    error ChangeCooldown();
    error DepositUnavailable(Reason reason, address asset);
    error DeadlineExpired();
    error Slippage();
    error InsufficientShares();
    error InsufficientAllowance();
    error TransferFailed(address token);
    error LossNotReady();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event OwnershipProposed(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event GuardianChanged(address indexed guardian);
    event FeeRecipientSet(address indexed recipient);
    event DepositsPaused(bool paused);
    event AssetClosed(address indexed token);
    event AssetOpened(address indexed token);
    event AssetListed(address indexed token, address indexed feed, uint256 minAnswer, uint256 maxAnswer);
    event FeedChanged(address indexed token, address indexed feed);
    event BandChanged(address indexed token, uint256 minAnswer, uint256 maxAnswer);
    event GenesisFinalized(uint256 depositsOpenAt);
    event NAVCapChanged(uint256 cap);
    event ProposalCreated(uint256 indexed id, Kind kind, address token, address target, uint256 value, uint256 readyAt);
    event ProposalCancelled(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event Deposited(
        address indexed caller,
        address indexed token,
        address indexed receiver,
        uint256 amount,
        uint256 shares,
        uint256 fee
    );
    event Redeemed(address indexed caller, uint256 shares, uint256 fee);
    event LegPaid(address indexed caller, address indexed token, uint256 amount);
    event PaymentDeferred(address indexed caller, address indexed token, uint256 amount);
    event Claimed(address indexed caller, address indexed token, address indexed to, uint256 amount);
    event DeficitFlagged(address indexed token, uint256 amount, uint256 since);
    event LossRecognized(address indexed token, uint256 amount);
    event DeficitCleared(address indexed token);

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Asset[] public assets;
    mapping(address => uint256) public assetIndex; // Index + 1; zero means unlisted.
    mapping(address => address) public feedAsset;
    mapping(address => uint256) public managed;
    mapping(address => mapping(address => uint256)) public owed;
    mapping(address => uint256) public totalOwed;
    mapping(address => Deficit) public deficits;
    mapping(address => uint256) public closeNonce;
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public depositsOpenAt;
    bool public depositsPaused;
    uint256 public NAV_CAP = 1_000_000e18;
    uint256 public bucket;
    uint256 public bucketUpdatedAt;
    uint256 public nextAssetChangeAt;
    uint256 private entered;

    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyRole() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0) || owner_ == guardian_) revert InvalidAddress();
        owner = owner_;
        guardian = guardian_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
    }

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientShares();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientShares();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transferOwnership(address next) external nonReentrant onlyOwner {
        if (next == address(0) || next == guardian) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipProposed(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert Unauthorized();
        if (msg.sender == guardian) revert InvalidAddress();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    function setFeeRecipient(address recipient) external nonReentrant onlyOwner {
        if (feeRecipient != address(0) || recipient == address(0) || recipient == address(this)) {
            revert InvalidAddress();
        }
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function pauseDeposits() external nonReentrant onlyRole {
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    function unpauseDeposits() external nonReentrant onlyOwner {
        depositsPaused = false;
        emit DepositsPaused(false);
    }

    function closeAsset(address token) external nonReentrant onlyRole {
        _asset(token).open = false;
        ++closeNonce[token];
        emit AssetClosed(token);
    }

    function lowerNAVCap(uint256 cap) external nonReentrant onlyOwner {
        if (cap >= NAV_CAP) revert InvalidInput();
        NAV_CAP = cap;
        emit NAVCapChanged(cap);
    }

    function finalizeGenesis() external nonReentrant onlyOwner {
        if (depositsOpenAt != 0 || assets.length < 3) revert InvalidInput();
        depositsOpenAt = block.timestamp + 72 hours;
        emit GenesisFinalized(depositsOpenAt);
    }

    function proposeAsset(address token, address feed) external nonReentrant onlyOwner returns (uint256) {
        return _proposeAsset(token, feed);
    }

    function proposeAssets(address[] calldata tokens, address[] calldata feeds)
        external
        nonReentrant
        onlyOwner
        returns (uint256[] memory ids)
    {
        if (tokens.length != feeds.length) revert InvalidInput();
        ids = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            ids[i] = _proposeAsset(tokens[i], feeds[i]);
        }
    }

    function _proposeAsset(address token, address feed) internal returns (uint256) {
        uint256 answer = _checkListing(token, feed);
        if (depositsOpenAt == 0) {
            _list(token, feed, answer);
            return 0;
        }
        return _propose(Kind.List, token, feed, 0);
    }

    function proposeFeed(address token, address feed) external nonReentrant onlyOwner returns (uint256) {
        Asset storage a = _asset(token);
        _checkReplacement(a, feed);
        return _propose(Kind.Feed, token, feed, 0);
    }

    function proposeBand(address token) external nonReentrant onlyOwner returns (uint256) {
        _asset(token);
        return _propose(Kind.Band, token, address(0), 0);
    }

    function proposeReopen(address token) external nonReentrant onlyOwner returns (uint256) {
        _asset(token);
        return _propose(Kind.Reopen, token, address(0), 0);
    }

    function proposeGuardian(address next) external nonReentrant onlyOwner returns (uint256) {
        if (next == address(0) || next == owner) revert InvalidAddress();
        return _propose(Kind.Guardian, address(0), next, 0);
    }

    function proposeNAVCap(uint256 cap) external nonReentrant onlyOwner returns (uint256) {
        if (cap <= NAV_CAP || cap > MAX_NAV_CAP) revert InvalidInput();
        return _propose(Kind.NAVCap, address(0), address(0), cap);
    }

    function _propose(Kind kind, address token, address target, uint256 value) internal returns (uint256 id) {
        id = ++proposalCount;
        uint256 ready = block.timestamp + PROPOSAL_DELAY;
        proposals[id] = Proposal(kind, token, target, value, ready, closeNonce[token], true);
        emit ProposalCreated(id, kind, token, target, value, ready);
    }

    function cancelProposal(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        if (msg.sender != owner && (msg.sender != guardian || p.kind == Kind.Guardian)) revert Unauthorized();
        if (!p.active) revert ProposalUnavailable();
        p.active = false;
        emit ProposalCancelled(id);
    }

    function executeProposal(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        if (!_pending(p)) revert ProposalUnavailable();
        if (block.timestamp < p.readyAt) revert ProposalNotReady();
        p.active = false;
        if (p.kind == Kind.List || p.kind == Kind.Feed) {
            if (block.timestamp < nextAssetChangeAt) revert ChangeCooldown();
            nextAssetChangeAt = block.timestamp + 24 hours;
        }
        if (p.kind == Kind.List) {
            _list(p.token, p.target, _checkListing(p.token, p.target));
        } else if (p.kind == Kind.Feed) {
            Asset storage a = _asset(p.token);
            _checkReplacement(a, p.target);
            delete feedAsset[a.feed];
            a.feed = p.target;
            feedAsset[p.target] = p.token;
            emit FeedChanged(p.token, p.target);
        } else if (p.kind == Kind.Band) {
            Asset storage a = _asset(p.token);
            (bool ok, int256 answer, uint256 updated) = _readFeed(a.feed);
            if (!ok || answer <= 0 || updated > block.timestamp || block.timestamp - updated >= 26 hours) {
                revert InvalidFeed(a.feed);
            }
            (a.minAnswer, a.maxAnswer) = _band(uint256(answer));
            emit BandChanged(p.token, a.minAnswer, a.maxAnswer);
        } else if (p.kind == Kind.Reopen) {
            _asset(p.token).open = true;
            emit AssetOpened(p.token);
        } else if (p.kind == Kind.Guardian) {
            if (p.target == owner) revert InvalidAddress();
            guardian = p.target;
            emit GuardianChanged(p.target);
        } else {
            if (p.value <= NAV_CAP) revert InvalidInput();
            NAV_CAP = p.value;
            emit NAVCapChanged(p.value);
        }
        emit ProposalExecuted(id);
    }

    function _pending(Proposal storage p) internal view returns (bool) {
        return p.active && block.timestamp < p.readyAt + PROPOSAL_WINDOW
            && (p.kind != Kind.Reopen || p.closeNonce == closeNonce[p.token]);
    }

    function pendingProposals() external view returns (uint256[] memory ids, Proposal[] memory entries) {
        uint256 count;
        for (uint256 i = 1; i <= proposalCount; ++i) {
            if (_pending(proposals[i])) ++count;
        }
        ids = new uint256[](count);
        entries = new Proposal[](count);
        uint256 j;
        for (uint256 i = 1; i <= proposalCount; ++i) {
            if (_pending(proposals[i])) {
                ids[j] = i;
                entries[j++] = proposals[i];
            }
        }
    }

    function _asset(address token) internal view returns (Asset storage a) {
        uint256 index = assetIndex[token];
        if (index == 0) revert InvalidAsset(token);
        return assets[index - 1];
    }

    function _checkListing(address token, address feed) internal view returns (uint256) {
        if (assetIndex[token] != 0 || assets.length >= MAX_ASSETS || token == address(0)) revert InvalidAsset(token);
        if (
            IStockToken(token).decimals() != 18
                || IStockFactory(STOCK_FACTORY).tokenAddress(IStockToken(token).uid()) != token
        ) revert InvalidAsset(token);
        return _checkFeed(token, feed);
    }

    function _checkFeed(address token, address feed) internal view returns (uint256) {
        if (feed == address(0) || (feedAsset[feed] != address(0) && feedAsset[feed] != token)) {
            revert InvalidFeed(feed);
        }
        if (IFeed(feed).decimals() != 8 || IFeed(feed).aggregator() == address(0)) revert InvalidFeed(feed);
        (bool ok, int256 answer,) = _readFeed(feed);
        if (!ok || answer <= 0) revert InvalidFeed(feed);
        return uint256(answer);
    }

    function _checkReplacement(Asset storage a, address feed) internal view {
        uint256 answer = _checkFeed(a.token, feed);
        if (answer < a.minAnswer || answer > a.maxAnswer) revert InvalidFeed(feed);
    }

    function _band(uint256 answer) internal pure returns (uint256, uint256) {
        if (answer > type(uint256).max / 4) revert InvalidInput();
        return (answer / 4, answer * 4);
    }

    function _list(address token, address feed, uint256 answer) internal {
        (uint256 low, uint256 high) = _band(answer);
        assets.push(
            Asset(token, feed, true, low, high, block.timestamp, depositsOpenAt == 0 ? 0 : block.timestamp + 30 days)
        );
        assetIndex[token] = assets.length;
        feedAsset[feed] = token;
        emit AssetListed(token, feed, low, high);
    }

    /// @dev Bounded output copying also protects against a token returning enormous data.
    function _balance(address token) internal view returns (bool ok, uint256 amount) {
        bytes memory data = abi.encodeWithSelector(bytes4(0x70a08231), address(this));
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(50000, token, add(data, 32), mload(data), out, 32)
            ok := and(ok, eq(returndatasize(), 32))
            amount := mload(out)
        }
    }

    function _available(address token) internal view returns (bool readable, uint256 available) {
        uint256 balance;
        (readable, balance) = _balance(token);
        if (!readable) return (false, managed[token]);
        uint256 reserved = totalOwed[token];
        return (true, balance > reserved ? balance - reserved : 0);
    }

    function _readFeed(address feed) internal view returns (bool ok, int256 answer, uint256 updated) {
        bytes memory data = abi.encodeWithSelector(IFeed.latestRoundData.selector);
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gas(), feed, add(data, 32), mload(data), out, 160)
            ok := and(ok, eq(returndatasize(), 160))
            answer := mload(add(out, 32))
            updated := mload(add(out, 96))
        }
        if (!ok) return (false, 0, 0);
    }

    function _priceOK(Asset storage a, bool ok, int256 answer, uint256 updated) internal view returns (bool) {
        if (
            !ok || answer <= 0 || uint256(answer) < a.minAnswer || uint256(answer) > a.maxAnswer
                || updated > block.timestamp || block.timestamp - updated > 26 hours
        ) return false;
        bytes memory data = abi.encodeWithSelector(IStockToken.oraclePaused.selector);
        uint256 paused;
        address token = a.token;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gas(), token, add(data, 32), mload(data), out, 32)
            ok := and(ok, eq(returndatasize(), 32))
            paused := mload(out)
        }
        return ok && paused == 0;
    }

    function marketOpen() public view returns (bool) {
        uint256 day = (block.timestamp / 1 days + 4) % 7;
        uint256 time = block.timestamp % 1 days;
        return day >= 1 && day <= 5 && time >= 55800 && time < 70200;
    }

    /// @dev Shared by deposit and its status/preview: the first failing reason and asset are identical.
    function _depositState(address token)
        internal
        view
        returns (Reason reason, address fault, uint256 nav, uint256 price)
    {
        if (depositsOpenAt == 0) return (Reason.Genesis, address(0), 0, 0);
        if (block.timestamp < depositsOpenAt) return (Reason.OpeningDelay, address(0), 0, 0);
        if (depositsPaused) return (Reason.Paused, address(0), 0, 0);
        if (assetIndex[token] == 0) return (Reason.NotListed, token, 0, 0);
        if (!_asset(token).open) return (Reason.Closed, token, 0, 0);
        (bool readable, uint256 balance) = _balance(token);
        if (!readable) return (Reason.Unreadable, token, 0, 0);
        if (balance < totalOwed[token]) return (Reason.OwedUnderfunded, token, 0, 0);
        if (!marketOpen()) return (Reason.MarketClosed, address(0), 0, 0);
        uint256 fresh;
        // Read once per feed, then count market freshness before evaluating portfolio faults.
        int256[] memory answers = new int256[](assets.length);
        uint256[] memory times = new uint256[](assets.length);
        bool[] memory reads = new bool[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            (reads[i], answers[i], times[i]) = _readFeed(assets[i].feed);
            if (reads[i] && times[i] <= block.timestamp && block.timestamp - times[i] <= 4 hours) ++fresh;
        }
        if (fresh < 3) return (Reason.MarketStale, address(0), 0, 0);
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            (bool ok, uint256 available) = _available(a.token);
            if (!ok) return (Reason.Unreadable, a.token, 0, 0);
            uint256 amount = managed[a.token];
            if (available < amount) return (Reason.Short, a.token, 0, 0);
            if (amount != 0 || a.token == token) {
                if (!_priceOK(a, reads[i], answers[i], times[i])) return (Reason.InvalidPrice, a.token, 0, 0);
                uint256 answer = uint256(answers[i]);
                nav += amount.mulDiv(answer, 1e8);
                if (a.token == token) price = answer;
            }
        }
        if (totalSupply != 0 && nav == 0) return (Reason.ZeroNAV, address(0), 0, 0);
        return (Reason.OK, address(0), nav, price);
    }

    function depositStatus(address token) external view returns (Reason reason, address fault) {
        (reason, fault,,) = _depositState(token);
    }

    function decayedBucket() public view returns (uint256) {
        uint256 elapsed = block.timestamp - bucketUpdatedAt;
        return elapsed >= 1 days ? 0 : bucket - bucket.mulDiv(elapsed, 1 days);
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount / 200 + (amount % 200 == 0 ? 0 : 1);
    }

    function _quote(address token, uint256 amount)
        internal
        view
        returns (uint256 received, uint256 fee, uint256 nextBucket)
    {
        (Reason reason, address fault, uint256 nav, uint256 price) = _depositState(token);
        if (reason != Reason.OK) revert DepositUnavailable(reason, fault);
        uint256 value = amount.mulDiv(price, 1e8);
        nextBucket = _checkCaps(token, amount, price, nav + value, value);
        uint256 gross = totalSupply == 0 ? value : value.mulDiv(totalSupply, nav);
        fee = _fee(gross);
        received = gross - fee;
        if (totalSupply == 0) {
            if (received <= LOCKED_SHARES) revert Slippage();
            received -= LOCKED_SHARES;
        }
        if (received == 0) revert Slippage();
    }

    function _checkCaps(address token, uint256 amount, uint256 price, uint256 nav2, uint256 value)
        internal
        view
        returns (uint256 nextBucket)
    {
        if (nav2 > NAV_CAP) revert DepositUnavailable(Reason.NAVCap, token);
        bool probation = block.timestamp < _asset(token).probationUntil;
        uint256 cap = probation ? nav2 / 100 : nav2.mulDiv(5, 100);
        uint256 floor = probation ? 5_000e18 : 25_000e18;
        if (cap < floor) cap = floor;
        if ((managed[token] + amount).mulDiv(price, 1e8) > cap) revert DepositUnavailable(Reason.AssetCap, token);
        nextBucket = decayedBucket() + value;
        cap = nav2 / 4;
        if (cap < 100_000e18) cap = 100_000e18;
        if (nextBucket > cap) revert DepositUnavailable(Reason.BucketCap, token);
    }

    function previewDeposit(address token, uint256 amount)
        external
        view
        returns (uint256 receiverShares, uint256 feeShares)
    {
        (receiverShares, feeShares,) = _quote(token, amount);
    }

    function deposit(address token, uint256 amount, address receiver, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        uint256 fee;
        uint256 nextBucket;
        (shares, fee, nextBucket) = _quote(token, amount);
        if (shares < minSharesOut) revert Slippage();
        (bool ok, uint256 beforeBalance) = _balance(token);
        if (!ok) revert TransferFailed(token);
        _callToken(token, abi.encodeWithSelector(bytes4(0x23b872dd), msg.sender, address(this), amount));
        uint256 afterBalance;
        (ok, afterBalance) = _balance(token);
        if (!ok || afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert TransferFailed(token);
        }
        managed[token] += amount;
        bucket = nextBucket;
        bucketUpdatedAt = block.timestamp;
        for (uint256 i; i < assets.length; ++i) {
            address t = assets[i].token;
            if (deficits[t].amount != 0) {
                delete deficits[t];
                emit DeficitCleared(t);
            }
        }
        if (totalSupply == 0) _mint(address(0xdEaD), LOCKED_SHARES);
        _mint(receiver, shares);
        if (feeRecipient != address(0) && fee != 0) _mint(feeRecipient, fee);
        emit Deposited(msg.sender, token, receiver, amount, shares, fee);
    }

    function _callToken(address token, bytes memory data) internal {
        bool ok;
        assembly ("memory-safe") {
            let out := mload(0x40)
            let success := call(gas(), token, 0, add(data, 32), mload(data), out, 32)
            ok := and(success, or(iszero(returndatasize()), and(eq(returndatasize(), 32), eq(mload(out), 1))))
        }
        if (!ok) revert TransferFailed(token);
    }

    /// @dev Only reachable from a guarded redeem/claim. A failed self-call rolls back even a lying transfer.
    function payLeg(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        (bool ok, uint256 beforeBalance) = _balance(token);
        if (!ok) revert TransferFailed(token);
        _callToken(token, abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount));
        uint256 afterBalance;
        (ok, afterBalance) = _balance(token);
        if (!ok || beforeBalance < afterBalance || beforeBalance - afterBalance != amount) {
            revert TransferFailed(token);
        }
    }

    function previewRedeem(uint256 shares) public view returns (uint256[] memory amounts, uint256 fee) {
        if (shares > totalSupply) revert InsufficientShares();
        fee = _fee(shares);
        uint256 net = shares - fee;
        amounts = new uint256[](assets.length);
        if (totalSupply == 0) return (amounts, fee);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i].token;
            (, uint256 available) = _available(token);
            uint256 amount = managed[token];
            if (available < amount) amount = available;
            amounts[i] = amount.mulDiv(net, totalSupply);
        }
    }

    function redeem(uint256 shares, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (shares > balanceOf[msg.sender]) revert InsufficientShares();
        uint256 supply = totalSupply;
        uint256 fee = _fee(shares);
        uint256 net = shares - fee;
        if (feeRecipient == address(0)) {
            _burn(msg.sender, shares);
        } else {
            _transfer(msg.sender, feeRecipient, fee);
            _burn(msg.sender, net);
        }
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i].token;
            (, uint256 available) = _available(token);
            uint256 amount = managed[token];
            if (available < amount) amount = available;
            uint256 leg = supply == 0 ? 0 : amount.mulDiv(net, supply);
            if (i < minAmountsOut.length && leg < minAmountsOut[i]) revert Slippage();
            amounts[i] = leg;
            managed[token] -= leg;
            if (leg == 0) continue;
            // Copy no return data: a hostile token cannot make the caller allocate it.
            bytes memory data = abi.encodeCall(this.payLeg, (token, msg.sender, leg));
            bool paid;
            assembly ("memory-safe") { paid := call(250000, address(), 0, add(data, 32), mload(data), 0, 0) }
            if (paid) {
                emit LegPaid(msg.sender, token, leg);
            } else {
                owed[msg.sender][token] += leg;
                totalOwed[token] += leg;
                emit PaymentDeferred(msg.sender, token, leg);
            }
        }
        emit Redeemed(msg.sender, shares, fee);
    }

    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        (bool ok, uint256 balance) = _balance(token);
        if (!ok) revert TransferFailed(token);
        amount = owed[msg.sender][token];
        if (balance < amount) amount = balance;
        owed[msg.sender][token] -= amount;
        totalOwed[token] -= amount;
        if (amount != 0) this.payLeg(token, to, amount);
        emit Claimed(msg.sender, token, to, amount);
    }

    function flagDeficit(address token) external nonReentrant {
        _asset(token);
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert TransferFailed(token);
        uint256 amount = managed[token] > available ? managed[token] - available : 0;
        if (amount <= deficits[token].amount) revert InvalidInput();
        deficits[token] = Deficit(amount, block.timestamp);
        emit DeficitFlagged(token, amount, block.timestamp);
    }

    function recognizeLoss(address token) external nonReentrant {
        _asset(token);
        Deficit memory d = deficits[token];
        if (d.amount == 0 || block.timestamp < d.since + 7 days) revert LossNotReady();
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert TransferFailed(token);
        uint256 loss = managed[token] > available ? managed[token] - available : 0;
        if (loss > d.amount) loss = d.amount;
        managed[token] -= loss;
        delete deficits[token];
        emit LossRecognized(token, loss);
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function allAssets() external view returns (AssetView[] memory result) {
        result = new AssetView[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            (, int256 answer, uint256 updated) = _readFeed(a.feed);
            (bool readable, uint256 available) = _available(a.token);
            result[i] = AssetView(
                a.token,
                a.feed,
                answer,
                updated,
                a.minAnswer,
                a.maxAnswer,
                a.open,
                block.timestamp < a.probationUntil,
                a.listedAt,
                managed[a.token],
                available < managed[a.token],
                readable,
                totalOwed[a.token]
            );
        }
    }

    function navPerShare() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 nav;
        for (uint256 i; i < assets.length; ++i) {
            Asset storage a = assets[i];
            uint256 amount = managed[a.token];
            if (amount == 0) continue;
            (bool ok, int256 answer, uint256 updated) = _readFeed(a.feed);
            if (!_priceOK(a, ok, answer, updated)) revert DepositUnavailable(Reason.InvalidPrice, a.token);
            nav += amount.mulDiv(uint256(answer), 1e8);
        }
        return nav.mulDiv(1e18, totalSupply);
    }
}
