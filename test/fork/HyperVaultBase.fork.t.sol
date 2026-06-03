// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {SystemAddress} from "../../src/libraries/SystemAddress.sol";

/*//////////////////////////////////////////////////////////////////////////
            HYPERVAULT — FORKED-MAINNET PROOF HARNESS (base)
//////////////////////////////////////////////////////////////////////////

  Purpose: prove the redemption/liveness findings from docs/REDEMPTION_ASSESSMENT.md
  on REAL HyperEVM-mainnet bytecode — NOT a mock. The asset is the real USDC ERC20
  at 0xb883…630f; LP funding uses `deal` (a cheatcode that writes the real token's
  balance slot — not a mock contract). A fresh HyperCoreVault is deployed on the
  fork via the same `new HyperCoreVault(cfg)` path as script/Deploy.s.sol.

  WHAT A FORGE FORK FAITHFULLY REPRODUCES (and these tests rely on):
    - the real USDC ERC20 (fetchable bytecode + storage); `deal` + transfers are real;
    - all pure-EVM contract logic: ERC4626 share math, AccessControl, Pausable,
      ReentrancyGuard, the bespoke withdrawal queue, and `pushToCore` (which is just
      a real ERC20 transfer to the bridge system address 0x2000…0000).

  WHAT A FORGE FORK CANNOT REPRODUCE (so no test here asserts it):
    - HyperCore L1 read precompiles 0x0800–0x0810: Foundry's revm does not implement
      chain-specific precompiles, so a CALL to e.g. 0x801 returns empty — exactly as
      it would for an uninitialised Core account. The lenient PrecompileLib wrappers
      therefore read 0 (so totalAssets()==idleUsdc() here), and the strict wrappers
      revert. This is *useful* for proving the vault's fail-open/closed wrapper logic
      (Finding H) but means the EVM↔Core USDC-linkage question (Finding G) CANNOT be
      read on a fork — it is resolved with a live read-only eth_call against the real
      node (scripts/python/resolve_usdc_linkage.py), and the actual bridge round-trip
      is proven by the live spike (scripts/python/e2e_runner.py step_pull).
    - CoreWriter processing: actions are fire-and-forget. None of these tests need it
      (the movers we exercise revert at their pause/role modifiers *before* CoreWriter).

  Run:
    HYPEREVM_RPC_MAINNET=<rpc> forge test --match-path 'test/fork/HyperVault*.fork.t.sol' -vvv
  (falls back to the public node if the env var is unset; set HYPEREVM_FORK_BLOCK to pin.)
*///////////////////////////////////////////////////////////////////////////

abstract contract HyperVaultBaseForkTest is Test {
    /// @dev The real HyperEVM-mainnet USDC — the configured asset in mainnet-tier1.json.
    address internal constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    uint256 internal constant HYPEREVM_CHAIN_ID = 999;
    /// @dev The USDC Core bridge / system address = SystemAddress.usdc() = forToken(0).
    address internal constant USDC_BRIDGE = 0x2000000000000000000000000000000000000000;

    HyperCoreVault internal vault;

    // Actors. `admin` is set to address(this) on the deployed vault so the test can
    // drive DEFAULT_ADMIN_ROLE setters directly (the production admin is a timelock;
    // the governance test exercises the real timelock topology separately).
    address internal operator     = makeAddr("operator");
    address internal emergency    = makeAddr("emergency");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper       = makeAddr("keeper");
    address internal alice        = makeAddr("alice");
    address internal bob          = makeAddr("bob");
    address internal carol        = makeAddr("carol");
    address internal attacker     = makeAddr("attacker");
    address internal idleSink     = makeAddr("idleSink");

    bool internal forked;

    // Event mirrors for vm.expectEmit (matched by signature + data).
    event WithdrawalRequested(address indexed lp, uint256 shares);
    event WithdrawalFulfilled(address indexed lp, uint256 assets);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event PerfFeePaid(address indexed lp, uint256 feeAssets);
    event BridgeDeposit(uint64 amount);

    function setUp() public virtual {
        string memory rpc = vm.envOr("HYPEREVM_RPC_MAINNET", string("https://rpc.hyperliquid.xyz/evm"));
        uint256 forkBlock = vm.envOr("HYPEREVM_FORK_BLOCK", uint256(0));
        try this.createFork(rpc, forkBlock) {
            forked = true;
        } catch {
            forked = false;
            return;
        }

        require(block.chainid == HYPEREVM_CHAIN_ID, "not HyperEVM mainnet (chainid != 999)");
        require(USDC.code.length > 0, "no code at USDC (wrong chain / RPC?)");
        // Sanity: the literal bridge constant must equal the library derivation.
        require(USDC_BRIDGE == SystemAddress.usdc(), "bridge address mismatch");

        // Default vault: no fees (isolates accounting); tests needing fees redeploy.
        vault = _deployVault(0, 0);

        console2.log("forked HyperEVM mainnet @ block", block.number);
        console2.log("vault:", address(vault));
    }

    /// @dev external wrapper so fork creation can be `try`-caught (LighterCustody pattern).
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

    /// @dev Deploy a fresh vault mirroring mainnet-tier1.json but with admin == address(this)
    ///      (so tests can call admin setters without timelock choreography) and the supplied
    ///      fee bps. Leverage cap / slippage band are 0 (irrelevant — no trading here).
    function _deployVault(uint16 mgmtBps, uint16 perfBps) internal returns (HyperCoreVault v) {
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(USDC),
            coreUsdcIndex: 0,
            coreUsdcDecimals: 8,
            name: "Fork Proof Vault",
            symbol: "fpv",
            admin: address(this),
            operator: operator,
            emergencyAdmin: emergency,
            feeRecipient: feeRecipient,
            leverageCapBps: 0,
            slippageBandBps: 0,
            mgmtFeeAnnualBps: mgmtBps,
            perfFeeBps: perfBps,
            depositCap: type(uint256).max,
            maxDepositPerAddress: 0
        });
        v = new HyperCoreVault(cfg);
    }

    /// @dev Fund `who` with real USDC (absolute balance == assets) and deposit it all.
    ///      If `deal` ever fails on this token, swap to whale-impersonation + transfer.
    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        deal(USDC, who, assets);
        vm.startPrank(who);
        IERC20(USDC).approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev Simulate a realised gain arriving as idle USDC (PPS up). Call only AFTER the
    ///      first real deposit, else OZ virtual-shares math strands it (donation trap).
    function _fundIdle(uint256 assets) internal {
        deal(USDC, address(vault), IERC20(USDC).balanceOf(address(vault)) + assets);
    }

    /// @dev Simulate idle USDC leaving the vault as deployed capital (off the EVM side),
    ///      manufacturing the "value not in idle, shares still outstanding" precondition
    ///      with a REAL ERC20 transfer from the vault to a non-blacklisted sink.
    ///
    ///      We deliberately do NOT use pushToCore here: the configured USDC blacklists the
    ///      Core bridge address 0x2000..0000, so pushToCore reverts (proven directly in
    ///      HyperVaultLivenessForkTest.test_G_pushToCoreRevertsOnBlacklistedBridge). The
    ///      behaviour under test — fulfill/redeem read only idleUsdc() — is independent of
    ///      HOW idle leaves the vault, so a direct transfer is a faithful stand-in.
    function _drainIdle(uint256 amount) internal {
        vm.prank(address(vault));
        IERC20(USDC).transfer(idleSink, amount);
    }

    function _idle() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(address(vault));
    }
}
