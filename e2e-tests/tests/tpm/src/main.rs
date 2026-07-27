//! E2E tests for the TPM service via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!
//! Exercises the TPM service's opcode routing, parameter validation,
//! state-machine enforcement, and access control by sending various
//! FF-A messages and checking the response status codes.

#![no_main]
#![no_std]

extern crate alloc;

use ffa::DirectMessagePayload;
use test_support::{run_tests, E2eContext};
use uefi::prelude::*;
use uuid::Uuid;

/// TPM 2.0 service UUID: 17b862a4-1806-4faf-86b3-089a58353861
const TPM_UUID: Uuid = uuid::uuid!("17b862a4-1806-4faf-86b3-089a58353861");

// ---------------------------------------------------------------------------
// TPM Service Function IDs (opcodes placed in Arg0 / register x4)
// ---------------------------------------------------------------------------
const TPM2_FFA_GET_INTERFACE_VERSION: u64 = 0x0f00_0001;
const TPM2_FFA_GET_FEATURE_INFO: u64 = 0x0f00_0101;
const TPM2_FFA_START: u64 = 0x0f00_0201;
const TPM2_FFA_REGISTER_FOR_NOTIFICATION: u64 = 0x0f00_0301;
const TPM2_FFA_UNREGISTER_FOR_NOTIFICATION: u64 = 0x0f00_0401;
const TPM2_FFA_FINISH_NOTIFIED: u64 = 0x0f00_0501;
const TPM2_FFA_MANAGE_LOCALITY: u64 = 0x1f00_0001;

// ---------------------------------------------------------------------------
// TPM Service Status Codes (returned in Arg0 / register x4 of response)
// ---------------------------------------------------------------------------
const TPM2_FFA_SUCCESS_OK: u64 = 0x0500_0001;
const TPM2_FFA_SUCCESS_OK_RESULTS: u64 = 0x0500_0002;
const TPM2_FFA_NO_FUNC: u64 = 0x8e00_0001;
const TPM2_FFA_NOT_SUP: u64 = 0x8e00_0002;
const TPM2_FFA_INV_ARG: u64 = 0x8e00_0005;
const TPM2_FFA_INV_CRB_CTRL_DATA: u64 = 0x8e00_0006;
const TPM2_FFA_DENIED: u64 = 0x8e00_000a;

// ---------------------------------------------------------------------------
// Start function qualifiers (placed in Arg1 / register x5)
// ---------------------------------------------------------------------------
const START_QUALIFIER_COMMAND: u64 = 0x0;
const START_QUALIFIER_LOCALITY: u64 = 0x1;

// ---------------------------------------------------------------------------
// ManageLocality operations (placed in Arg1 / register x5)
// ---------------------------------------------------------------------------
const MANAGE_LOCALITY_OPEN: u64 = 0x0;
const MANAGE_LOCALITY_CLOSE: u64 = 0x1;

// ---------------------------------------------------------------------------
// Test-only opcode: write CRB register bits in the SP's internal CRB
// ---------------------------------------------------------------------------
const TPM2_FFA_TEST_WRITE_CRB: u64 = 0xDE00_0001;

// TestWriteCrb operations (placed in Arg1 / register x5)
const TEST_CRB_SET_REQUEST_ACCESS: u64 = 0;
const TEST_CRB_SET_RELINQUISH: u64 = 1;
const TEST_CRB_SET_CMD_READY: u64 = 2;
const TEST_CRB_SET_GO_IDLE: u64 = 3;
#[allow(dead_code)]
const TEST_CRB_SET_START: u64 = 4;

/// A status-only case: send `(opcode, function, locality)` and assert the
/// response status equals `expected`. `expected` is an explicit constant per
/// case, never derived from the request.
struct StatusCase {
    name: &'static str,
    opcode: u64,
    function: u64,
    locality: u64,
    expected: u64,
}

/// Build a TPM request payload from (opcode, function, locality).
///
/// The TPM service reads three registers from the FF-A payload:
///   Arg0 (x4) = opcode
///   Arg1 (x5) = function qualifier
///   Arg2 (x6) = locality
fn tpm_request(opcode: u64, function: u64, locality: u64) -> DirectMessagePayload {
    let bytes: alloc::vec::Vec<u8> = opcode
        .to_le_bytes()
        .into_iter()
        .chain(function.to_le_bytes())
        .chain(locality.to_le_bytes())
        .chain(core::iter::repeat_n(0u8, 14 * 8 - 24))
        .collect();
    DirectMessagePayload::from_iter(bytes)
}

/// Send a fully-built TPM `payload` and return the response body, failing
/// `test_name` with TPM's distinct diagnostic when the SP's response FID is
/// unexpected.
fn tpm_send(
    ctx: &mut E2eContext,
    test_name: &str,
    payload: &DirectMessagePayload,
) -> Option<DirectMessagePayload> {
    ctx.send_payload(test_name, &TPM_UUID, payload, "unexpected response FID")
}

/// Run status-only cases in order, asserting each response status. Preserves
/// ordered state boundaries: callers pass one slice per state group.
fn run_status_cases(ctx: &mut E2eContext, cases: &[StatusCase]) {
    for case in cases {
        let payload = tpm_request(case.opcode, case.function, case.locality);
        let Some(resp) = tpm_send(ctx, case.name, &payload) else {
            continue;
        };
        let status = resp.u64_at(0);
        log::info!("  {}: status={:#x}", case.name, status);
        if status == case.expected {
            ctx.pass(case.name);
        } else {
            ctx.fail(case.name, "unexpected status");
        }
    }
}

// Stateless cases (don't depend on or change locality state).
const STATELESS_CASES: &[StatusCase] = &[
    // GetFeatureInfo is not implemented — should return NOT_SUP.
    StatusCase {
        name: "tpm_get_feature_info",
        opcode: TPM2_FFA_GET_FEATURE_INFO,
        function: 0,
        locality: 0,
        expected: TPM2_FFA_NOT_SUP,
    },
    // An unknown opcode should return NO_FUNC.
    StatusCase {
        name: "tpm_invalid_opcode",
        opcode: 0xDEAD_BEEF,
        function: 0,
        locality: 0,
        expected: TPM2_FFA_NO_FUNC,
    },
    // Start(COMMAND) on closed locality 2 → DENIED (per DEN0138, DENIED is
    // for "TPM has disabled requests at this locality"). Localities 2..=4
    // are closed by default after SP init; localities 0..=1 are open.
    StatusCase {
        name: "tpm_start_closed_locality",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_COMMAND,
        locality: 2,
        expected: TPM2_FFA_DENIED,
    },
    // Start with out-of-range locality (>= 5) → INV_ARG.
    StatusCase {
        name: "tpm_start_invalid_locality",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_COMMAND,
        locality: 5,
        expected: TPM2_FFA_INV_ARG,
    },
    // Start(LOCALITY) on closed locality 2 → DENIED (same reasoning as above).
    StatusCase {
        name: "tpm_start_locality_qualifier_closed",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_LOCALITY,
        locality: 2,
        expected: TPM2_FFA_DENIED,
    },
];

// These share one SP instance and run in order, forming a
// register → unregister → finish sequence.
const NOTIFICATION_SEQUENCE: &[StatusCase] = &[
    // RegisterForNotification (no prior registration) → OK.
    StatusCase {
        name: "tpm_register_for_notification",
        opcode: TPM2_FFA_REGISTER_FOR_NOTIFICATION,
        function: 0,
        locality: 0,
        expected: TPM2_FFA_SUCCESS_OK,
    },
    // UnregisterForNotification (registered by the case above) → OK.
    StatusCase {
        name: "tpm_unregister_for_notification",
        opcode: TPM2_FFA_UNREGISTER_FOR_NOTIFICATION,
        function: 0,
        locality: 0,
        expected: TPM2_FFA_SUCCESS_OK,
    },
    // FinishNotified (no active registration after the unregister above) →
    // DENIED.
    StatusCase {
        name: "tpm_finish_notified",
        opcode: TPM2_FFA_FINISH_NOTIFIED,
        function: 0,
        locality: 0,
        expected: TPM2_FFA_DENIED,
    },
];

// ManageLocality tests (SP built with test-bypass-locality-check).
const MANAGE_LOCALITY_CASES: &[StatusCase] = &[
    // ManageLocality(OPEN, locality=0) should succeed.
    StatusCase {
        name: "tpm_manage_locality_open",
        opcode: TPM2_FFA_MANAGE_LOCALITY,
        function: MANAGE_LOCALITY_OPEN,
        locality: 0,
        expected: TPM2_FFA_SUCCESS_OK,
    },
    // ManageLocality with invalid operation (not OPEN or CLOSE) → INV_ARG.
    StatusCase {
        name: "tpm_manage_locality_invalid_op",
        opcode: TPM2_FFA_MANAGE_LOCALITY,
        function: 0x2,
        locality: 0,
        expected: TPM2_FFA_INV_ARG,
    },
];

// Cases requiring open locality (locality 0 was opened above).
const OPEN_LOCALITY_CASES: &[StatusCase] = &[
    // Start(COMMAND) on open locality with no command queued in CRB
    // → INV_CRB_CTRL_DATA (per DEN0138, the CRB control data is invalid
    // because no operation is requested). Note: the test name is historical;
    // in the live SP+EC scenario, active_locality is set to 0 by the EC's
    // earlier Start(LOCALITY,0) traffic, so this exercises the "no command
    // queued" path rather than the "locality mismatch" branch.
    StatusCase {
        name: "tpm_start_command_locality_mismatch",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_COMMAND,
        locality: 0,
        expected: TPM2_FFA_INV_CRB_CTRL_DATA,
    },
    // Start with invalid function qualifier → INV_ARG.
    StatusCase {
        name: "tpm_start_invalid_function",
        opcode: TPM2_FFA_START,
        function: 0x2,
        locality: 0,
        expected: TPM2_FFA_INV_ARG,
    },
    // Start(LOCALITY) with no CRB request/relinquish bits → INV_CRB_CTRL_DATA
    // (per DEN0138, the locality_control register has no operation requested).
    StatusCase {
        name: "tpm_start_locality_no_crb_bits",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_LOCALITY,
        locality: 0,
        expected: TPM2_FFA_INV_CRB_CTRL_DATA,
    },
    // Start(COMMAND) with no command queued in CRB → INV_CRB_CTRL_DATA.
    // Same code path as tpm_start_command_locality_mismatch above.
    StatusCase {
        name: "tpm_start_command_idle_no_bits",
        opcode: TPM2_FFA_START,
        function: START_QUALIFIER_COMMAND,
        locality: 0,
        expected: TPM2_FFA_INV_CRB_CTRL_DATA,
    },
];

// Close locality.
const LOCALITY_CLOSE_CASE: &[StatusCase] = &[StatusCase {
    name: "tpm_manage_locality_close",
    opcode: TPM2_FFA_MANAGE_LOCALITY,
    function: MANAGE_LOCALITY_CLOSE,
    locality: 0,
    expected: TPM2_FFA_SUCCESS_OK,
}];

#[entry]
fn main() -> Status {
    run_tests(run_tpm_tests)
}

fn run_tpm_tests(ctx: &mut E2eContext) {
    // Stateless tests (don't depend on or change locality state).
    test_get_interface_version(ctx);
    run_status_cases(ctx, STATELESS_CASES);

    // register → unregister → finish sequence.
    run_status_cases(ctx, NOTIFICATION_SEQUENCE);

    // ManageLocality open + invalid op.
    run_status_cases(ctx, MANAGE_LOCALITY_CASES);

    // Cases requiring open locality (locality 0 was opened above).
    run_status_cases(ctx, OPEN_LOCALITY_CASES);

    // CRB state machine tests — exercises handle_command + tpm_sst.
    // These use the test-only TestWriteCrb opcode to set internal CRB bits,
    // then trigger the state machine via Start(LOCALITY/COMMAND).
    test_crb_state_machine(ctx);

    // Close locality.
    run_status_cases(ctx, LOCALITY_CLOSE_CASE);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Verify GetInterfaceVersion returns success and the correct v1.0 version.
fn test_get_interface_version(ctx: &mut E2eContext) {
    let payload = tpm_request(TPM2_FFA_GET_INTERFACE_VERSION, 0, 0);
    let Some(resp) = tpm_send(ctx, "tpm_get_interface_version", &payload) else {
        return;
    };
    let status = resp.u64_at(0);
    let version = resp.u64_at(8);

    log::info!(
        "  get_interface_version: status={:#x}, version={:#x}",
        status,
        version
    );

    if status != TPM2_FFA_SUCCESS_OK_RESULTS {
        ctx.fail("tpm_get_interface_version", "unexpected status");
        return;
    }

    // Version should be (major << 16) | minor = (1 << 16) | 0 = 0x10000
    if version != 0x1_0000 {
        ctx.fail(
            "tpm_get_interface_version",
            "expected version 1.0 (0x10000)",
        );
        return;
    }

    ctx.pass("tpm_get_interface_version");
}

/// Helper: send TestWriteCrb and assert OK.
fn test_write_crb(ctx: &mut E2eContext, test_name: &str, operation: u64, locality: u64) -> bool {
    let payload = tpm_request(TPM2_FFA_TEST_WRITE_CRB, operation, locality);
    let Some(resp) = tpm_send(ctx, test_name, &payload) else {
        return false;
    };
    if resp.u64_at(0) != TPM2_FFA_SUCCESS_OK {
        ctx.fail(test_name, "TestWriteCrb failed");
        return false;
    }
    true
}

/// Exercises the full CRB state machine through handle_command and
/// handle_locality_request, driving the SST layer (tpm_sst.rs):
///
///   1. Set REQUEST_ACCESS → Start(LOCALITY) → sst.locality_request → active=0
///   2. Set CMD_READY → Start(COMMAND) → handle_command IDLE→READY (sst.cmd_ready)
///   3. Set GO_IDLE → Start(COMMAND) → handle_command READY→IDLE (sst.go_idle)
///   4. Set RELINQUISH → Start(LOCALITY) → sst.locality_relinquish → active=NONE
fn test_crb_state_machine(ctx: &mut E2eContext) {
    // -- Step 1: Request locality 0 via sst.locality_request ---------------
    if !test_write_crb(ctx, "tpm_crb_sm", TEST_CRB_SET_REQUEST_ACCESS, 0) {
        return;
    }
    let payload = tpm_request(TPM2_FFA_START, START_QUALIFIER_LOCALITY, 0);
    let Some(resp) = tpm_send(ctx, "tpm_crb_locality_request", &payload) else {
        return;
    };
    let status = resp.u64_at(0);
    log::info!("  crb_locality_request: status={:#x}", status);
    if status != TPM2_FFA_SUCCESS_OK {
        ctx.fail(
            "tpm_crb_locality_request",
            "expected OK from locality request",
        );
        return;
    }
    ctx.pass("tpm_crb_locality_request");

    // -- Step 2: IDLE → READY via sst.cmd_ready ----------------------------
    if !test_write_crb(ctx, "tpm_crb_sm", TEST_CRB_SET_CMD_READY, 0) {
        return;
    }
    let payload = tpm_request(TPM2_FFA_START, START_QUALIFIER_COMMAND, 0);
    let Some(resp) = tpm_send(ctx, "tpm_crb_idle_to_ready", &payload) else {
        return;
    };
    let status = resp.u64_at(0);
    log::info!("  crb_idle_to_ready: status={:#x}", status);
    if status != TPM2_FFA_SUCCESS_OK {
        ctx.fail("tpm_crb_idle_to_ready", "expected OK for IDLE→READY");
        return;
    }
    ctx.pass("tpm_crb_idle_to_ready");

    // -- Step 3: READY → IDLE via sst.go_idle ------------------------------
    if !test_write_crb(ctx, "tpm_crb_sm", TEST_CRB_SET_GO_IDLE, 0) {
        return;
    }
    let payload = tpm_request(TPM2_FFA_START, START_QUALIFIER_COMMAND, 0);
    let Some(resp) = tpm_send(ctx, "tpm_crb_ready_to_idle", &payload) else {
        return;
    };
    let status = resp.u64_at(0);
    log::info!("  crb_ready_to_idle: status={:#x}", status);
    if status != TPM2_FFA_SUCCESS_OK {
        ctx.fail("tpm_crb_ready_to_idle", "expected OK for READY→IDLE");
        return;
    }
    ctx.pass("tpm_crb_ready_to_idle");

    // -- Step 4: Relinquish locality 0 via sst.locality_relinquish ---------
    if !test_write_crb(ctx, "tpm_crb_sm", TEST_CRB_SET_RELINQUISH, 0) {
        return;
    }
    let payload = tpm_request(TPM2_FFA_START, START_QUALIFIER_LOCALITY, 0);
    let Some(resp) = tpm_send(ctx, "tpm_crb_locality_relinquish", &payload) else {
        return;
    };
    let status = resp.u64_at(0);
    log::info!("  crb_locality_relinquish: status={:#x}", status);
    if status != TPM2_FFA_SUCCESS_OK {
        ctx.fail(
            "tpm_crb_locality_relinquish",
            "expected OK from locality relinquish",
        );
        return;
    }
    ctx.pass("tpm_crb_locality_relinquish");
}
