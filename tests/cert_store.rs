#[path = "support/tls_cert.rs"]
mod tls_cert;
#[path = "support/tls_server.rs"]
mod tls_server;

use wreq::{Client, tls::trust::CertStore};

#[tokio::test]
async fn verify_host_overrides_uri_host() {
    let (cert, key) = tls_cert::self_signed("wreq.test", Some([192, 0, 2, 1].into()));
    let der = cert.to_der().unwrap();
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);

    let get = |host: &'static str| {
        let store = CertStore::builder()
            .add_der_cert(&der)
            .verify_host(host)
            .build()
            .unwrap();
        let client = Client::builder()
            .tls_cert_store(store)
            .tls_verify_hostname(false)
            .no_proxy()
            .build()
            .unwrap();
        client.get(&url).send()
    };

    // The URI names 127.0.0.1, which the certificate does not cover.
    assert!(get("wreq.test").await.unwrap().status().is_success());
    assert!(get("192.0.2.1").await.unwrap().status().is_success());
    assert!(get("other.test").await.is_err());
}

// Exercise the native-only root feature rather than relying on bundled roots.
#[cfg(feature = "native-roots")]
#[tokio::test]
async fn native_roots_build_client_and_reject_unknown_self_signed_certificate() {
    let (cert, key) = tls_cert::self_signed("localhost", Some([127, 0, 0, 1].into()));
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);
    let client = Client::builder().no_proxy().build().unwrap();
    assert!(client.get(&url).send().await.is_err());
    let der = cert.to_der().unwrap();
    let store = CertStore::from_der_certs([&der]).unwrap();
    let client = Client::builder()
        .no_proxy()
        .tls_cert_store(store)
        .build()
        .unwrap();
    assert!(client.get(&url).send().await.unwrap().status().is_success());
}
