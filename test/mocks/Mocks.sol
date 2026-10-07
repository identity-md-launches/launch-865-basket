// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract StockFactoryMock {
    mapping(bytes32 => address) public tokenAddress;

    function set(bytes32 id, address token) external {
        tokenAddress[id] = token;
    }
}

contract FeedMock {
    uint8 public decimals = 8;
    address public aggregator = address(1);
    int256 public answer = 100e8;
    uint256 public updatedAt;
    bool public broken;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function configure(uint8 d, address a, bool b) external {
        decimals = d;
        aggregator = a;
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed broken");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract StockMock {
    bytes32 public uid;
    uint8 public decimals = 18;
    bool private pausedOracle;
    bool public brokenOracle;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    // 0 normal, 1 revert, 2 false, 3 no return, 4 taxed, 5 no movement,
    // 6 gas bomb, 7 huge return, 8 malformed boolean, 9 >250k work.
    uint256 public transferMode;
    // 0 normal, 1 revert, 2 empty, 3 extra word, 4 gas bomb, 5 huge return,
    // 6 almost 50k of work (readable but costly).
    uint256 public balanceMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackBlocked;

    constructor(bytes32 id) {
        uid = id;
    }

    function configure(uint8 d, bool p, bool broken) external {
        decimals = d;
        pausedOracle = p;
        brokenOracle = broken;
    }

    function modes(uint256 transfer_, uint256 balance_) external {
        transferMode = transfer_;
        balanceMode = balance_;
    }

    function blockHolder(address holder, bool value) external {
        blocked[holder] = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function rawBalance(address holder) external view returns (uint256) {
        return balances[holder];
    }

    function oraclePaused() external view returns (bool) {
        require(!brokenOracle, "oracle broken");
        return pausedOracle;
    }

    function balanceOf(address holder) external view returns (uint256) {
        uint256 mode = balanceMode;
        if (mode == 1) revert("balance broken");
        if (mode == 2) {
            assembly { return(0, 0) }
        }
        if (mode == 3) {
            assembly {
                mstore(0, 1)
                return(0, 64)
            }
        }
        if (mode == 4) {
            assembly { invalid() }
        }
        if (mode == 5) {
            assembly { return(0, 0x100000) }
        }
        if (mode == 6) {
            uint256 initial = gasleft();
            while (initial - gasleft() < 43_000) {}
        }
        return balances[holder];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        uint256 mode = transferMode;
        require(!blocked[from] && !blocked[to] && mode != 1, "blocked or paused");
        if (mode == 6) {
            assembly { invalid() }
        }
        if (mode == 9) {
            uint256 initial = gasleft();
            while (initial - gasleft() < 300_000) {}
        }
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            callbackBlocked = !ok && result.length == 4 && bytes4(result) == bytes4(keccak256("Reentrancy()"));
            require(callbackBlocked, "callback escaped guard");
        }
        if (mode != 5) {
            balances[from] -= amount;
            uint256 sent = mode == 4 ? amount - amount / 100 : amount;
            balances[to] += sent;
        }
        if (mode == 2) return false;
        if (mode == 3) {
            assembly { return(0, 0) }
        }
        if (mode == 7) {
            assembly {
                mstore(0, 1)
                return(0, 0x10000)
            }
        }
        if (mode == 8) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract RejectCalls {
    fallback() external {
        revert("must never call fee recipient");
    }
}
