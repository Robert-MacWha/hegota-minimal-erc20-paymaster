pub mod receipt;

use anyhow::{Context, Result};
use ethrex_common::types::{APPROVE_EXECUTION_AND_PAYMENT, Frame, FrameMode, FrameTransaction};
use ethrex_common::utils::keccak;
use ethrex_common::{Address, Bytes, H256, U256};
use secp256k1::{Message, SECP256K1, SecretKey};

/// Parses a `0x`-prefixed or bare hex private key into a `SecretKey`.
pub fn parse_secret_key(hex: &str) -> Result<SecretKey> {
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    SecretKey::from_slice(&hex::decode(hex).context("invalid private key")?)
        .context("invalid private key")
}

/// Derives the Ethereum address controlled by `secret_key`.
pub fn address_from_secret_key(secret_key: &SecretKey) -> Address {
    Address::from(keccak(
        &secret_key.public_key(SECP256K1).serialize_uncompressed()[1..],
    ))
}

pub fn self_verify_frame(sender: Address, gas_limit: u64) -> Frame {
    Frame {
        mode: FrameMode::Verify as u8,
        flags: APPROVE_EXECUTION_AND_PAYMENT,
        target: Some(sender),
        gas_limit,
        value: U256::zero(),
        data: Bytes::new(),
    }
}

pub fn sender_frame(target: Address, value: U256, data: Bytes, gas_limit: u64) -> Frame {
    Frame {
        mode: FrameMode::Sender as u8,
        flags: 0,
        target: Some(target),
        gas_limit,
        value,
        data,
    }
}

/// Signs `hash` with `signer`, returning the raw recovery id (0/1) and the
/// 64-byte `r || s` compact signature.
pub fn sign_recoverable(hash: H256, signer: &SecretKey) -> (u8, [u8; 64]) {
    let msg = Message::from_digest(hash.0);
    let (recovery_id, sig) = SECP256K1
        .sign_ecdsa_recoverable(&msg, signer)
        .serialize_compact();
    (Into::<i32>::into(recovery_id) as u8, sig)
}

/// Signs `tx`'s signature hash and fills in `signatures[sig_index]` with a
/// `v || r || s` SECP256K1 signature, as required by frame-transaction
/// verification (see `validate_frame_signatures` in ethrex's EVM crate).
pub fn sign(tx: &mut FrameTransaction, sig_index: usize, signer: &SecretKey) {
    let (v, sig) = sign_recoverable(tx.compute_sig_hash(), signer);
    let mut raw = Vec::with_capacity(65);
    raw.push(v);
    raw.extend_from_slice(&sig);
    tx.signatures[sig_index].signature = Bytes::from(raw);
}
