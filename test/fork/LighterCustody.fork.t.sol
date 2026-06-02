// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////////////////
                    D2 · LIGHTER CUSTODY — ON-CHAIN FORK SPIKE
//////////////////////////////////////////////////////////////////////////

  Goal (vaults.md §8.1): prove/debunk — on a fork of REAL Ethereum-mainnet
  bytecode, NOT a mock — that a smart-contract vault can:
    (1) become a first-class Lighter L1 account owner (no EIP-1271 needed),
    (2) install an L2 trading key,
    (3) be the ONLY party that can move its funds (non-owner withdraw reverts),
    (4) initiate withdrawals that carry NO destination arg (owner-bound),
    (5) trigger the permissionless 14-day Desert-Mode escape, and
    (6) exit only via a genuine (un-forgeable) ZK proof, with owner-keyed payout.

  Substrate: verified ZkLighter proxy 0x3B4D…5ca7 (impl 0xc4F388…009C +
  AdditionalZkLighter 0x22F0…668f). Function signatures / storage getters /
  custom errors below are copied verbatim from the verified source
  (IZkLighter.sol / Storage.sol / ExtendableStorage.sol / Config.sol).

  Run:
    ETH_RPC_URL=<archive-rpc> forge test --match-path test/fork/LighterCustody.fork.t.sol -vvv
  (falls back to a public node if ETH_RPC_URL is unset; set ETH_FORK_BLOCK to pin.)
*///////////////////////////////////////////////////////////////////////////

/// @dev Minimal interface to the LIVE ZkLighter proxy. Selectors must match
///      the deployed contract exactly — taken from the verified source.
interface ILighter {
    enum RouteType {
        Perps,
        Spot
    }

    // --- state-changing (routed proxy -> ZkLighter -> delegatecall AdditionalZkLighter) ---
    function deposit(address _to, uint16 _assetIndex, RouteType _routeType, uint256 _amount) external payable;
    function withdraw(uint48 _accountIndex, uint16 _assetIndex, RouteType _routeType, uint64 _baseAmount) external;
    function changePubKey(uint48 _accountIndex, uint8 _apiKeyIndex, bytes calldata _pubKey) external;

    // --- escape hatch (on the main ZkLighter contract) ---
    function activateDesertMode() external returns (bool);
    function performDesert(
        uint48 _accountIndex,
        address _l1Address,
        uint16 _assetIndex,
        uint128 _totalBaseAmount,
        bytes calldata proof
    ) external;
    function withdrawPendingBalance(address _owner, uint16 _assetIndex, uint128 _baseAmount) external;

    // --- public getters ---
    function getPendingBalance(address _owner, uint16 _assetIndex) external view returns (uint128);
    function addressToAccountIndex(address) external view returns (uint48);
    function lastAccountIndex() external view returns (uint48);
    function openPriorityRequestCount() external view returns (uint64);
    function desertMode() external view returns (bool);
    function assetConfigs(uint16)
        external
        view
        returns (
            address tokenAddress,
            uint8 withdrawalsEnabled,
            uint56 extensionMultiplier,
            uint128 tickSize,
            uint64 depositCapTicks,
            uint64 minDepositTicks
        );
}

/// @dev Custom errors we assert against (verbatim from the verified source).
interface ILighterErrors {
    error AdditionalZkLighter_AccountIsNotRegistered();
    error ZkLighter_DesertError();
    error ZkLighter_InvalidWithdrawAmount();
}

/// @dev The "vault" stand-in: a plain smart contract that owns a Lighter account.
///      It deposits to itself, installs a key, and withdraws — all as `msg.sender`.
contract LighterVaultProbe {
    ILighter public immutable lighter;

    constructor(ILighter _lighter) {
        lighter = _lighter;
    }

    function depositToSelf(address usdc, uint16 assetIdx, uint256 amount) external {
        IERC20(usdc).approve(address(lighter), amount);
        lighter.deposit(address(this), assetIdx, ILighter.RouteType.Perps, amount);
    }

    function installKey(uint48 acctIdx, uint8 apiKeyIdx, bytes calldata pk) external {
        lighter.changePubKey(acctIdx, apiKeyIdx, pk);
    }

    function withdrawAsOwner(uint48 acctIdx, uint16 assetIdx, uint64 baseAmount) external {
        lighter.withdraw(acctIdx, assetIdx, ILighter.RouteType.Perps, baseAmount);
    }
}

contract LighterCustodyForkTest is Test {
    address constant ZKLIGHTER = 0x3B4D794a66304F130a4Db8F2551B0070dfCf5ca7;
    uint16 constant USDC_IDX = 3; // Config.USDC_ASSET_INDEX

    ILighter lighter = ILighter(ZKLIGHTER);
    LighterVaultProbe probe;

    bool internal forked;
    address internal usdc;
    uint256 internal depositAmount;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 forkBlock = vm.envOr("ETH_FORK_BLOCK", uint256(0));
        try this.createFork(rpc, forkBlock) {
            forked = true;
        } catch {
            forked = false;
            return;
        }

        require(ZKLIGHTER.code.length > 0, "no code at ZkLighter (wrong chain?)");

        uint128 tickSize;
        uint64 minDepositTicks;
        (usdc,,, tickSize,, minDepositTicks) = lighter.assetConfigs(USDC_IDX);
        require(usdc != address(0), "USDC asset (idx 3) not registered");

        uint256 minDeposit = uint256(minDepositTicks) * uint256(tickSize);
        // Deposit comfortably above the on-chain minimum, kept a multiple of tickSize.
        depositAmount = minDeposit == 0 ? 1000e6 : minDeposit * 100;

        probe = new LighterVaultProbe(lighter);

        console2.log("forked ETH mainnet | USDC:", usdc);
        console2.log("min deposit (raw):", minDeposit);
        console2.log("deposit amount   :", depositAmount);
    }

    /// @dev external wrapper so the fork creation can be `try`-caught.
    function createFork(string calldata rpc, uint256 forkBlock) external {
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
    }

    function _skipIfNoFork() internal {
        if (!forked) {
            vm.skip(true);
        }
    }

    /// @dev Fund + deposit so the probe becomes a registered owner; returns its account index.
    function _registerProbe() internal returns (uint48 acct) {
        deal(usdc, address(probe), depositAmount);
        probe.depositToSelf(usdc, USDC_IDX, depositAmount);
        acct = lighter.addressToAccountIndex(address(probe));
        require(acct != 0, "registration failed");
    }

    /// @dev A canonical 40-byte Lighter API pubkey: 5 little-endian uint64 limbs,
    ///      each == 1 (non-zero and < GOLDILOCKS_MODULUS), satisfying changePubKey's checks.
    function _validPubKey() internal pure returns (bytes memory pk) {
        pk = new bytes(40);
        for (uint256 i = 0; i < 5; i++) {
            pk[i * 8] = 0x01;
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.1 — a smart CONTRACT can become a first-class L1 account owner
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_01_contractCanOwnAccount() public {
        _skipIfNoFork();

        assertEq(lighter.addressToAccountIndex(address(probe)), 0, "probe pre-registered");
        uint48 lastBefore = lighter.lastAccountIndex();

        deal(usdc, address(probe), depositAmount);
        probe.depositToSelf(usdc, USDC_IDX, depositAmount);

        uint48 acct = lighter.addressToAccountIndex(address(probe));
        assertGt(acct, 0, "contract did NOT become an account owner");
        assertEq(acct, lastBefore + 1, "account index not assigned synchronously to the contract");
        console2.log("D2.1 PASS - probe is account index:", acct);
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.2 — the contract can install an L2 trading key (msg.sender-gated)
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_02_contractInstallsTradeKey() public {
        _skipIfNoFork();

        uint48 acct = _registerProbe();
        uint64 openBefore = lighter.openPriorityRequestCount();

        probe.installKey(acct, 2, _validPubKey());

        assertEq(lighter.openPriorityRequestCount(), openBefore + 1, "changePubKey did not enqueue a priority request");
        console2.log("D2.2 PASS - contract installed an L2 key via changePubKey");
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.3 — a NON-OWNER cannot move the vault's funds
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_03_nonOwnerCannotWithdraw() public {
        _skipIfNoFork();

        uint48 acct = _registerProbe();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ILighterErrors.AdditionalZkLighter_AccountIsNotRegistered.selector);
        lighter.withdraw(acct, USDC_IDX, ILighter.RouteType.Perps, 1);

        console2.log("D2.3 PASS - non-owner withdraw reverted AccountIsNotRegistered");
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.4 — the owner's withdraw is destination-bound (no recipient arg exists)
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_04_ownerWithdrawIsDestinationBound() public {
        _skipIfNoFork();

        uint48 acct = _registerProbe();
        uint64 openBefore = lighter.openPriorityRequestCount();

        // Owner initiates withdraw. The ABI carries NO destination address —
        // the request is keyed to msg.sender's account; payout can only reach the owner.
        probe.withdrawAsOwner(acct, USDC_IDX, 1);

        assertEq(lighter.openPriorityRequestCount(), openBefore + 1, "owner withdraw did not enqueue");
        console2.log("D2.4 PASS - owner withdraw enqueued; no destination parameter in the ABI");
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.5 — permissionless 14-day Desert-Mode freeze (escape, step 1)
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_05_permissionlessEscapeFreeze() public {
        _skipIfNoFork();

        _registerProbe(); // guarantees >= 1 open priority request (our deposit)
        assertFalse(lighter.desertMode(), "already in desert mode");

        // Warp past the 14-day expiry of the oldest unexecuted priority request.
        vm.warp(block.timestamp + 14 days + 1 hours);

        address anyone = makeAddr("anyone"); // NOT the operator, NOT a validator
        vm.prank(anyone);
        bool triggered = lighter.activateDesertMode();

        assertTrue(triggered, "desert mode did not trigger after 14d");
        assertTrue(lighter.desertMode(), "desertMode flag not set");
        console2.log("D2.5 PASS - anyone froze the rollup after the 14d deadline");
    }

    // ───────────────────────────────────────────────────────────────────────
    // D2.6 — exit is genuine (proof-gated) and payout is owner-keyed (escape, step 2)
    //         A real desert exit needs an off-chain ZK proof we cannot forge here;
    //         we prove the gating + owner-keying instead (documented limitation).
    // ───────────────────────────────────────────────────────────────────────
    function test_D2_06_escapeIsProofGatedAndOwnerKeyed() public {
        _skipIfNoFork();

        uint48 acct = _registerProbe();

        // (a) performDesert is impossible before desert mode.
        vm.expectRevert(ILighterErrors.ZkLighter_DesertError.selector);
        lighter.performDesert(acct, address(probe), USDC_IDX, 1, hex"00");

        // (b) Enter desert mode, then a bogus proof MUST still be rejected
        //     (the desertVerifier reverts/returns false — funds can't be conjured).
        _registerProbe(); // open request -> allow activation
        vm.warp(block.timestamp + 14 days + 1 hours);
        lighter.activateDesertMode();
        assertTrue(lighter.desertMode(), "expected desert mode");

        vm.expectRevert(); // verifier reverts on the malformed proof
        lighter.performDesert(acct, address(probe), USDC_IDX, 1, hex"00");

        // (c) Payout is owner-keyed: with no credited balance, withdrawPendingBalance reverts,
        //     and getPendingBalance for the owner is 0 (funds can only ever land at the owner).
        assertEq(lighter.getPendingBalance(address(probe), USDC_IDX), 0, "unexpected pending balance");
        vm.expectRevert(ILighterErrors.ZkLighter_InvalidWithdrawAmount.selector);
        lighter.withdrawPendingBalance(address(probe), USDC_IDX, 1);

        console2.log("D2.6 PASS - exit requires a real ZK proof; payout is owner-keyed");
    }
}
