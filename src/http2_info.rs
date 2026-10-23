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
    peer_initial_settings_received: bool,
    peer_initial_settings: Vec<Http2Setting>,
    peer_first_connection_window_update: Option<u32>,
    peer_first_connection_window_update_before_settings_ack: Option<bool>,
    peer_acknowledged_local_initial_settings: bool,
}

impl Http2Info {
    /// Initial SETTINGS entries sent by this client, in wire order.
    #[inline]
    pub fn local_initial_settings(&self) -> &[Http2Setting] {
        &self.local_initial_settings
    }

    /// Whether the peer's initial SETTINGS frame has been observed.
    #[inline]
    pub fn peer_initial_settings_received(&self) -> bool {
        self.peer_initial_settings_received
    }

    /// Initial SETTINGS entries received from the peer, in wire order.
    #[inline]
    pub fn peer_initial_settings(&self) -> &[Http2Setting] {
        &self.peer_initial_settings
    }

    /// First connection-level WINDOW_UPDATE increment received from the peer.
    #[inline]
    pub fn peer_first_connection_window_update(&self) -> Option<u32> {
        self.peer_first_connection_window_update
    }

    /// Whether the first connection-level WINDOW_UPDATE arrived before the
    /// peer acknowledged our initial SETTINGS frame.
    #[inline]
    pub fn peer_first_connection_window_update_before_settings_ack(&self) -> Option<bool> {
        self.peer_first_connection_window_update_before_settings_ack
    }

    /// Whether the peer acknowledged our initial SETTINGS frame.
    #[inline]
    pub fn peer_acknowledged_local_initial_settings(&self) -> bool {
        self.peer_acknowledged_local_initial_settings
    }

    pub(crate) fn from_settings(
        local: &[http2::frame::ObservedSetting],
        peer: Option<&http2::frame::Settings>,
        peer_first_connection_window_update: Option<(u32, bool)>,
        peer_acknowledged_local_initial_settings: bool,
    ) -> Self {
        let local_initial_settings = local
            .iter()
            .map(|setting| Http2Setting {
                id: setting.id(),
                value: setting.value(),
            })
            .collect();
        let peer_initial_settings_received = peer.is_some();
        let peer_initial_settings = peer
            .and_then(http2::frame::Settings::observed_settings)
            .unwrap_or_default()
            .iter()
            .map(|setting| Http2Setting {
                id: setting.id(),
                value: setting.value(),
            })
            .collect();
        let (
            peer_first_connection_window_update,
            peer_first_connection_window_update_before_settings_ack,
        ) = peer_first_connection_window_update
            .map(|(increment, before_ack)| (Some(increment), Some(before_ack)))
            .unwrap_or((None, None));
        Self {
            local_initial_settings,
            peer_initial_settings_received,
            peer_initial_settings,
            peer_first_connection_window_update,
            peer_first_connection_window_update_before_settings_ack,
            peer_acknowledged_local_initial_settings,
        }
    }
}
