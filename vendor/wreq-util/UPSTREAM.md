# Vendored wreq-util browser profile compatibility

Source: https://github.com/0x676e67/wreq-util at `917d2581d6761a94db66466caa6c2eb4d4cdbd43`, Apache-2.0 (LICENSE).

This copy is maintained alongside codeandsolder/wreq-exp because the published
wreq-util 0.2.1 targets removed options in current Wreq: the old HEADERS
stream dependency builder and the preserve-TLS-1.3-cipher-list toggle.

The new HEADERS priority API preserves the original parent, wire weight and
exclusivity semantics, including Firefox's declared idle parent stream 13.
The TLS 1.3 cipher order is explicitly configured for Chrome, Firefox, Opera
and OkHttp as well as Safari variants requesting cipher-list preservation.

Removed AES hardware overrides have been replaced by explicit TLS 1.3 suite
order and AES-128-GCM ECH GREASE policies, preventing the emulated fingerprint
from changing with the machine's AES hardware capabilities.

Wreq is a path dependency on the repository root, so compatibility changes
are checked against exactly the Wreq implementation used by downstream tools.
Preserve all browser and platform variants; do not substitute partial profiles.
