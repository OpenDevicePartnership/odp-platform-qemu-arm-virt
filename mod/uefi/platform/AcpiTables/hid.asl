// This sets up HIDI2C support for the virtual QEMU EC.
//
// Quick summary:
// -EC I2C address: 0x2C
// -EC HID descriptor register address: 0x1

//
// HID-over-I2C peripheral hanging off the QEMUI2C controller
//
Device (HID0)
{
    //
    // Vendor-specific HID for your device
    // Use your own 4-char vendor + 4-hex device ID
    //
    Name (_HID, "QEMU0002")
    Name (_UID, 0)

    //
    // Required compatible ID for HID-over-I2C
    //
    Name (_CID, "PNP0C50")

    //
    // Current Resource Settings:
    //  - I2C serial bus connection to the controller above
    //  - GPIO interrupt line for HID attention/events
    //
    Name (_CRS, ResourceTemplate ()
    {
        I2CSerialBus(
            0x002C,                  // 7-bit I2C slave address (example: 0x2C)
            ControllerInitiated,     // Usually controller initiated
            400000,                  // Bus speed in Hz (example: 400 kHz)
            AddressingMode7Bit,
            "\\_SB.I2C0",            // ACPI path to QemuI2C controller
            0x00,                    // ResourceSourceIndex
            ResourceConsumer,
            ,
        )

        GpioInt(
            Level,
            ActiveLow,               // Adjust to your hardware
            Exclusive,
            PullUp,                  // Adjust to your board design
            0x0000,
            "\\_SB.GPO0",           // Exposed by QEMU (ARMH0061)
            0x00,
            ResourceConsumer,
            ,
        )
        {
            0x000                   // PL061 pin 0 — wired to EC GPIO0 (chardev id gpio0)
        }
    })

    //
    // Required HID-over-I2C _DSM
    // Function 1 returns the HID descriptor register offset
    //
    Method (_DSM, 4, NotSerialized)
    {
        If (LEqual (Arg0, ToUUID ("3CDFF6F7-4267-4555-AD05-B30A3D8938DE")))
        {
            Switch (ToInteger (Arg2))
            {
                Case (0)
                {
                    //
                    // Query supported functions bitmap.
                    // Bit0 = function 0 supported, Bit1 = function 1 supported
                    //
                    Return (Buffer() { 0x03 })
                }

                Case (1)
                {
                    //
                    // HID descriptor register offset in the I2C target.
                    // Must match the EC's RegisterFile::hid_desc_reg
                    // (embedded-services hid module default = 0x0001).
                    //
                    Return (0x0001)
                }
            }
        }

        Return (Buffer() { 0x00 })
    }
}
