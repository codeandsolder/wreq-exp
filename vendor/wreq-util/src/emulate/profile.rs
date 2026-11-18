//! Emulation for different browsers.

pub mod chrome;
pub mod firefox;
pub mod okhttp;
pub mod opera;
pub mod safari;

use typed_builder::TypedBuilder;
#[cfg(feature = "emulation-compression")]
use wreq::header::ACCEPT_ENCODING;
use wreq::{
    Group,
    header::{ACCEPT, ACCEPT_LANGUAGE, HeaderMap, HeaderName, HeaderValue, USER_AGENT},
    http2::{
        HeadersDependency, HeadersPriority, Http2Options, Priorities, Priority, PseudoId,
        PseudoOrder, SettingId, SettingsOrder, StreamDependency, StreamId,
    },
    tls::{
        AlpnProtocol, AlpsProtocol, EchGrease, EchGreaseAead, ExtensionType, KeyShare, Tls13Cipher,
        TlsOptions, TlsVersion, compress::CertificateCompressor,
    },
};

use super::{
    Emulation, Platform,
    compress::{BrotliCompressor, ZlibCompressor, ZstdCompressor},
};

/// Mirror browser profiles that previously requested AES hardware overrides.
/// Their ECH GREASE AEAD must be deterministic, not dependent on CPU flags.
fn ech_grease_aes(enabled: bool) -> Option<EchGrease> {
    enabled.then_some(EchGrease::Aead(EchGreaseAead::AES_128_GCM))
}

/// Extract TLS 1.3 suites from the combined browser cipher list in wire order.
///
/// The only TLS 1.3 suites currently defined by BoringSSL are handled; legacy
/// cipher names are left to the separate TLS 1.2 cipher-list setting.
fn tls13_ciphers_in_wire_order(cipher_list: &str) -> Vec<Tls13Cipher> {
    cipher_list
        .split(':')
        .filter_map(|suite| match suite {
            "TLS_AES_128_GCM_SHA256" => Some(Tls13Cipher::AES_128_GCM_SHA256),
            "TLS_AES_256_GCM_SHA384" => Some(Tls13Cipher::AES_256_GCM_SHA384),
            "TLS_CHACHA20_POLY1305_SHA256" => Some(Tls13Cipher::CHACHA20_POLY1305_SHA256),
            _ => None,
        })
        .collect()
}

fn build_standard_emulation(
    group: &'static str,
    tls_options: TlsOptions,
    http2_options: Option<Http2Options>,
    default_headers: Option<HeaderMap>,
) -> wreq::Emulation {
    let mut builder = wreq::Emulation::builder().tls_options(tls_options);

    if let Some(http2_options) = http2_options {
        builder = builder.http2_options(http2_options);
    }

    if let Some(headers) = default_headers {
        builder = builder.headers(headers);
    }

    builder.build(Group::new(group))
}
