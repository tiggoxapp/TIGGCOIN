// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  TIGGCOIN ($TIGG) — FINAL (OpenZeppelin v5.x patterns)
  - Chain: Binance Smart Chain (EVM compatible)
  - Initial supply: 1,000,000,000 (1B) minted to deployer (msg.sender)
  - Max supply: 10,000,000,000 (10B)
  - Decimals: 18
  - Scheduled mint: +1B on 30 Sep at 00:00:00 UTC every 5 years (first at 2030-09-30). Hardcoded timestamps.
  - Emergency stop / restart (transfers & minting blocked while emergency)
  - Bridge mint/burn hooks restricted to BRIDGE_ROLE
  - Rescue functions for tokens & native currency (owner-only)
  - OpenZeppelin v5: uses _grantRole, Ownable(msg.sender), and _update hook
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TIGGCOIN is ERC20, AccessControl, Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    uint8 private constant _DECIMALS = 18;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * (10 ** uint256(_DECIMALS)); // 1B
    uint256 public constant TRANCHE_AMOUNT = 1_000_000_000 * (10 ** uint256(_DECIMALS)); // 1B each tranche
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * (10 ** uint256(_DECIMALS)); // 10B

    // Hardcoded scheduled mint timestamps (30 Sep 00:00:00 UTC every 5 years starting 2030)
    // These are UNIX timestamps (seconds since 1970-01-01 UTC)
    uint256[] public scheduledMints;
    uint256 public nextMintIndex = 0; // index for next scheduled mint

    // Emergency circuit breaker
    bool public emergencyStopped = false;

    // Events
    event MintScheduled(uint256 indexed amount, uint256 indexed unlockTime);
    event MintExecuted(address indexed to, uint256 amount, uint256 timestamp, uint256 newTotalSupply);
    event BridgeMint(address indexed to, uint256 amount, address indexed bridge);
    event BridgeBurn(address indexed from, uint256 amount, address indexed bridge);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);
    event EmergencyStopped(address indexed by, uint256 timestamp);
    event EmergencyLifted(address indexed by, uint256 timestamp);

    constructor() ERC20("TIGGCOIN", "TIGG") Ownable(msg.sender) {
        // Grant roles to deployer (OpenZeppelin v5 style)
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
        _grantRole(BRIDGE_ROLE, _msgSender());

        // Mint initial supply to deployer
        _mint(_msgSender(), INITIAL_SUPPLY);

        // Populate scheduled mint timestamps (30 Sep 00:00:00 UTC every 5 years starting 2030)
        // Note: timestamps are in seconds UTC
        // 2030-09-30 00:00:00 UTC
        scheduledMints.push(1916956800);
        // 2035-09-30
        scheduledMints.push(2074723200);
        // 2040-09-30
        scheduledMints.push(2232576000);
        // 2045-09-30
        scheduledMints.push(2390342400);
        // 2050-09-30
        scheduledMints.push(2548108800);
        // 2055-09-30
        scheduledMints.push(2705875200);
        // 2060-09-30
        scheduledMints.push(2863728000);
        // 2065-09-30
        scheduledMints.push(3021494400);
        // 2070-09-30
        scheduledMints.push(3179260800);

        // Emit schedule events for on-chain transparency
        for (uint256 i = 0; i < scheduledMints.length; i++) {
            emit MintScheduled(TRANCHE_AMOUNT, scheduledMints[i]);
        }
    }

    // override decimals
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ----------------------
    // Emergency controls
    // ----------------------
    function emergencyStop() external onlyOwner {
        emergencyStopped = true;
        emit EmergencyStopped(_msgSender(), block.timestamp);
    }

    function liftEmergencyStop() external onlyOwner {
        emergencyStopped = false;
        emit EmergencyLifted(_msgSender(), block.timestamp);
    }

    // ----------------------
    // Scheduled mint: execute next tranche
    // only callable by MINTER_ROLE, and blocked during emergency.
    // ----------------------
    function executeScheduledMint() external onlyRole(MINTER_ROLE) {
        require(!emergencyStopped, "TIGG: emergency stopped");
        require(nextMintIndex < scheduledMints.length, "TIGG: no scheduled mints left");

        uint256 unlockTime = scheduledMints[nextMintIndex];
        require(block.timestamp >= unlockTime, "TIGG: scheduled mint not yet available");

        uint256 currentSupply = totalSupply();
        require(currentSupply + TRANCHE_AMOUNT <= MAX_SUPPLY, "TIGG: max supply exceeded");

        // Mint tranche to owner for distribution/treasury control
        _mint(owner(), TRANCHE_AMOUNT);

        emit MintExecuted(owner(), TRANCHE_AMOUNT, block.timestamp, totalSupply());

        // advance index
        nextMintIndex += 1;
    }

    function scheduledMintsRemaining() external view returns (uint256) {
        if (nextMintIndex >= scheduledMints.length) return 0;
        return scheduledMints.length - nextMintIndex;
    }

    // ----------------------
    // Bridge functions (only BRIDGE_ROLE)
    // ----------------------
    function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(!emergencyStopped, "TIGG: emergency stopped");
        require(to != address(0), "TIGG: mint to zero");
        require(totalSupply() + amount <= MAX_SUPPLY, "TIGG: max supply exceeded");

        _mint(to, amount);
        emit BridgeMint(to, amount, _msgSender());
    }

    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(!emergencyStopped, "TIGG: emergency stopped");
        require(from != address(0), "TIGG: burn from zero");

        _burn(from, amount);
        emit BridgeBurn(from, amount, _msgSender());
    }

    // ----------------------
    // Accept native currency (BNB) and fallback
    // ----------------------
    receive() external payable {}
    fallback() external payable {}

    // ----------------------
    // Rescue / sweep functions (owner-only)
    // ----------------------
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TIGG: to zero");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function rescueAllERC20(address token, address to) external onlyOwner {
        require(to != address(0), "TIGG: to zero");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "TIGG: zero balance");
        IERC20(token).safeTransfer(to, bal);
        emit TokenRescued(token, to, bal);
    }

    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "TIGG: to zero");
        require(amount <= address(this).balance, "TIGG: insufficient balance");
        to.transfer(amount);
        emit NativeRescued(to, amount);
    }

    function rescueAllNative(address payable to) external onlyOwner {
        require(to != address(0), "TIGG: to zero");
        uint256 bal = address(this).balance;
        require(bal > 0, "TIGG: zero balance");
        to.transfer(bal);
        emit NativeRescued(to, bal);
    }

    // ----------------------
    // OpenZeppelin v5 transfer hook: block transfers during emergency
    // ----------------------
    function _update(address from, address to, uint256 amount) internal override {
        require(!emergencyStopped, "TIGG: emergency stopped");
        super._update(from, to, amount);
    }

    // ----------------------
    // Owner convenience role helpers
    // ----------------------
    function ownerGrantMinter(address account) external onlyOwner { _grantRole(MINTER_ROLE, account); }
    function ownerRevokeMinter(address account) external onlyOwner { revokeRole(MINTER_ROLE, account); }
    function ownerGrantBridge(address account) external onlyOwner { _grantRole(BRIDGE_ROLE, account); }
    function ownerRevokeBridge(address account) external onlyOwner { revokeRole(BRIDGE_ROLE, account); }
}
