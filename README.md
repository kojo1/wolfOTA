## wolfOTA --- OTA cloud service for secure update

English | [日本語](README_jp.md)

wolfOTA is a cloud service for securely updating device firmware. It includes the on-device platform for this service.
The implementation uses wolfSSL products wherever possible.

### Usage scenarios

- Install: add secure update capability (wolfOTA for Device: o4d) to a device that has not been secured.
- Enroll: register a device that has o4d installed with the wolfOTA cloud service.
- Initial attestation: remotely confirm at enrollment that a genuine o4d is running.
- Certificate renewal (re-enrollment): renew a device certificate approaching expiry over EST.
- Deploy: distribute a new firmware version to enrolled devices.
- Remote attestation: remotely confirm at any time that genuine firmware is running on the device.
- Quarantine: isolate a device that fails attestation.
- Unenroll: remove an enrolled device from the service.

### Main functions and components

Cloud side

- Deploy server: MQTT-based server (wolfMQTT broker or mosquitto, mTLS with wolfSSL)
- Enrollment server: issues certificates over EST at enrollment and certificate renewal.
  Uses the open-source EST server globalsign/est (Go, MIT). Interoperability with wolfCert is covered by wolfCert's interop tests.
  Issuance is plugged in by implementing the `est.CA` interface (`Enroll` / `Reenroll`), where the verifier's verdict is checked.
  (The server bundled with wolfCert is for development and interop testing, so it is used only for unit testing.)
- Verifier: verifies attestation tokens sent from devices, compares them against reference values,
  and records the verdict in the device registry.
- Device registry: manages device ID, certificate, DeviceID public key, firmware version,
  attestation results and state (enrolled / quarantined / revoked, etc.).

Device side (o4d)

- Client-side enrollment and certificate renewal using wolfCert (github.com/wolfssl/wolfcert)
  (integrated as a Zephyr module; key operations delegated to ELS via CryptoCb)
- Secure boot and update by wolfBoot
- Remote attestation (wolfBoot DICE; tokens are COSE_Sign1 produced by wolfCOSE)
- Update agent (receives over wolfMQTT and writes to the update partition)
- Unenroll

### wolfSSL products used

| Function | Product |
|---|---|
| TLS / mTLS | wolfSSL |
| MQTT | wolfMQTT |
| Enrollment / certificate renewal (EST) | wolfCert (client). Server is globalsign/est (OSS) |
| CA operation | wolfCLU |
| Secure boot, update, signing tools | wolfBoot, wolfBoot keytools |
| Attestation | wolfBoot DICE, wolfCOSE |
| Future RoT variations | wolfTPM, wolfHSM |

### Trust assumptions (Root of Trust)

When o4d is installed after the fact, the basis for claiming "a genuine o4d is running" at initial attestation
depends on the device's hardware RoT. The following variations will be covered eventually.

| Type | Description | Example |
|---|---|---|
| A. UDS (hardware protected) | UDS/CDI/keys are not visible to software | NXP MCX N (ELS) |
| B. UDS (readable by software) | wolfBoot performs DICE derivation in software | STM32H5 |
| C. TPM | Measured boot and Quote with wolfTPM | Discrete TPM, fwTPM |
| D. No hardware RoT | Factory provisioning or TOFU (trust on first use) | Generic MCU |

**The initial PoC starts with A (a chip with UDS).** The target is the ELS (EdgeLock Secure Subsystem) of the NXP FRDM-MCXN947.

- The boot ROM generates the initial CDI from the UDS and the wolfBoot hash into an ELS key slot.
- wolfBoot derives CDIs with the ELS HKDF and performs key generation and signing inside ELS.
- Secrets (UDS/CDI/private keys) are never exposed to software.

#### Implementation policy

Keep the generic parts common as much as possible, and use features provided by each chip where available.

- CBOR/COSE encoding, token format, communication protocols and the server side are common implementations.
- RoT-dependent operations such as CDI derivation, key generation and signing sit behind wolfBoot HAL hooks
  (`hal_dice_update_cdi()` / `hal_dice_create_attest_key()`, etc.),
  and chip-specific terms and APIs do not appear outside the HAL implementation.
- When a chip lacks a feature, fall back to a software implementation with wolfCrypt.

### Attestation key structure (two-layer DICE)

If the attestation key changed with every firmware update, it could no longer be verified with the public key
registered at the verifier. To avoid this, DICE is structured in two layers.

| Layer | CDI | Key | Measurements | Lifetime |
|---|---|---|---|---|
| Layer 0 | CDI_L0 = f(UDS, wolfBoot measurement) | DeviceID key | wolfBoot | Long-term (unchanged unless wolfBoot is updated) |
| Layer 1 | CDI_L1 = HKDF(CDI_L0, application image measurement) | Alias key | wolfBoot + application | Per firmware |

- At boot, wolfBoot signs the certificate for the Alias key (Alias certificate) with the DeviceID key.
  The Alias certificate contains the application image measurement.
- The attestation token is signed with the Alias key and accompanied by the Alias certificate.
- The verifier validates the chain "DeviceID → Alias certificate → token" with the DeviceID public key registered at enrollment.
- Since DeviceID does not change with firmware updates, the verifier's registration does not need to be updated.
- The current wolfBoot DICE is single-layer (IAK); making it two-layer is a PoC development item.

### Enrollment and initial attestation

1. The device obtains a nonce from the verifier.
2. The device generates an attestation token (EAT, COSE_Sign1) containing the nonce.
3. The device generates a device key (for TLS) with wolfCert, builds a CSR and sends it to the enrollment server via EST `/simpleenroll`.
   The token is stored in the CSR as an extension with a private OID (added with wolfCert's `customize` callback).
4. The verifier validates the token (Alias certificate chain, nonce, measurements against reference values).
5. Only if validation passes does the enrollment server issue the certificate and register it in the device registry together with the DeviceID public key.

- Placing the token inside the CSR binds the token to the device key through the CSR signature.
- The enrollment server requests this OID via `/csrattrs` (`CSRAttrs` of `est.CA`).
- In `Enroll`, the enrollment server extracts the token from the CSR, queries the verifier and issues only on a pass.
- Binding the CSR to the TLS session with tls-unique (RFC 7030) is not supported by wolfCert (TLS 1.3 has no tls-unique).

### Certificate renewal (re-enrollment)

1. The device (wolfCert) checks the remaining validity of its certificate and starts renewal when it falls below a threshold.
2. It connects to the enrollment server with mTLS using its current device certificate and sends a new CSR via EST `/simplereenroll`.
   An attestation token is attached, and the certificate is issued only if the verifier's verdict is a pass.
   In `Reenroll`, the enrollment server checks the CSR against the current certificate presented over mTLS, checks the state in the registry and validates the token.
3. The new certificate is stored and used for subsequent connections. The old certificate remains valid until expiry but is treated as superseded in the registry.
4. CA certificate updates are retrieved via EST `/cacerts`.
5. Re-enrollment from quarantined or revoked devices is rejected.

### Deployment

Built basically on wolfBoot tools and MQTT pub/sub.

1. Signing: sign the firmware and assign a version with wolfBoot keytools (`sign`).
2. Notification: the deploy server publishes a manifest (version, size, hash, number of chunks) to the target device's topic.
3. Chunked transfer: the signed image is split into chunks and published; the device subscribes and receives them.
   Chunks carry sequence numbers, and the device publishes its reception status (ack / retransmission request).
4. Writing: the update agent writes the received chunks to the wolfBoot update partition.
5. Applying: after all chunks are received, call `wolfBoot_update_trigger()`. **By default the update is applied at the next reboot.**
6. Confirmation: wolfBoot verifies the signature and version and boots. The new firmware calls `wolfBoot_success()` after confirming it booted correctly;
   if not confirmed, wolfBoot rolls back.
7. Report: the device publishes its new version and an attestation token, and the device registry is updated.

Topic structure (draft)

```
wolfota/<device-id>/manifest   server → device
wolfota/<device-id>/chunk      server → device
wolfota/<device-id>/status     device → server (ack, retransmission request, version report, failure report)
wolfota/<device-id>/attest     bidirectional (nonce request / token)
wolfota/<device-id>/control    server → device (unenroll, etc.)
```

#### Handling update failures

Image verification, recovery from power loss during a swap, and rollback when boot is not confirmed are covered by wolfBoot's state management.
The following other cases are handled by o4d and the server side.

| Case | Handling | Responsible |
|---|---|---|
| Transfer interrupted (connection loss, device reboot) | Record received chunks and resume from where it stopped | Update agent, deploy server |
| Received image inconsistent | Check against the manifest hash before `wolfBoot_update_trigger()`; discard and report on mismatch | Update agent |
| New firmware hangs and reaches neither `wolfBoot_success()` nor a reboot | Enable the watchdog so that a reset triggers rollback | o4d (board configuration) |
| Boots but cannot provide service (cannot reconnect to MQTT, etc.) | Call `wolfBoot_success()` only after reconnecting to the server and passing attestation | Update agent |
| Server unaware that a rollback occurred | Report the current version after boot; the server records a mismatch with the expected version as a failure | Update agent, deploy server |
| Repeated failures from redistributing the same version | Do not automatically redistribute a failed version (re-run at the operator's discretion) | Deploy server |
| Image not intended for the device (other board / partition) | Check target board and image type in the manifest and reject | Update agent (wolfBoot also verifies the image type) |

#### Preventing downgrade attacks

- wolfBoot rejects updates to a version lower than the current one (using the default setting with `ALLOW_DOWNGRADE` disabled).
- The version is part of the signed image header, so tampering with it is rejected by signature verification.
- The deploy server also rejects distribution of older versions at the manifest stage.
- Countermeasures against writing an old image into flash with physical access are out of scope for the PoC.

### Remote attestation

1. The verifier sends a nonce on the `attest` topic.
2. The device generates a token with the wolfBoot attestation service and returns it together with the Alias certificate.
3. The verifier validates the Alias certificate and the token with the DeviceID public key (registered at enrollment) and compares the measurements against reference values.
4. Reference values are registered from the hashes of the images signed at deployment.

#### Handling attestation failures (quarantine)

The default is quarantine.

- A quarantined device is excluded from deployment and certificate renewal.
  Only access to the `attest`, `status` and `control` topics is allowed (broker ACL).
- Quarantine is lifted when the device passes attestation again or an operator releases it.
  If genuine firmware needs to be redistributed during quarantine, this is done at the operator's discretion.

Viewing attestation results (simple)

- For each device, the verifier records in the registry the time of judgment, the verdict (pass / fail / unverifiable), the reason,
  and the reported measurements and firmware version.
- Operators can view the device list, latest results and history with a CLI (or a read-only HTTP endpoint).

### Unenroll

Proposed scope for the initial PoC

| Item | Initial PoC | Notes |
|---|---|---|
| Set device state to revoked in the registry | Yes | |
| Revoke the device certificate (issue CRL) | Yes | CRL generated with wolfCLU |
| Reject connections at the broker | Yes | CRL check with wolfSSL on the broker side |
| Unenroll command to the device and response | Yes | `control` topic, signed command |
| Erase certificate and device key on the device | Yes | |
| Exclude from deployment and attestation | Yes | |
| OCSP | No | Future |
| Uninstall o4d (restore original firmware) | No | Future |
| Re-enrollment | No | Future |

Note: the DeviceID key derived by DICE is generated deterministically from the UDS and measurements, so it cannot be "erased" on the device.
Unenrollment is achieved by invalidating the binding between the DeviceID and the device on the server side.

### Future work

- Updating o4d itself (wolfBoot)
- Signing key rotation
- Ownership transfer / decommissioning
- Staged rollout
- Encrypted updates / delta updates
- Time handling on devices without an RTC
- PQC migration
- Device status reporting (version, SBOM)
- Extension to other RoTs (trust assumptions B to D)

### PoC development items

Items missing from existing products that need to be developed in the PoC.

| Item | Target | Description |
|---|---|---|
| Two-layer DICE | wolfBoot | Generation of DeviceID key, Alias key and Alias certificate |
| Public key operations in ELS | wolfSSL (NXP ELS port) | The current ELS port CryptoCb supports only AES/CMAC/hash/RNG. Add a CryptoCb that performs ECC P-256 key generation and signing in ELS key slots, mapped to wolfCert's `key_id` (key slot). Software keys are used in the meantime |
| Issuance (CA implementation) | globalsign/est | Implement `est.CA` to query the verifier with the token in the CSR and issue only on a pass. CA key and issued certificates linked to the registry |
| Update agent | o4d | Receiving MQTT chunked transfer, handling update failures |
| Verifier, device registry, deploy server | Cloud | New |

### Initial PoC target

- Board: NXP FRDM-MCXN947 (TrustZone, ELS)
- Base: existing wolfBoot OTA demo (wolfBoot + Zephyr + wolfMQTT) and the hardware DICE plan for MCXN947
- Software: wolfSSL 5.9.4 or later (required by wolfCert), Zephyr 4.4 + SDK 1.0.1

### Simulation environment (Docker)

Before running on hardware, the whole flow is reproduced on a host PC with docker compose.

| Container | Contents |
|---|---|
| `ca` | Creates the CA and server certificates with wolfCLU and places them in a shared volume |
| `broker` | mosquitto (TLS 1.3, mTLS) |
| `est` | globalsign/est with our own `est.CA` implementation |
| `verifier` | Verifier and device registry (Go, SQLite) |
| `deploy` | Signing with wolfBoot keytools and MQTT chunked transfer |
| `device` | wolfBoot sim target + o4d for Linux (scalable to multiple devices) |

- wolfBoot's sim target emulates flash with a file, verifies signatures and boots the application (o4d).
  o4d enrolls with wolfCert, receives updates with wolfMQTT, writes them to the update partition and calls `wolfBoot_update_trigger()`;
  after a restart, wolfBoot swaps the images.
- ELS cannot be emulated, so the simulation uses a software implementation that reads the UDS from a file (trust assumption B).
  This is the first instance of the policy of keeping chip-specific parts behind the HAL;
  two-layer DICE is developed and verified on the sim first, then the ELS HAL for MCXN947 is substituted.
- wolfSSL products are fetched from GitHub at fixed tags/commits when the images are built.

Phases

1. CA, broker, EST and device: enroll to obtain a certificate and connect to MQTT with mTLS.
2. Deployment (signing, chunked transfer, update on restart, rollback check).
3. Verifier, two-layer DICE (sim HAL), token-based enrollment, quarantine.
4. Certificate renewal and unenrollment.

Directory layout

```
docker-compose.yml
docker/      base images (wolfSSL, wolfCLU, wolfMQTT, wolfCert)
cloud/       ca, broker, est, verifier, deploy
device/      o4d and wolfBoot sim configuration
```

#### Running phase 1

```sh
docker compose build base          # wolfSSL 5.9.4 + wolfCLU + wolfMQTT + wolfCert (first time only)
docker compose up -d --scale device=3
docker compose logs -f device
./scripts/phase1-test.sh           # enrollment, mTLS, ACL and rejection checks
docker compose down -v             # remove everything including the PKI
```

- Service names: `est.wolfota.test:8443` (EST), `broker.wolfota.test:8883` (MQTT over mTLS).
- The device ID is the container hostname for now (replaced by the DICE-derived ID in phase 3).
- Initial enrollment uses a bootstrap HTTP Basic credential until token-based enrollment (phase 3).

#### Notes found in phase 1

- wolfCert refuses single-label host names (`est`) unless wolfSSL is built with `WOLFSSL_ALLOW_SINGLE_LABEL_HOSTNAME`, so services use FQDN aliases.
- wolfMQTT's TLS callback must return `WOLFSSL_SUCCESS` (1), not 0.
- wolfCLU v0.2.0: `ca` needs a `[ca]` section in the config (crashes without it), writes `-out` relative to `new_certs_dir`,
  and does not support `extendedKeyUsage` in the config.
