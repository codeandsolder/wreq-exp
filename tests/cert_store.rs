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
