use std::time::Duration;

use anyhow::{Context, Result, bail};
use ethrex_common::H256;
use ethrex_rpc::EthClient;
use ethrex_rpc::types::receipt::RpcReceipt;

pub async fn wait_for_receipt(
    client: &EthClient,
    hash: H256,
    max_polls: usize,
    poll_interval: Duration,
) -> Result<RpcReceipt> {
    for _ in 0..max_polls {
        let receipt = client
            .get_transaction_receipt(hash)
            .await
            .context("eth_getTransactionReceipt failed")?;

        if let Some(receipt) = receipt {
            return Ok(receipt);
        }

        tokio::time::sleep(poll_interval).await;
    }

    bail!("timed out waiting for receipt of {hash:#x}")
}
