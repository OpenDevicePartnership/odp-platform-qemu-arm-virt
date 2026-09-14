#[cfg(any(windows, test))]
use ec_test_lib::{
    UcsiSource,
    ucsi::{PowerRole, UcsiSnapshot},
};

#[cfg(windows)]
fn main() -> Result<(), String> {
    println!("{}", smoke(&ec_test_lib::acpi::Acpi::new(0))?);
    Ok(())
}

#[cfg(not(windows))]
fn main() -> Result<(), &'static str> {
    Err("UCSI ACPI smoke runs only on Windows")
}

#[cfg(any(windows, test))]
fn smoke(source: &impl UcsiSource) -> Result<&'static str, String> {
    let snapshot = source
        .get_snapshot(1)
        .map_err(|error| format!("get_snapshot(1): {error}"))?;

    println!("UCSI VERSION: {:#06x}", snapshot.version);
    println!("UCSI GET_CAPABILITY: {:?}", snapshot.capability);
    println!(
        "UCSI GET_CONNECTOR_CAPABILITY(1): {:?}",
        snapshot.connector_capability
    );
    println!(
        "UCSI GET_CONNECTOR_STATUS(1): {:?}",
        snapshot.connector_status
    );

    validate_snapshot(&snapshot)?;
    Ok("UCSI SUMMARY: 4 passed, 0 failed")
}

#[cfg(any(windows, test))]
fn validate_snapshot(snapshot: &UcsiSnapshot) -> Result<(), String> {
    if snapshot.version != 0x0120 {
        return Err(format!(
            "VERSION: expected 0x0120, got {:#06x}",
            snapshot.version
        ));
    }

    let capability = &snapshot.capability;
    if capability.num_connectors != 1
        || !capability.attributes.usb_power_delivery()
        || capability.bcd_usb_pd_spec != 0x0300
    {
        return Err(format!(
            "GET_CAPABILITY: expected one connector, USB PD, BCD PD 0x0300; got {capability:?}"
        ));
    }

    let connector = &snapshot.connector_capability;
    let modes = connector.operation_mode();
    if !modes.drp()
        || !modes.usb2()
        || !modes.usb3()
        || !connector.provider()
        || !connector.consumer()
    {
        return Err(format!(
            "GET_CONNECTOR_CAPABILITY(1): expected DRP, USB2, USB3, provider, consumer; got {connector:?}"
        ));
    }

    let status = &snapshot.connector_status;
    if !status.connect_status
        || status.status.as_ref().is_none_or(|connected| {
            !connected.partner_flags.usb() || connected.power_direction != PowerRole::Sink
        })
    {
        return Err(format!(
            "GET_CONNECTOR_STATUS(1): expected connected USB partner with sink power direction; got {status:?}"
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ec_test_lib::{ErrorKind, ErrorType, mock::Mock};
    use std::cell::RefCell;

    fn snapshot() -> UcsiSnapshot {
        Mock::new().get_snapshot(1).expect("shared mock snapshot")
    }

    fn assert_rejected(snapshot: UcsiSnapshot, group: &str) {
        let source = TestSource(RefCell::new(Some(Ok(snapshot))));
        let error = smoke(&source).expect_err("invalid snapshot must fail");
        assert!(error.contains(group), "missing {group} diagnostic: {error}");
    }

    #[test]
    fn accepts_shared_mock_snapshot() {
        assert_eq!(validate_snapshot(&snapshot()), Ok(()));
    }

    #[test]
    fn complete_success_returns_exact_summary() {
        assert_eq!(smoke(&Mock::new()), Ok("UCSI SUMMARY: 4 passed, 0 failed"));
    }

    #[test]
    fn rejects_wrong_version() {
        let mut snapshot = snapshot();
        snapshot.version = 0x0110;
        assert_rejected(snapshot, "VERSION");
    }

    #[test]
    fn rejects_connector_count_other_than_one() {
        for count in [0, 2] {
            let mut snapshot = snapshot();
            snapshot.capability.num_connectors = count;
            assert_rejected(snapshot, "GET_CAPABILITY");
        }
    }

    #[test]
    fn rejects_missing_usb_pd_support() {
        let mut snapshot = snapshot();
        snapshot.capability.attributes.set_usb_power_delivery(false);
        assert_rejected(snapshot, "GET_CAPABILITY");
    }

    #[test]
    fn rejects_wrong_pd_revision() {
        let mut snapshot = snapshot();
        snapshot.capability.bcd_usb_pd_spec = 0x0200;
        assert_rejected(snapshot, "GET_CAPABILITY");
    }

    #[test]
    fn rejects_missing_drp() {
        let mut snapshot = snapshot();
        let mut modes = snapshot.connector_capability.operation_mode();
        modes.set_drp(false);
        snapshot.connector_capability.set_operation_mode(modes);
        assert_rejected(snapshot, "GET_CONNECTOR_CAPABILITY(1)");
    }

    #[test]
    fn rejects_missing_usb2() {
        let mut snapshot = snapshot();
        let mut modes = snapshot.connector_capability.operation_mode();
        modes.set_usb2(false);
        snapshot.connector_capability.set_operation_mode(modes);
        assert_rejected(snapshot, "GET_CONNECTOR_CAPABILITY(1)");
    }

    #[test]
    fn rejects_missing_usb3() {
        let mut snapshot = snapshot();
        let mut modes = snapshot.connector_capability.operation_mode();
        modes.set_usb3(false);
        snapshot.connector_capability.set_operation_mode(modes);
        assert_rejected(snapshot, "GET_CONNECTOR_CAPABILITY(1)");
    }

    #[test]
    fn rejects_missing_provider() {
        let mut snapshot = snapshot();
        snapshot.connector_capability.set_provider(false);
        assert_rejected(snapshot, "GET_CONNECTOR_CAPABILITY(1)");
    }

    #[test]
    fn rejects_missing_consumer() {
        let mut snapshot = snapshot();
        snapshot.connector_capability.set_consumer(false);
        assert_rejected(snapshot, "GET_CONNECTOR_CAPABILITY(1)");
    }

    #[test]
    fn rejects_missing_connected_status() {
        let mut snapshot = snapshot();
        snapshot.connector_status.status = None;
        assert_rejected(snapshot, "GET_CONNECTOR_STATUS(1)");
    }

    #[test]
    fn rejects_disconnected_connector() {
        let mut snapshot = snapshot();
        snapshot.connector_status.connect_status = false;
        assert_rejected(snapshot, "GET_CONNECTOR_STATUS(1)");
    }

    #[test]
    fn rejects_non_usb_partner() {
        let mut snapshot = snapshot();
        snapshot
            .connector_status
            .status
            .as_mut()
            .unwrap()
            .partner_flags
            .set_usb(false);
        assert_rejected(snapshot, "GET_CONNECTOR_STATUS(1)");
    }

    #[test]
    fn rejects_non_sink_power_role() {
        let mut snapshot = snapshot();
        snapshot
            .connector_status
            .status
            .as_mut()
            .unwrap()
            .power_direction = PowerRole::Source;
        assert_rejected(snapshot, "GET_CONNECTOR_STATUS(1)");
    }

    struct TestSource(RefCell<Option<Result<UcsiSnapshot, ErrorKind>>>);

    impl ErrorType for TestSource {
        type Error = ErrorKind;
    }

    impl UcsiSource for TestSource {
        fn get_snapshot(&self, connector: u8) -> Result<UcsiSnapshot, Self::Error> {
            assert_eq!(connector, 1);
            self.0.borrow_mut().take().expect("exactly one snapshot")
        }
    }

    #[test]
    fn source_error_is_not_a_success_summary() {
        let source = TestSource(RefCell::new(Some(Err(ErrorKind::Io))));
        assert_eq!(smoke(&source), Err("get_snapshot(1): I/O error".into()));
    }

    #[test]
    fn acquires_one_snapshot_for_connector_one() {
        let source = TestSource(RefCell::new(Some(Ok(snapshot()))));
        assert!(smoke(&source).is_ok());
        assert!(source.0.borrow().is_none());
    }
}
