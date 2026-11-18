#![cfg(unix)]

mod support;

use std::{hash::BuildHasher, path::PathBuf, pin::Pin, time::Duration};

use btls::ssl::{Ssl, SslAcceptor, SslMethod};
use http::Method;
use http_body_util::Full;
use hyper::{Request, Response, body::Incoming, service::service_fn};
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server::conn::auto::Builder,
};
use tokio::{
    net::{TcpListener, UnixListener},
    task,
};
use tokio_btls::SslStream;
use wreq::{Client, Proxy, tls::trust::CertStore};

struct UnixSocketPath(PathBuf);

impl Drop for UnixSocketPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn random_sock_path() -> UnixSocketPath {
    let mut buf = std::env::temp_dir();
    // libstd uses system random to create each one
    let rng = std::collections::hash_map::RandomState::new();
    let n = rng.hash_one("uds-sock");
    buf.push(format!("test-uds-sock-{}", n));
    UnixSocketPath(buf)
}

#[tokio::test]
async fn test_unix_socket() {
    let sock_path = random_sock_path();

    let listener = UnixListener::bind(&sock_path.0).unwrap();
    let server = async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let io = TokioIo::new(stream);
            let service = service_fn(|_req: Request<Incoming>| async {
                Ok::<_, hyper::Error>(Response::new(Full::new(&b"hello unix"[..])))
            });
            task::spawn(async move {
                if let Err(e) = hyper::server::conn::http1::Builder::new()
                    .serve_connection(io, service)
                    .await
                {
                    eprintln!("server error: {:?}", e);
                }
            });
        }
    };
    tokio::spawn(server);

    let client = Client::builder()
        .proxy(Proxy::unix(sock_path.0.as_path()).unwrap())
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();

    let resp = client.get("http://localhost/").send().await.unwrap();
    let body = resp.text().await.unwrap();
    assert_eq!(body, "hello unix");
}

#[tokio::test]
async fn test_proxy_unix_socket() {
    // A local HTTPS target verifies CONNECT tunnelling without depending on
    // Google (which can return 403 or 429 based on the CI runner's IP).
    let (cert, key) =
        support::tls_cert::self_signed("localhost", Some("127.0.0.1".parse().unwrap()));
    let trust = CertStore::builder()
        .add_der_cert(&cert.to_der().unwrap())
        .build()
        .unwrap();
    let mut tls_builder = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
    tls_builder.set_certificate(&cert).unwrap();
    tls_builder.set_private_key(&key).unwrap();
    let tls = tls_builder.build();

    let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_addr = upstream.local_addr().unwrap();
    let upstream_task = tokio::spawn(async move {
        let (tcp, _) = upstream.accept().await.unwrap();
        let ssl = Ssl::new(tls.context()).unwrap();
        let mut stream = SslStream::new(ssl, tcp).unwrap();
        Pin::new(&mut stream).accept().await.unwrap();
        let service = service_fn(|req: Request<Incoming>| async move {
            assert_eq!(req.method(), Method::GET);
            Ok::<_, hyper::Error>(Response::new(Full::new(&b"hello tunneled HTTPS"[..])))
        });
        hyper::server::conn::http1::Builder::new()
            .serve_connection(TokioIo::new(stream), service)
            .await
            .unwrap();
    });

    let sock_path = random_sock_path();
    let (connect_tx, mut connect_rx) = tokio::sync::mpsc::unbounded_channel();

    let listener = UnixListener::bind(&sock_path.0).unwrap();
    let server = async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let io = TokioIo::new(stream);
            let connect_tx = connect_tx.clone();
            let service = service_fn(move |req: Request<Incoming>| {
                let connect_tx = connect_tx.clone();
                async move {
                    if Method::CONNECT == req.method() {
                        // Received an HTTP request like:
                        // ```
                        // CONNECT www.domain.com:443 HTTP/1.1
                        // Host: www.domain.com:443
                        // Proxy-Connection: Keep-Alive
                        // ```
                        //
                        // When HTTP method is CONNECT we should return an empty body,
                        // then we can eventually upgrade the connection and talk a new protocol.
                        //
                        // Note: only after client received an empty body with STATUS_OK can the
                        // connection be upgraded, so we can't return a response inside
                        // `on_upgrade` future.
                        let authority = req.uri().authority().cloned().unwrap();
                        connect_tx.send(authority.to_string()).unwrap();
                        tokio::task::spawn({
                            let req = req;
                            async move {
                                match hyper::upgrade::on(req).await {
                                    Ok(upgraded) => {
                                        tracing::info!("upgraded connection to: {}", authority);
                                        if let Ok(mut io) =
                                            tokio::net::TcpStream::connect(authority.to_string())
                                                .await
                                        {
                                            let _ = tokio::io::copy_bidirectional(
                                                &mut TokioIo::new(upgraded),
                                                &mut io,
                                            )
                                            .await;
                                        }
                                    }
                                    Err(e) => tracing::warn!("upgrade error: {}", e),
                                }
                            }
                        });

                        Ok::<_, hyper::Error>(Response::new(Full::new(&b""[..])))
                    } else {
                        Ok::<_, hyper::Error>(Response::new(Full::new(
                            &b"unsupported request method"[..],
                        )))
                    }
                }
            });
            task::spawn(async move {
                if let Err(e) = Builder::new(TokioExecutor::new())
                    .serve_connection_with_upgrades(io, service)
                    .await
                {
                    eprintln!("server error: {:?}", e);
                }
            });
        }
    };
    let proxy_task = tokio::spawn(server);

    let client = Client::builder()
        .proxy(Proxy::unix(sock_path.0.as_path()).unwrap())
        .tls_cert_store(trust)
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();

    let resp = client
        .get(format!("https://127.0.0.1:{}/", upstream_addr.port()))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), wreq::StatusCode::OK);
    assert_eq!(resp.text().await.unwrap(), "hello tunneled HTTPS");
    assert_eq!(
        connect_rx
            .try_recv()
            .expect("Unix proxy must receive CONNECT"),
        format!("127.0.0.1:{}", upstream_addr.port())
    );

    proxy_task.abort();
    upstream_task.abort();
}
