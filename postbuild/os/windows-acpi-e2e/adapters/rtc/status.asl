DefinitionBlock ("", "SSDT", 2, "ODP", "RTCSTAT", 1)
{
    Scope (\_SB)
    {
        Device (FFA0)
        {
            Name (_HID, "ODP0001")
            // Echo requests: framework status is zero, command becomes nonzero SP status.
            Name (FFAC, Buffer (144) {})
        }
        #include "rtc.asl"
    }
    Method (MAIN, 0)
    {
        If (\_SB.RTC._SRT (Buffer (16) {}) != 0xFFFFFFFF) {
            Return (One)
        }
        If (\_SB.RTC._CWS (Zero) != One) {
            Return (One)
        }
        If (\_SB.RTC._STV (Zero, One) != One) {
            Return (One)
        }
        If (\_SB.RTC._STP (Zero, One) != One) {
            Return (One)
        }
        Return (Zero)
    }
}
