//! Exercises the `SimpleAccount`/`OpcodeLib` custom spender rule
//! (`../contracts/`) against a live ethrex frame-tx-capable RPC node: sends
//! one frame transaction signed by the account's real owner (expect
//! approval) and one signed by an unrelated key (expect rejection).
//!
//! Env: RPC_URL, SIMPLE_ACCOUNT (deployed address, see
//! contracts/script/DeploySimpleAccount.s.sol), OWNER_PRIVATE_KEY (matching
//! the OWNER address passed to that script).

use std::time::Duration;

use anyhow::{Context, Result, bail};
use ethrex_common::types::{
    FRAME_SIG_SCHEME_ARBITRARY, FrameSignature, FrameTransaction, Transaction,
};
use ethrex_common::utils::keccak;
use ethrex_common::{Address, Bytes, H256, U256};
use ethrex_rpc::EthClient;
use ethrex_rpc::types::block_identifier::{BlockIdentifier, BlockTag};
use hegota_minimal_erc20_paymaster::{
    parse_secret_key, receipt, self_verify_frame, sender_frame, sign_recoverable,
};
use secp256k1::SecretKey;

/// `validate()` selector, from `contracts/src/SimpleAccount.sol`.
const VALIDATE_SELECTOR: [u8; 4] = [0x69, 0x01, 0xf6, 0x68];

/// Builds a [self-verify, sender] frame tx targeting `account`. The VERIFY
/// frame's calldata is just the bare `validate()` selector; the real
/// authentication material - an ecrecover-format signature (r || s || v(27/28))
/// over the tx's own sig_hash, signed by `signing_key` - travels as
/// `signatures[0]` (ARBITRARY scheme), which `SimpleAccount.validate` reads
/// back via SIGDATACOPY. It can't travel in the VERIFY frame's own calldata:
/// `compute_sig_hash` commits to every frame's data verbatim, so a signature
/// over sig_hash could never be embedded in the very calldata that is part of
/// that hash's preimage - only the outer `signatures` list's raw bytes are
/// elided from the hash (see `SimpleAccount.validate`'s doc comment).
async fn build_tx(
    client: &EthClient,
    account: Address,
    scratch_recipient: Address,
    signing_key: &SecretKey,
) -> Result<FrameTransaction> {
    let chain_id = client.get_chain_id().await?.as_u64();
    let nonce = client
        .get_nonce(account, BlockIdentifier::Tag(BlockTag::Latest))
        .await?;
    let max_priority_fee_per_gas = client.get_max_priority_fee().await?.as_u64();
    let max_fee_per_gas = client.get_gas_price().await?.as_u64() + max_priority_fee_per_gas;

    let mut verify_frame = self_verify_frame(account, 200_000);
    verify_frame.data = Bytes::from(VALIDATE_SELECTOR.to_vec());

    let mut tx = FrameTransaction {
        chain_id,
        nonce_keys: vec![U256::zero()],
        nonce_seq: nonce,
        sender: account,
        frames: vec![
            verify_frame,
            sender_frame(scratch_recipient, U256::one(), Bytes::new(), 100_000),
        ],
        // Placeholder - `signature`'s real bytes are elided from
        // compute_sig_hash whenever `msg` is empty, so filling it in below
        // (after hashing) doesn't change the hash the signature is over.
        signatures: vec![FrameSignature {
            scheme: FRAME_SIG_SCHEME_ARBITRARY,
            signer: None,
            msg: Bytes::new(),
            signature: Bytes::new(),
        }],
        max_priority_fee_per_gas,
        max_fee_per_gas,
        ..Default::default()
    };

    let (v, sig) = sign_recoverable(tx.compute_sig_hash(), signing_key);
    let mut signature = [0u8; 65];
    signature[..64].copy_from_slice(&sig);
    signature[64] = v + 27;
    tx.signatures[0].signature = Bytes::from(signature.to_vec());

    Ok(tx)
}

/// Sends a frame tx signed by `signing_key` and confirms the VERIFY frame
/// approved (`frame_receipts[0].status == 1`).
async fn run_case(
    client: &EthClient,
    account: Address,
    scratch_recipient: Address,
    signing_key: &SecretKey,
    max_polls: usize,
) -> Result<()> {
    let tx = build_tx(client, account, scratch_recipient, signing_key).await?;
    let raw = Transaction::FrameTransaction(tx).encode_canonical_to_vec();

    let hash: H256 = client
        .send_raw_transaction(&raw)
        .await
        .context("send_raw_transaction rejected the tx")?;
    println!("  sent: {hash:#x}");

    let receipt = receipt::wait_for_receipt(client, hash, max_polls, Duration::from_secs(1))
        .await
        .context("no receipt appeared (tx likely never included)")?;

    let approved = receipt
        .frame_receipts
        .as_ref()
        .and_then(|frames| frames.first())
        .is_some_and(|frame| frame.status == 1);

    if approved {
        println!("  frame 0 (VERIFY) approved");
        Ok(())
    } else {
        bail!("frame 0 (VERIFY) did not approve: {receipt:?}")
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let rpc_url = std::env::var("RPC_URL").context("RPC_URL required")?;
    let account: Address = std::env::var("SIMPLE_ACCOUNT")
        .context("SIMPLE_ACCOUNT required")?
        .parse()
        .context("invalid SIMPLE_ACCOUNT")?;
    let owner_key = parse_secret_key(
        &std::env::var("OWNER_PRIVATE_KEY").context("OWNER_PRIVATE_KEY required")?,
    )?;
    // Deterministic, unrelated key for the rejection case - no private key
    // controls this hash's preimage, so it can never match the real owner.
    let wrong_key = SecretKey::from_slice(&keccak(b"definitely-not-the-account-owner").0)
        .expect("keccak digest is a valid secp256k1 scalar");

    let client = EthClient::new(rpc_url.parse().context("invalid RPC_URL")?)
        .context("failed to connect to provider")?;
    let scratch_recipient = Address::from(keccak(b"spender-rules-scratch-recipient"));

    println!("== case 1: correct owner signature (expect approval) ==");
    run_case(&client, account, scratch_recipient, &owner_key, 60).await?;

    println!("== case 2: wrong signature (expect rejection) ==");
    match run_case(&client, account, scratch_recipient, &wrong_key, 15).await {
        Ok(()) => bail!("wrong signature was unexpectedly approved"),
        Err(e) => println!("  rejected as expected ({e})"),
    }

    println!("both cases behaved as expected");
    Ok(())
}
