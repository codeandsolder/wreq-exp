//! Loopback HTTPS server shared by TLS certificate validation tests.

use std::{net::SocketAddr, pin::Pin};

use btls::{
    pkey::{PKey, Private},
    ssl::Ssl,
    x509::X509,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

use super::tls_cert;

/// Serves a local HTTPS endpoint using the provided certificate and key.
///
/// The listener binds to an ephemeral loopback port; tests can deliberately
/// supply a certificate whose DNS SAN differs from the URL's IP address.
pub async fn serve(cert: &X509, key: &PKey<Private>) -> SocketAddr {
    let acceptor = tls_cert::acceptor(cert, key);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    start(listener, acceptor)
}

/// Serves TLS with a caller-configured acceptor (for example TLS 1.3 only).
pub fn start(listener: TcpListener, acceptor: btls::ssl::SslAcceptor) -> SocketAddr {
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let ssl = Ssl::new(acceptor.context()).unwrap();
            let mut stream = tokio_btls::SslStream::new(ssl, tcp).unwrap();
            tokio::spawn(async move {
                if Pin::new(&mut stream).accept().await.is_ok() {
                    let mut buf = [0; 1024];
                    let _ = stream.read(&mut buf).await;
                    let _ = stream
                        .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
                        .await;
                }
            });
        }
    });
    addr
}
