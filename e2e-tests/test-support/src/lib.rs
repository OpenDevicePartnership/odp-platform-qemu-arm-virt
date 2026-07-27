//! Shared E2E test support utilities for FF-A based UEFI tests.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_std]

use ffa::{DirectMessagePayload, Function, IdGet, Version};
use uefi::prelude::*;
use uuid::Uuid;

/// EC Thermal service UUID: 31f56da7-593c-4d72-a4b3-8fc7171ac073
///
/// Used for partition discovery because the BIOS includes a separate SP that
/// also claims the TPM UUID. Both services run in the same EC SP.
pub const THERMAL_UUID: Uuid = uuid::uuid!("31f56da7-593c-4d72-a4b3-8fc7171ac073");

/// EC Battery service UUID: 25cb5207-ac36-427d-aaef-3aa78877d27e
pub const BATTERY_UUID: Uuid = uuid::uuid!("25cb5207-ac36-427d-aaef-3aa78877d27e");

/// EC TimeAlarm service UUID: 23ea63ed-b593-46ea-b027-8924df88e92f
pub const TIME_ALARM_UUID: Uuid = uuid::uuid!("23ea63ed-b593-46ea-b027-8924df88e92f");

const FFA_MSG_SEND_DIRECT_REQ2: u64 = 0xC400008D;
const FFA_MSG_SEND_DIRECT_RESP2: u64 = 0xC400008E;
const FFA_INTERRUPT: u64 = 0x84000062;
const FFA_YIELD: u64 = 0x8400006C;
const FFA_RUN: u64 = 0x8400006D;

/// Pass/fail accounting shared by the setup phase and the service-ready
/// context.
#[derive(Default)]
struct Tally {
    passed: u32,
    failed: u32,
}

impl Tally {
    fn pass(&mut self, name: &str) {
        self.passed += 1;
        log::info!("[PASS] {}", name);
    }

    fn fail(&mut self, name: &str, reason: &str) {
        self.failed += 1;
        log::error!("[FAIL] {} - {}", name, reason);
    }

    fn summary(&self) -> bool {
        log::info!(
            "--- Results: {} passed, {} failed ---",
            self.passed,
            self.failed
        );
        self.failed == 0
    }
}

/// Setup phase: runs the standard FFA tests (version, id_get,
/// partition_discovery) and accumulates the discovered partition IDs. Promoted
/// to an [`E2eContext`] via [`Setup::into_context`] once both IDs are known.
#[derive(Default)]
struct Setup {
    tally: Tally,
    our_id: Option<u16>,
    ec_id: Option<u16>,
}

impl Setup {
    /// Test FFA version negotiation (requires >= 1.2).
    fn test_ffa_version(&mut self) {
        match Version::new().exec() {
            Ok(version) => {
                let major = version.major();
                let minor = version.minor();
                log::info!("  FFA version: {}.{}", major, minor);
                if major >= 1 && (major > 1 || minor >= 2) {
                    self.tally.pass("ffa_version");
                } else {
                    self.tally
                        .fail("ffa_version", "version too old, need >= 1.2");
                }
            }
            Err(e) => {
                self.tally.fail("ffa_version", "SMC call failed");
                log::error!("  error: {:?}", e);
            }
        }
    }

    /// Test FFA_ID_GET and record our partition ID.
    fn test_ffa_id_get(&mut self) {
        match IdGet.exec() {
            Ok(id_result) => {
                log::info!("  Our partition ID: {:#06x}", id_result.id);
                self.tally.pass("ffa_id_get");
                self.our_id = Some(id_result.id);
            }
            Err(e) => {
                self.tally.fail("ffa_id_get", "SMC call failed");
                log::error!("  error: {:?}", e);
            }
        }
    }

    /// Discover the EC partition by thermal UUID and record its ID.
    fn test_partition_discovery(&mut self) {
        match ffa::ffa_partition_info_get_regs(&THERMAL_UUID) {
            Ok((count, partitions)) => {
                log::debug!("  partition_info: count={}", count);
                for (i, part) in partitions.iter().enumerate().take(count) {
                    log::debug!(
                        "    [{}] id={:#06x} ctx={} props={:#010x}",
                        i,
                        part.partition_id,
                        part.execution_ctx_count,
                        part.properties,
                    );
                }
                if count > 0 {
                    let id = partitions[0].partition_id;
                    log::info!(
                        "  Found EC partition: id={:#06x} ctx={} props={:#010x}",
                        id,
                        partitions[0].execution_ctx_count,
                        partitions[0].properties,
                    );
                    self.tally.pass("partition_discovery");
                    self.ec_id = Some(id);
                } else {
                    self.tally.fail(
                        "partition_discovery",
                        "no partitions found for thermal UUID",
                    );
                }
            }
            Err(e) => {
                self.tally
                    .fail("partition_discovery", "PARTITION_INFO_GET_REGS failed");
                log::error!("  error: {:?}", e);
            }
        }
    }

    /// Promote to a service-ready [`E2eContext`] once both partition IDs exist.
    /// On failure, returns the accumulated [`Tally`] so the caller can still
    /// report the aggregate setup summary.
    fn into_context(self) -> Result<E2eContext, Tally> {
        match (self.our_id, self.ec_id) {
            (Some(our_id), Some(ec_id)) => Ok(E2eContext {
                tally: self.tally,
                our_id,
                ec_id,
            }),
            _ => Err(self.tally),
        }
    }
}

/// Service-ready shared state for a single test binary: pass/fail accounting,
/// the concrete FF-A partition IDs, and the send plumbing every service test
/// drives. Constructed only via [`Setup::into_context`], so the send methods
/// always have valid IDs and can never panic on a missing ID.
pub struct E2eContext {
    tally: Tally,
    our_id: u16,
    ec_id: u16,
}

impl E2eContext {
    pub fn pass(&mut self, name: &str) {
        self.tally.pass(name);
    }

    pub fn fail(&mut self, name: &str, reason: &str) {
        self.tally.fail(name, reason);
    }

    /// Send `[command, args…]` to `uuid` on the EC partition and return the
    /// response body, failing `test_name` when the SP sends no DIRECT_RESP2.
    pub fn send_command(
        &mut self,
        test_name: &str,
        uuid: &Uuid,
        command: u8,
        args: &[u8],
    ) -> Option<DirectMessagePayload> {
        let payload = build_request(command, args);
        self.send_payload(test_name, uuid, &payload, "no DIRECT_RESP2 from SP")
    }

    /// Send a fully-built request `payload` to `uuid` and return the response
    /// body. When the SP sends no DIRECT_RESP2, fail `test_name` with the
    /// caller-supplied `no_response_reason` and return `None`.
    pub fn send_payload(
        &mut self,
        test_name: &str,
        uuid: &Uuid,
        payload: &DirectMessagePayload,
        no_response_reason: &str,
    ) -> Option<DirectMessagePayload> {
        match send_direct_req2(self.our_id, self.ec_id, uuid, payload) {
            Some(resp) => Some(response_payload(&resp)),
            None => {
                self.fail(test_name, no_response_reason);
                None
            }
        }
    }

    fn summary(&self) -> bool {
        self.tally.summary()
    }
}

/// Send an FF-A Direct Request v2 and handle YIELD/INTERRUPT retries.
///
/// Returns the raw SMC response registers on success (DIRECT_RESP2), or `None`
/// if the response FID was unexpected after retries.
fn send_direct_req2(
    our_id: u16,
    dest_id: u16,
    uuid: &Uuid,
    payload: &DirectMessagePayload,
) -> Option<[u64; 18]> {
    let x1 = ((our_id as u64) << 16) | (dest_id as u64);
    let (uuid_high, uuid_low) = uuid.as_u64_pair();
    let x2 = uuid_high.to_be();
    let x3 = uuid_low.to_be();

    let mut payload_regs = [0u64; 14];
    for (i, reg) in payload.registers_iter().enumerate().take(14) {
        payload_regs[i] = reg;
    }

    let mut resp = ffa::raw_smc(
        FFA_MSG_SEND_DIRECT_REQ2,
        x1,
        x2,
        x3,
        payload_regs[0],
        payload_regs[1],
        payload_regs[2],
        payload_regs[3],
        payload_regs[4],
        payload_regs[5],
        payload_regs[6],
        payload_regs[7],
        payload_regs[8],
        payload_regs[9],
        payload_regs[10],
        payload_regs[11],
        payload_regs[12],
        payload_regs[13],
    );

    let mut retries = 0;
    while (resp[0] == FFA_YIELD || resp[0] == FFA_INTERRUPT) && retries < 100 {
        log::debug!(
            "  FFA_YIELD/INTERRUPT (x0={:#x}), calling FFA_RUN...",
            resp[0]
        );
        let run_arg = (dest_id as u64) << 16;
        resp = ffa::raw_smc(
            FFA_RUN, run_arg, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        );
        retries += 1;
    }

    if resp[0] == FFA_MSG_SEND_DIRECT_RESP2 {
        Some(resp)
    } else {
        log::error!(
            "  x0={:#018x} (expected DIRECT_RESP2={:#x})",
            resp[0],
            FFA_MSG_SEND_DIRECT_RESP2
        );
        None
    }
}

/// Extract the response payload (x4..x17) from raw SMC result registers.
fn response_payload(resp: &[u64; 18]) -> DirectMessagePayload {
    DirectMessagePayload::from_iter(resp[4..18].iter().flat_map(|r| r.to_le_bytes()))
}

/// Build a `[command, args…]` FF-A Direct-Request payload, zero-padded to the
/// full 14-register (112-byte) message payload the SP services parse.
fn build_request(command: u8, args: &[u8]) -> DirectMessagePayload {
    DirectMessagePayload::from_iter(
        core::iter::once(command)
            .chain(args.iter().copied())
            .chain(core::iter::repeat(0u8))
            .take(14 * 8),
    )
}

/// Common test harness: initialises UEFI + UART logging, runs the standard
/// FFA setup tests (version, id_get, partition_discovery), then invokes the
/// caller's service-specific tests and returns the appropriate UEFI status.
///
/// The closure receives the [`E2eContext`], which owns the discovered
/// partition IDs and the FF-A send plumbing.
pub fn run_tests(f: impl FnOnce(&mut E2eContext)) -> Status {
    uefi::helpers::init().unwrap();
    uart_logger::init();
    log::info!("=== EC Secure Partition E2E Tests ===");

    let mut setup = Setup::default();

    setup.test_ffa_version();
    setup.test_ffa_id_get();
    setup.test_partition_discovery();

    let ok = match setup.into_context() {
        Ok(mut ctx) => {
            f(&mut ctx);
            ctx.summary()
        }
        Err(tally) => tally.summary(),
    };

    if ok {
        Status::SUCCESS
    } else {
        Status::ABORTED
    }
}
