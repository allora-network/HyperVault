# HyperCoreVault: Executive Overview

A self-custodial trading vault on Hyperliquid. June 2026. Contract version 1.4, after audit remediation, before launch.

## 1. Executive summary

HyperCoreVault is our investment vault on Hyperliquid, the leading on-chain derivatives exchange. Customers deposit USDC, a digital dollar, and receive shares in return. We trade that capital on the exchange, and each share's value rises and falls with the results. Nobody has to take our word for the numbers: the vault's books are computed on the blockchain, directly from the exchange's own ledger, every time anyone deposits or withdraws.

Control is deliberately narrow. The trading key can trade and nothing else; it can't send customer money to itself or to any destination that wasn't pre-approved in public. Every rule change waits at least 24 hours before it takes effect. Withdrawals are never switched off, even in an emergency.

An independent security review produced 11 findings. All are fixed, and every fix is proven by automated tests run against the live network's actual code. One integration task remains before launch: switching the vault onto Circle's official dollar bridge between the vault and the exchange (see section 7).

## 2. What the vault does

Think of the vault as a fund wrapper. You put in dollars, you get units, and the unit price tracks the strategy's performance. The shares follow a widely used vault standard, so wallets, custodians, and portfolio tools already know how to read them.

Deposits are open to anyone, within two caps we control: a ceiling on the vault's total size and a ceiling per wallet. Both are deliberate ramp controls for the launch period. Withdrawals work at any time: instantly from the vault's cash buffer, or through a short queue when a request is larger than the buffer (see section 5).

## 3. How the money is counted

No one at Allora reports the vault's value. The contract reads Hyperliquid's own ledger directly and adds up three things: cash sitting in the vault, cash sitting on the exchange, and the exchange's own conservative figure for the trading account.

"Conservative" is deliberate. The vault counts what could be turned back into cash right now. Collateral committed to open positions isn't counted until those positions close or shrink. The benefit is that the share price can't be inflated or gamed; the trade-off is that it modestly understates the vault's value while trades are open, then catches back up as positions close. We treat that as a feature: when in doubt, the books read low, never high.

## 4. Fees

The performance fee is personal. Each depositor is measured against their own entry price, and the fee applies only to their own gain, taken when they withdraw. If you exit at or below the price you came in at, you pay nothing. Riding the fund up and back down to your entry also costs nothing. And one customer's loss can never hide another customer's gain; the audit specifically closed that loophole.

Fees are paid in dollars to a fee address fixed at deployment, and the fee rate has a hard 50 percent ceiling written into the code. The contract also supports an optional time-based management fee. To keep the promise "you never pay a fee while you're down" exact, we recommend running this strategy with the management fee set to zero.

## 5. Deposits and withdrawals

Withdrawals are paid instantly out of the vault's cash buffer. A request bigger than the buffer joins a queue while capital is brought back from the exchange. The queue is honest by construction: an on-chain timer makes overdue requests visible to everyone, and an overdue request gets first claim on cash as it arrives, ahead of anyone trying to jump the line.

Two operating notes, stated plainly. First, bringing capital back from the exchange is triggered manually by our team today; the funds move contract-to-contract with no one holding them in between, but automating the trigger is still on the build plan. Second, a depositor with an open withdrawal request has to cancel it before adding new money. That's an anti-gaming rule that came out of the audit, not a bug.

## 6. Controls and safety

Three separate keys hold three separate jobs, and the deployment tooling refuses any setup that merges them.

The trading key can only trade: only in markets we've pre-approved, only within price bands around the exchange's own quotes, and only under an overall leverage ceiling. It cannot pay itself. The emergency key can pause the vault and unwind positions, but it can't move funds to itself either. The administrator seat is held by a timelock, so every rule change (new markets, fee levels, caps) sits in public view for at least 24 hours before it can execute.

Pausing stops new deposits and new trading. It never stops withdrawals, and the paths that return money from the exchange keep working while paused. The security review went beyond desk checks: the weaknesses were first demonstrated with real funds on a disposable test vault, then fixed, and each fix is proven by tests against the live network's code. A final live re-verification of the fixes is scheduled before launch.

## 7. Fit for the planned strategy

The planned strategy runs on this contract as built. Every 8 hours we'll take fresh predictions, turn them into target portfolio weights, and adjust positions in BTC, ETH, and SOL accordingly, long or short, using perpetual futures on the exchange. The contract supports all of it today: several markets at once under one leverage ceiling, no limits on rebalancing frequency, and a performance fee that already matches the rule we want, where each customer pays only on their own gain.

What remains is configuration and operations, not contract code: approve the ETH and SOL markets through the 24-hour process (BTC is already approved), raise the deposit caps from their current test values, set the management fee to zero, deploy a fresh vault on the current contract version, and build the small service that trades every 8 hours and keeps the withdrawal buffer topped up. Holding the three assets through futures rather than buying coins outright is the standard professional approach, and it's the one the vault's accounting is built for.

One integration task needs to land before launch: the dollar route. When we audited, the standard token bridge rejected our USDC and we planned an operations workaround through a company treasury. Deeper research closed that gap: since December 2025, Circle operates an official bridge contract for exactly this purpose. It's live, it holds roughly 4.9 billion dollars as the exchange's published USDC reserve, and it lets a contract move dollars to the exchange (even straight into the trading account) and receive them back, no human in the loop. The vault needs a small code change to call it, and we'll confirm the round trip with a few dollars of real money before launch. The treasury route stays documented as a contingency only. One honest caveat: the bridge contract is operated and upgradeable by Circle, which is the same issuer trust we already accept by holding USDC at all.

## 8. Status and path to launch

The contract work is in good shape; the remaining lift is one small integration plus operations. In order: wire the vault to Circle's official dollar bridge (a small, testable code change), prove the round trip with a few dollars on the live network, deploy a fresh vault, approve markets, production caps, and fees through the timelock, make the seed deposit, switch the accounting to its strict fail-safe mode after the first exchange transaction, set the withdrawal timer, hand the administrator seat to the production multisig, run the scheduled live re-verification, and open deposits.
