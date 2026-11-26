#[path = "support/tls_cert.rs"]
mod tls_cert;
#[path = "support/tls_server.rs"]
mod tls_server;

use btls::{pkey::PKey, x509::X509};
use tokio::net::TcpListener;
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

async fn send(builder: wreq::ClientBuilder, url: &str) -> wreq::Result<wreq::Response> {
    builder.no_proxy().build().unwrap().get(url).send().await
}

fn assert_verification_failure(result: wreq::Result<wreq::Response>) {
    let error = result.unwrap_err();
    assert!(
        format!("{error:?}").contains("CERTIFICATE_VERIFY_FAILED"),
        "{error:?}"
    );
}

#[tokio::test]
async fn ca_issued_certificate_verifies_over_tls13() {
    use btls::ssl::{SslAcceptor, SslMethod, SslVersion};

    // Issued by LOCALHOST_CA for localhost and 127.0.0.1.
    const LOCALHOST_CERT: &[u8] = include_bytes!("support/localhost.cert");
    const LOCALHOST_KEY: &[u8] = include_bytes!("support/localhost.key");
    const LOCALHOST_CA: &[u8] = include_bytes!("support/localhost-ca.cert");

    let cert = X509::from_der(LOCALHOST_CERT).unwrap();
    let key = PKey::private_key_from_der(LOCALHOST_KEY).unwrap();
    let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
    acceptor.set_certificate(&cert).unwrap();
    acceptor.set_private_key(&key).unwrap();
    acceptor
        .set_min_proto_version(Some(SslVersion::TLS1_3))
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("https://{}/", tls_server::start(listener, acceptor.build()));

    assert_verification_failure(send(Client::builder(), &url).await);
    let store = CertStore::builder()
        .add_der_cert(LOCALHOST_CA)
        .build()
        .unwrap();
    let response = send(Client::builder().tls_cert_store(store), &url)
        .await
        .unwrap();
    assert!(response.status().is_success());
}

#[tokio::test]
async fn self_signed_certificate_requires_explicit_trust() {
    use wreq::tls::TlsInfo;

    let (cert, key) = tls_cert::self_signed("wreq.test", Some([127, 0, 0, 1].into()));
    let addr = tls_server::serve(&cert, &key).await;
    let url = format!("https://{addr}/");

    assert_verification_failure(send(Client::builder(), &url).await);
    assert_verification_failure(send(Client::builder().tls_verify_hostname(false), &url).await);

    let builder = Client::builder()
        .tls_cert_verification(false)
        .tls_info(true);
    let response = send(builder, &url).await.unwrap();
    assert!(response.status().is_success());
    let peer_cert = response
        .extensions()
        .get::<TlsInfo>()
        .and_then(TlsInfo::peer_certificate)
        .unwrap();
    assert_eq!(peer_cert, cert.to_der().unwrap().as_slice());

    let response = send(Client::builder().tls_cert_verification(false), &url)
        .await
        .unwrap();
    assert!(response.extensions().get::<TlsInfo>().is_none());

    let store = CertStore::builder()
        .add_der_cert(peer_cert)
        .build()
        .unwrap();
    let named = |host: &'static str| {
        Client::builder()
            .resolve(host, addr)
            .tls_cert_store(store.clone())
    };
    let port = addr.port();
    let response = send(named("wreq.test"), &format!("https://wreq.test:{port}/"))
        .await
        .unwrap();
    assert!(response.status().is_success());
    let wrong_host = format!("https://other.test:{port}/");
    assert_verification_failure(send(named("other.test"), &wrong_host).await);
    let response = send(named("other.test").tls_verify_hostname(false), &wrong_host)
        .await
        .unwrap();
    assert!(response.status().is_success());

    // Both certificates cover loopback, but the trust store contains only the first.
    let (other_cert, other_key) = tls_cert::self_signed("wreq.test", Some(addr.ip()));
    let other_addr = tls_server::serve(&other_cert, &other_key).await;
    let other_url = format!("https://{other_addr}/");
    assert_verification_failure(send(Client::builder().tls_cert_store(store), &other_url).await);
}

#[tokio::test]
async fn dns_only_certificate_rejects_ip_uri_unless_hostname_verification_is_disabled() {
    let (cert, key) = tls_cert::self_signed("expected.example", None);
    let url = format!("https://{}/", tls_server::serve(&cert, &key).await);
    let der = cert.to_der().unwrap();
    let store = CertStore::from_der_certs([&der]).unwrap();
    let trusted = || Client::builder().tls_cert_store(store.clone());
    assert_verification_failure(send(trusted(), &url).await);
    assert!(
        send(trusted().tls_verify_hostname(false), &url)
            .await
            .unwrap()
            .status()
            .is_success()
    );
}
