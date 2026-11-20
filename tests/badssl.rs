#[path = "support/tls_cert.rs"]
mod tls_cert;
#[path = "support/tls_server.rs"]
mod tls_server;

use wreq::{
    Client,
    tls::{TlsInfo, trust::CertStore},
};

#[tokio::test]
async fn test_modern_tls_with_local_certificate() {
    let (cert, key) = tls_cert::self_signed("localhost", Some("127.0.0.1".parse().unwrap()));
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);
    let store = CertStore::builder()
        .add_der_cert(&cert.to_der().unwrap())
        .build()
        .unwrap();

    let response = Client::builder()
        .tls_cert_store(store)
        .no_proxy()
        .build()
        .unwrap()
        .get(&url)
        .send()
        .await
        .unwrap();

    assert!(response.status().is_success());
}

#[tokio::test]
async fn test_self_signed_certificate_verification_override() {
    let (cert, key) = tls_cert::self_signed("localhost", Some("127.0.0.1".parse().unwrap()));
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);

    let response = Client::builder()
        .tls_cert_verification(false)
        .no_proxy()
        .build()
        .unwrap()
        .get(&url)
        .send()
        .await
        .unwrap();

    assert!(response.status().is_success());
}

#[tokio::test]
async fn test_tls_hostname_verification_override() {
    let (cert, key) = tls_cert::self_signed("expected.example", None);
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);
    let der = cert.to_der().unwrap();

    let client = |verify_hostname| {
        Client::builder()
            .tls_cert_store(CertStore::builder().add_der_cert(&der).build().unwrap())
            .tls_verify_hostname(verify_hostname)
            .no_proxy()
            .build()
            .unwrap()
    };

    // The certificate is trusted, but only names expected.example, not 127.0.0.1.
    assert!(
        client(false)
            .get(&url)
            .send()
            .await
            .unwrap()
            .status()
            .is_success()
    );
    assert!(client(true).get(&url).send().await.is_err());

    // Skipping hostname matching does not skip certificate-chain verification.
    let untrusted = Client::builder()
        .tls_verify_hostname(false)
        .no_proxy()
        .build()
        .unwrap();
    assert!(untrusted.get(&url).send().await.is_err());
}

#[tokio::test]
async fn test_tls_self_signed_cert() {
    let (cert, key) = tls_cert::self_signed("localhost", Some("127.0.0.1".parse().unwrap()));
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);

    let client = Client::builder()
        .tls_cert_verification(false)
        .tls_info(true)
        .no_proxy()
        .build()
        .unwrap();

    let resp = client.get(&url).send().await.unwrap();
    let peer_cert_der = resp
        .extensions()
        .get::<TlsInfo>()
        .and_then(|info| info.peer_certificate())
        .unwrap();

    let self_signed_cert_store = CertStore::builder()
        .add_der_cert(peer_cert_der)
        .build()
        .unwrap();

    let client = Client::builder()
        .tls_cert_store(self_signed_cert_store)
        .no_proxy()
        .build()
        .unwrap();

    assert!(client.get(&url).send().await.unwrap().status().is_success());

    // A different self-signed cert is not trusted even at the same hostname.
    let (other_cert, other_key) =
        tls_cert::self_signed("localhost", Some("127.0.0.1".parse().unwrap()));
    let other_url = format!(
        "https://{}/",
        tls_server::serve(&other_cert, &other_key).await
    );
    assert!(client.get(&other_url).send().await.is_err());
}
