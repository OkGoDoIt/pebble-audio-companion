# Muse gadget protocol fixtures

`link_pairing_v5.json` is copied unchanged from Meta's Muse Gadget SDK
(https://github.com/facebookincubator/muse-gadget-sdk, `linux/tests/vectors/link_pairing_v5.json`,
commit `038fc3a`), Apache License 2.0, Copyright (c) Meta Platforms, Inc. and affiliates.
It is synthetic test data (private scalars 1, 2 and 3; counter-pattern nonces), never real keys.

`noise_xx_25519_aesgcm_sha256.json` is the `Noise_XX_25519_AESGCM_SHA256` entry of the cacophony
Noise test vectors (https://github.com/haskell-cryptography/cacophony, `vectors/cacophony.txt`),
extracted unchanged: fixed keys, a prologue and per-message payloads, so the initiator is checked
against an independent implementation rather than only against our own responder.
