**Assumptions**:
1. Inclusions of [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) (frame transaction), [EIP-8272](https://eips.ethereum.org/EIPS/eip-8272) (recent roots), [EIP-8250](https://eips.ethereum.org/EIPS/eip-8250) (keyed nonces).
2. EIP-8250 allows for multiple in-flight transactions from the same sender with different nonces.

**Concept**:

Have a Sender contract which holds ERC20s for users and allows users to pay for transactions from SENDER by deducting their held balance. The operation is split across two frames. The first checks that the user (a) had a sufficient balance to pay for the transaction at a recent root, and (b) that the recent root is really the most recent state for that user. The second deducts the fee from the user's balance.

Frames:

| Frame | Mode   | Caller      | Flags             | Target          | Data                                            |
| ----- | ------ | ----------- | ----------------- | --------------- | ----------------------------------------------- |
| 0     | VERIFY | ENTRY_POINT | ~                 | EXPIRY_VERIFIER | `expiry(EXCHANGE_TIMESTAMP + EXCHANGE_TIMEOUT)` |
| 1     | VERIFY | ENTRY_POINT | APPROVE_EXECUTION | Null (sender)   | `verify()`                                      |
| 2     | SENDER | Sender      | NONE              | Sender          | `deduct()`                                      |
| 3     | SENDER | Sender      | ...               | Sender          | `execute()`                                     |

Constants:
- USER_ID: A unique per-user value (ie user's address).
- FEE_TOKEN: The ERC20 token the user is paying their gas fee in.
- FEE: The gas fee expressed in FEE_TOKEN
- LATEST_NONCE: The latest recorded nonce for a given user.
- LATEST_BALANCE: The latest recorded balance for a given user.
- EXCHANGE_RATE: The exchange rate between a given token and ETH.
- EXCHANGE_TIMESTAMP: The timestamp at which a TOKEN_EXCHANGE was recorded.
- EXCHANGE_TIMEOUT: Arbitrary timeout after which exchange rates become invalid.
- EXCHANGE_BUFFER: A safety threshold on TOKEN_EXCHANGE to mitigate changing exchange rates do not affect the liquidity provider.
- USER_ROOT: Root for a merkle tree containing leaves with (USER_ID, LATEST_NONCE, LATEST_BALANCE).

Contract:
- Stores USER_ROOT. Publishes as a recent root.
- Stores EXCHANGE_RATE, EXCHANGE_TIMESTAMP. Publishes these values directly as recent roots.

Effects:

0. Verifies expiry for an arbitrary timestamp (timestamp is verified in frame 1)
1. Sender performs the following checks:
    - Loads USER_ID, LATEST_NONCE, LATEST_BALANCE via a merkle proof against the selected USER_ROOT, and EXCHANGE_RATE, EXCHANGE_TIMESTAMP directly. 
    - Require `nonce_keys[0]` == `USER_ID`
    - Require `nonce_seq[USER_ID]` == `LATEST_NONCE + 1`
    - Require `block.timestamp` < `EXCHANGE_TIMESTAMP + EXCHANGE_TIMEOUT`
    - Require `LATEST_BALANCE` > `gas_cost * max_fee_per_gas * EXCHANGE_RATE * EXCHANGE_BUFFER`
    - Require `frames[2]` == `deduct()`
    - Require `frames[0]` == `expiry(EXCHANGE_TIMESTAMP + EXCHANGE_TIMEOUT)`
2. Sender performs the following actions:
    - Computes the actual FEE value and deducts it from the user's balance.
    - USER_ID += 1
    - USER_BALANCE -= FEE
    - Inserts the updated values into the merkle tree, computes the new USER_ROOT, and publishes it to the recent roots.
3. 3+
    - Executes arbitrary user calls.

**Additional Requirements**:
- Requires permissionless maintinance of `USER_ROOT` so if it ever expires it is re-published.
- Regular permissionless updates to EXCHANGE_RATE and EXCHANGE_TIMESTAMP so that the exchange rate used by the smart contract does not fall out-of-sync.
- Economic modeling to ensure EXCHANGE_RATE never diverges too much from the true exchange rate (some economic risk will be undertaken by the liquidity provider).

**Validity**:
Given a valid transaction following this pattern, it can only be invalidated by:
1. A greater nonce_seq for the user's nonce_key being used (nonce becomes invalid).
2. The timestamp verified by frame 0 expiring.

Both of these are easily traceable by node code and do not require re-executing the entire frame to invalidate a transaction.

**FAQ**
- Why use a merkle tree?
    - Since recent roots expire after ~8k slots, we can't store each user's data in their own root.  Using a merkle tree means that someone needs to execute a tx every ~8k slots to maintain the state, much more likely.
- What prevents users from double-spending?
    - Users can only send a single tx with each nonce value. Since the contract increments `LATEST_NONCE` each operation, users must reference the latest balance update in any future calls.
- How can users deposit / withdraw?
    - Via the same mechanism as gas fees are spent.  The updated balance will be inserted into the merkle tree and the user's nonce will be incremented.
