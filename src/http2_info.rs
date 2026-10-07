//! HTTP/2 peer transport observations.

/// One entry from the peer's initial HTTP/2 SETTINGS frame.
#[derive(Debug, Clone, Copy, Hash, Eq, PartialEq)]
pub struct Http2Setting {
    id: u16,
    value: u32,
}

impl Http2Setting {
    /// Raw 16-bit SETTINGS identifier as observed on the wire.
    #[inline]
    pub fn id(&self) -> u16 {
        self.id
    }

    /// Raw 32-bit SETTINGS value as observed on the wire.
    #[inline]
    pub fn value(&self) -> u32 {
        self.value
    }
}

/// HTTP/2 metadata observed from the connected peer.
///
/// This is deliberately transport-oriented rather than a server classifier. The
/// initial SETTINGS entries are retained in peer wire order, including unknown
/// setting identifiers, so callers can derive fingerprints without losing raw
/// evidence.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Http2Info {
    local_initial_settings: Vec<Http2Setting>,
    peer_initial_settings: Vec<Http2Setting>,
}

impl Http2Info {
    /// Initial SETTINGS entries sent by this client, in wire order.
    #[inline]
    pub fn local_initial_settings(&self) -> &[Http2Setting] {
        &self.local_initial_settings
    }

    /// Initial SETTINGS entries received from the peer, in wire order.
    #[inline]
    pub fn peer_initial_settings(&self) -> &[Http2Setting] {
        &self.peer_initial_settings
    }

    pub(crate) fn from_settings(
        local: &[http2::frame::ObservedSetting],
        peer: Option<&http2::frame::Settings>,
    ) -> Self {
        let local_initial_settings = local
            .iter()
            .map(|setting| Http2Setting {
                id: setting.id(),
                value: setting.value(),
            })
            .collect();
        let peer_initial_settings = peer
            .and_then(http2::frame::Settings::observed_settings)
            .unwrap_or_default()
            .iter()
            .map(|setting| Http2Setting {
                id: setting.id(),
                value: setting.value(),
            })
            .collect();
        Self {
            local_initial_settings,
            peer_initial_settings,
        }
    }
}
