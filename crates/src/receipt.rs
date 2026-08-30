use std::time::Duration;

use anyhow::{Context, Result, bail};
use ethrex_common::H256;
use ethrex_rpc::EthClient;
use ethrex_rpc::utils::RpcRequest;
use serde::Deserialize;
use serde_json::json;

/// Minimal, version-tolerant frame-transaction receipt: `ethrex_rpc`'s own
/// `RpcReceipt`/`RpcFrameReceipt` require fields (e.g. `stateGasUsed`) added
/// by a later wire-format revision than what the live devnet this project
/// targets actually returns, so this only declares what's actually used
/// here rather than depending on that stricter, newer shape.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    #[serde(default)]
    pub frame_receipts: Option<Vec<FrameReceipt>>,
}

#[derive(Debug, Deserialize)]
pub struct FrameReceipt {
    #[serde(deserialize_with = "hex_u8")]
    pub status: u8,
}

fn hex_u8<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u8, D::Error> {
    let s = String::deserialize(deserializer)?;
    let s = s.strip_prefix("0x").unwrap_or(&s);
    u8::from_str_radix(s, 16).map_err(serde::de::Error::custom)
}

pub async fn wait_for_receipt(
    client: &EthClient,
    hash: H256,
    max_polls: usize,
    poll_interval: Duration,
) -> Result<Receipt> {
    for _ in 0..max_polls {
        let request = RpcRequest::new(
            "eth_getTransactionReceipt",
            Some(vec![json!(format!("{hash:#x}"))]),
        );
        let receipt: Option<Receipt> = client
            .send_request_parsed(request)
            .await
            .context("eth_getTransactionReceipt failed")?;

        if let Some(receipt) = receipt {
            return Ok(receipt);
        }

        tokio::time::sleep(poll_interval).await;
    }

    bail!("timed out waiting for receipt of {hash:#x}")
}
