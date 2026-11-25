use btls::ssl::{SslConnectorBuilder, SslVerifyMode};

use crate::{
    Error,
    tls::{
        compress::{self, CertificateCompressor},
        trust::{CertStore, Identity},
    },
};

/// SslConnectorBuilderExt trait for `SslConnectorBuilder`.
pub trait SslConnectorBuilderExt {
    /// Configure the Identity for the given `SslConnectorBuilder`.
    fn set_identity(self, identity: Option<&Identity>) -> crate::Result<SslConnectorBuilder>;

    /// Configure the CertStore for the given `SslConnectorBuilder`.
    fn set_cert_store(self, store: Option<&CertStore>) -> crate::Result<SslConnectorBuilder>;

    /// Configure the certificate verification for the given `SslConnectorBuilder`.
    fn set_cert_verification(self, enable: bool) -> crate::Result<SslConnectorBuilder>;

    /// Configure the certificate compressors for the given `SslConnectorBuilder`.
    fn set_cert_compressors(
        self,
        compressors: Option<&[&'static dyn CertificateCompressor]>,
    ) -> crate::Result<SslConnectorBuilder>;
}

impl SslConnectorBuilderExt for SslConnectorBuilder {
    fn set_identity(mut self, identity: Option<&Identity>) -> crate::Result<SslConnectorBuilder> {
        if let Some(identity) = identity {
            self.set_certificate(&identity.cert).map_err(Error::tls)?;
            self.set_private_key(&identity.pkey).map_err(Error::tls)?;
            for cert in identity.chain.iter() {
                // https://www.openssl.org/docs/manmaster/man3/SSL_CTX_add_extra_chain_cert.html
                // specifies that "When sending a certificate chain, extra chain certificates are
                // sent in order following the end entity certificate."
                self.add_extra_chain_cert(cert.clone())
                    .map_err(Error::tls)?;
            }
        }
        Ok(self)
    }

    fn set_cert_store(mut self, store: Option<&CertStore>) -> crate::Result<SslConnectorBuilder> {
        if let Some(store) = store {
            btls::ssl::SslContextBuilder::set_cert_store(&mut self, store.0.as_ref().clone())
                .map_err(Error::tls)?;
        } else {
            #[cfg(any(
                feature = "chromium-roots",
                feature = "webpki-roots",
                feature = "native-roots"
            ))]
            {
                // Parsing the platform root store can be expensive. Cache the
                // immutable store without panicking on failed initialization.
                static DEFAULT_CERT_STORE: std::sync::OnceLock<CertStore> =
                    std::sync::OnceLock::new();
                let store = match DEFAULT_CERT_STORE.get() {
                    Some(store) => store,
                    None => {
                        let mut roots = std::collections::HashSet::<Vec<u8>>::new();
                        #[cfg(feature = "native-roots")]
                        {
                            let native = rustls_native_certs::load_native_certs();
                            for error in native.errors {
                                warn!("failed to load native trust root: {error}");
                            }
                            roots.extend(
                                native.certs.into_iter().map(|cert| cert.as_ref().to_vec()),
                            );
                        }
                        #[cfg(feature = "chromium-roots")]
                        roots.extend(
                            chromium_roots::TLS_SERVER_ROOT_CERTS
                                .iter()
                                .map(|cert| cert.as_ref().to_vec()),
                        );
                        #[cfg(feature = "webpki-roots")]
                        roots.extend(
                            webpki_root_certs::TLS_SERVER_ROOT_CERTS
                                .iter()
                                .map(|cert| cert.as_ref().to_vec()),
                        );
                        if roots.is_empty() {
                            return Err(Error::builder("no trust roots available"));
                        }
                        let store = CertStore::from_der_certs(roots.iter())?;
                        DEFAULT_CERT_STORE.get_or_init(|| store)
                    }
                };
                btls::ssl::SslContextBuilder::set_cert_store(&mut self, store.0.as_ref().clone())
                    .map_err(Error::tls)?;
            }

            #[cfg(not(any(
                feature = "chromium-roots",
                feature = "webpki-roots",
                feature = "native-roots"
            )))]
            {
                self.set_default_verify_paths().map_err(Error::tls)?;
            }
        }

        Ok(self)
    }

    fn set_cert_verification(mut self, enable: bool) -> crate::Result<SslConnectorBuilder> {
        self.set_verify(if enable {
            SslVerifyMode::PEER
        } else {
            SslVerifyMode::NONE
        })
        .map_err(Error::tls)?;

        Ok(self)
    }

    fn set_cert_compressors(
        mut self,
        compressors: Option<&[&'static dyn CertificateCompressor]>,
    ) -> crate::Result<SslConnectorBuilder> {
        if let Some(compressors) = compressors {
            for compressor in compressors {
                compress::register(*compressor, &mut self).map_err(Error::tls)?;
            }
        }

        Ok(self)
    }
}
