use std::{env, time::Duration};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = wreq::Client::builder()
        .tls_info(true)
        .timeout(Duration::from_secs(25))
        .connect_timeout(Duration::from_secs(10))
        .build()?;

    for target in env::args().skip(1) {
        match client.get(&target).send().await {
            Ok(response) => {
                let tls = response.extensions().get::<wreq::tls::TlsInfo>();
                println!("target={target}");
                println!(
                    "status={} version={:?} uri={} remote={:?}",
                    response.status(),
                    response.version(),
                    response.uri(),
                    response.remote_addr()
                );
                if let Some(info) = tls {
                    println!(
                        "tls={} cipher={:?} group={:?} alpn={:?} resumed={}",
                        info.protocol_version(),
                        info.cipher_suite(),
                        info.negotiated_group(),
                        info.alpn_protocol().map(String::from_utf8_lossy),
                        info.session_reused(),
                    );
                }
                if let Some(info) = response.extensions().get::<wreq::http2::Http2Info>() {
                    let settings = info
                        .peer_initial_settings()
                        .iter()
                        .map(|setting| format!("{}={}", setting.id(), setting.value()))
                        .collect::<Vec<_>>()
                        .join(",");
                    println!("h2-peer-settings={settings}");
                }
                for name in [
                    "server",
                    "cf-ray",
                    "x-datadome-cid",
                    "x-cache",
                    "x-served-by",
                    "x-amzn-waf-action",
                    "via",
                ] {
                    if let Some(value) = response.headers().get(name) {
                        println!("{name}: {}", value.to_str().unwrap_or("<binary>"));
                    }
                }
            }
            Err(error) => {
                println!("target={target}\nerror={error}");
            }
        }
        println!();
        tokio::time::sleep(Duration::from_millis(750)).await;
    }
    Ok(())
}
