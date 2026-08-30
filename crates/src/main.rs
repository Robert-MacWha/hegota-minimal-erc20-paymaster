use std::time::Duration;

use anyhow::Context;
use clap::Parser;
use ethrex_common::types::{
    FRAME_SIG_SCHEME_SECP256K1, FrameSignature, FrameTransaction, Transaction,
};
use ethrex_common::{Address, Bytes, H256, U256};
use ethrex_rpc::EthClient;
use ethrex_rpc::types::block_identifier::{BlockIdentifier, BlockTag};
use hegota_minimal_erc20_paymaster::{
    address_from_secret_key, parse_secret_key, receipt, self_verify_frame, sender_frame, sign,
};

#[derive(Parser)]
struct Args {
    /// Recipient address
    to: Address,
    /// Amount to send, in wei
    #[arg(value_parser = parse_wei, default_value = "1000000000000000")]
    amount_wei: U256,
}

fn parse_wei(s: &str) -> Result<U256, String> {
    U256::from_dec_str(s).map_err(|e| e.to_string())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let rpc_url = std::env::var("RPC_URL").context("RPC_URL required")?;
    let private_key = std::env::var("PRIVATE_KEY").context("PRIVATE_KEY required")?;
    let secret_key = parse_secret_key(&private_key)?;
    let sender = address_from_secret_key(&secret_key);

    let client = EthClient::new(rpc_url.parse().context("invalid RPC_URL")?)
        .context("Failed to connect to provider")?;

    let chain_id = client.get_chain_id().await?.as_u64();
    let nonce = client
        .get_nonce(sender, BlockIdentifier::Tag(BlockTag::Latest))
        .await?;
    let max_priority_fee_per_gas = client.get_max_priority_fee().await?.as_u64();
    let max_fee_per_gas = client.get_gas_price().await?.as_u64() + max_priority_fee_per_gas;

    let mut tx = FrameTransaction {
        chain_id,
        nonce_keys: vec![U256::zero()],
        nonce_seq: nonce,
        sender,
        frames: vec![
            self_verify_frame(sender, 150_000),
            sender_frame(args.to, args.amount_wei, Bytes::new(), 300_000),
        ],
        signatures: vec![FrameSignature {
            scheme: FRAME_SIG_SCHEME_SECP256K1,
            signer: Some(sender),
            msg: Bytes::new(),
            signature: Bytes::new(),
        }],
        max_priority_fee_per_gas,
        max_fee_per_gas,
        ..Default::default()
    };

    sign(&mut tx, 0, &secret_key)?;
    let raw = Transaction::FrameTransaction(tx).encode_canonical_to_vec();

    let hash: H256 = client
        .send_raw_transaction(&raw)
        .await
        .context("failed to send frame transaction")?;
    println!("sent: {hash:#x}");
    println!("waiting for receipt...");

    let receipt = receipt::wait_for_receipt(&client, hash, 60, Duration::from_secs(1)).await?;
    dbg!(&receipt);

    Ok(())
}
