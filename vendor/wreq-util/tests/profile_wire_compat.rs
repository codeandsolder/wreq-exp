//! Offline checks that browser profiles survive Wreq's new priority and TLS APIs.

use wreq::{
    IntoEmulation,
    http2::{HeadersDependency, HeadersPriority},
    tls::{EchGrease, EchGreaseAead, Tls13Cipher},
};
use wreq_util::{Emulation, Platform, Profile};

#[test]
fn chrome149_headers_priority_uses_root_exclusive_weight_255() {
    let options = Profile::Chrome149
        .into_emulation()
        .http2_options
        .expect("Chrome HTTP/2 profile");
    assert_eq!(
        options.headers_priority,
        Some(HeadersPriority::new(HeadersDependency::Root, 255, true))
    );
}

#[test]
fn firefox109_uses_declared_parent_13_with_preface_priority_tree() {
    let options = Profile::Firefox109
        .into_emulation()
        .http2_options
        .expect("Firefox HTTP/2 profile");
    assert_eq!(options.initial_stream_id, Some(15));
    assert_eq!(
        options.headers_priority,
        Some(HeadersPriority::new(
            HeadersDependency::Declared(13_u32.into()),
            41,
            false,
        ))
    );
    assert!(options.priorities.is_some());
}

#[test]
fn firefox135_explicit_tls13_order_and_ech_aead() {
    let options = Profile::Firefox135
        .into_emulation()
        .tls_options
        .expect("Firefox TLS profile");
    assert_eq!(
        options.tls13_cipher_list.as_deref(),
        Some(
            [
                Tls13Cipher::AES_128_GCM_SHA256,
                Tls13Cipher::CHACHA20_POLY1305_SHA256,
                Tls13Cipher::AES_256_GCM_SHA384,
            ]
            .as_slice()
        )
    );
    assert_eq!(
        options.ech_grease,
        Some(EchGrease::Aead(EchGreaseAead::AES_128_GCM))
    );
}

#[test]
fn safari_ios18_preserves_distinct_platform_and_cipher_settings() {
    let native = Emulation::builder()
        .profile(Profile::SafariIos18_1_1)
        .platform(Platform::IOS)
        .headers(false)
        .build()
        .into_emulation();
    assert!(native.tls_options.is_some());
    assert!(native.http2_options.is_some());
    assert!(native.headers.is_empty());
}

#[test]
fn okhttp39_without_tls13_suites_keeps_backend_default() {
    let options = Profile::OkHttp3_9
        .into_emulation()
        .tls_options
        .expect("OkHttp TLS profile");
    assert_eq!(options.tls13_cipher_list, None);
    assert!(
        options
            .cipher_list
            .as_deref()
            .unwrap()
            .contains("TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256")
    );
}

#[test]
fn okhttp313_preserves_supported_explicit_tls13_order() {
    let options = Profile::OkHttp3_13
        .into_emulation()
        .tls_options
        .expect("OkHttp TLS profile");
    assert_eq!(
        options.tls13_cipher_list.as_deref(),
        Some(
            [
                Tls13Cipher::AES_128_GCM_SHA256,
                Tls13Cipher::AES_256_GCM_SHA384,
                Tls13Cipher::CHACHA20_POLY1305_SHA256,
            ]
            .as_slice()
        )
    );
}

#[test]
fn no_browser_profile_explicitly_sets_an_empty_tls13_cipher_list() {
    // The old combined TLS cipher strings may contain only pre-TLS-1.3
    // suites. In that case leave the backend's normal TLS 1.3 defaults
    // intact rather than explicitly asking BoringSSL to reset the list.
    for &profile in Profile::VARIANTS {
        let options = Emulation::builder()
            .profile(profile)
            .headers(false)
            .build()
            .into_emulation()
            .tls_options
            .expect("every browser profile supplies TLS options");
        assert!(
            options
                .tls13_cipher_list
                .as_deref()
                .is_none_or(|list| !list.is_empty()),
            "profile {profile:?} supplied an explicit empty TLS 1.3 cipher list"
        );
    }
}
