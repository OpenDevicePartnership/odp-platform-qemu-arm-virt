/** @file
  Contains root level name space objects for the platform
  Copyright (c) 2025, MediaTek Inc. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent

  Copyright (c) Microsoft Corporation. All rights reserved.

**/

#define FFA_PAYLOAD_START_INDEX_BYTES 32
#define FFA_PAYLOAD_START_INDEX_BITS 256

Device(RTC)
{
    Name (_HID, "ACPI000E")  // _HID: Hardware ID
    Name (_UID, 0)  // _UID: Unique ID

    // 144 bytes = 18 64-bit registers, which is the be the number of registers that FF-A uses to pass stuff to the secure partition.
    //
    Name(CBUF, Buffer(144){}) // Buffer used to send/receive data to/from EC
    CreateDWordField(CBUF, 0, CRES)   // Out - result for request/response
    CreateField(CBUF, 128, 128, UUID) // In  - UUID of service being interacted with
    CreateByteField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES, CMDD)   // In  - Command ID
    // For input, the expected contents of the buffer after byte 33 are command-specific and should be defined in the method.
    // For output, the result will start at byte 32 if CRES is zero, and the contents will be undefined if CRES is nonzero.


// TODO figure out if this applies - it's not part of the TAD spec but may be involved in triggering wake from sleep? Surface was doing it, at any rate
// //   Name (PRWP, Package (0x02)
// //   {
// //     Zero,
// //     Zero
// //   })

// //   Method (GPRW, 2, NotSerialized)
// //   {
// //     PRWP [Zero] = Arg0
// //     Local0 = (SS4 << 0x04)
// //     If (((One << Arg1) & Local0))
// //     {
// //       PRWP [One] = Arg1
// //       Return (PRWP)
// //     }
// //     Else
// //     {
// //       Local0 = Local0 >> One
// //       FindSetLeftBit (Local0, PRWP [One])
// //       Return (PRWP)
// //     }
// //   }

// //   Method (_PRW, 0, NotSerialized)  // _PRW: Power Resources for Wake
// //   {
// //     Return (GPRW (0x6D, 0x04))
// //   }

    // Call an EC method over FF-A that takes no arguments and returns a u32 result.
    //
    // Arguments:
    //   Arg0: u32 - command ID
    //   Arg1: u32 - return value in case of failure
    // Returns:
    //   u32 - return value from EC, or Arg1 in case of failure
    //
    Method(EC_0, 2, Serialized) {

        // Populate request buffer
        //
        UUID = ToUUID("23ea63ed-b593-46ea-b027-8924df88e92f")
        CMDD = Arg0

        // Call the EC via FF-A
        //
        CBUF = (\_SB_.FFA0.FFAC = CBUF)
        If (CRES != 0x0) {
            Return (Arg1) // Communication failure
        }

        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES, ECRS) // Out: EC result code
        Return(ECRS)
    }

    // Call an EC method over FF-A that takes a single u32 argument and returns a u32 result.
    //
    // Arguments:
    //   Arg0: u32 - command ID
    //   Arg1: u32 - return value in case of failure
    //   Arg2: u32 - command argument to pass through to the EC
    // Returns:
    //   u32 - return value from EC, or Arg1 in case of failure
    //
    Method(EC_1, 3, Serialized) {

        // Populate request buffer
        //
        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES + 1, EAR1) // In: argument to EC
        EAR1 = Arg2

        UUID = ToUUID("23ea63ed-b593-46ea-b027-8924df88e92f")
        CMDD = Arg0

        // Call the EC via FF-A
        //
        CBUF = (\_SB_.FFA0.FFAC = CBUF)
        If (CRES != 0x0) {
            Return (Arg1) // Communication failure
        }

        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES, ECRS) // Out: EC result code
        Return(ECRS)
    }

    // Call an EC method over FF-A that takes two u32 arguments and returns a u32 result.
    //
    // Arguments:
    //   Arg0: u32 - command ID
    //   Arg1: u32 - return value in case of failure
    //   Arg2: u32 - first command argument to pass through to the EC
    //   Arg3: u32 - second command argument to pass through to the EC
    // Returns:
    //   u32 - return value from EC, or Arg1 in case of failure
    //
    Method(EC_2, 4, Serialized, 0) {

        // Populate request buffer
        //
        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES + 1,     EAR1) // In: argument 1 to EC
        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES + 1 + 4, EAR2) // In: argument 2 to EC
        EAR1 = Arg2
        EAR2 = Arg3

        UUID = ToUUID("23ea63ed-b593-46ea-b027-8924df88e92f")
        CMDD = Arg0

        // Call the EC via FF-A
        //
        CBUF = (\_SB_.FFA0.FFAC = CBUF)
        If(CRES != 0x0) {
            Return (Arg1) // Communication failure
        }

        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES, ECRS) // Out: EC result code
        Return(ECRS)
    }

    //
    // EC_TAS_GET_GCP - Get capabilities
    //  Arguments: None
    //  Returns:
    //    A u32 bitfield representing the capabilities of the timer and wake functions.
    //
    //    This function has no way to express failure, so if the FF-A call fails, we fall back to a hardcoded
    //    value that represents the capabilities that the platform is expected to have.
    //
    //
    Method (_GCP, 0, Serialized)
    {
        // 1: AC wake implemented
        // 1: DC wake implemented
        // 1: Get/set real time implemented
        // 0: Real time accuracy is to seconds
        // 1: Wake supported from S4 on AC
        // 1: Wake supported from S5 on AC
        // 1: Wake supported from S4 on DC
        // 0: Wake not supported from S5 on DC // TODO @Surface is this intentional? It could be, but could also be an off-by-one error when manually computing the bitfield
        Return(EC_0(0x1, 0xF7))
    }

    //
    // EC_TAS_GET_GRT - Get real time
    //   Arguments: None
    //   Returns:
    //     Buffer containing ACPI time structure: Valid = 1 on success, Valid = 0 on failure.
    //
    Method (_GRT, 0, Serialized)
    {
        // ACPI time structure to return - we only need to fill in the 'valid' field, everything else
        // comes from the EC, and the 'valid' field is set to 1 by the EC if it was successful.
        //
        Name(RBUF, Buffer (0x10){})
        // Year: u16
        // Month: u8,
        // Day: u8,
        // Hour: u8,
        // Minute: u8,
        // Second: u8,
        CreateByteField(RBUF, 0x07, ISOK) // u8: valid
        // milliseconds: u16,
        // timezone: u16,
        // daylight: u8,
        // padding: u8[3]

        ISOK = Zero

        // Populate request buffer
        //
        UUID = ToUUID("23ea63ed-b593-46ea-b027-8924df88e92f")
        CMDD = 0x2 // EC_TAS_GET_GRT

        // Call the EC via FF-A
        //
        CBUF = (\_SB_.FFA0.FFAC = CBUF)
        If(CRES != 0x0) {
            Return (RBUF) // Communication failure
        }

        // Copy return payload to its own buffer for return.
        // The EC will set ISOK in that payload to 1 if it was successful.
        //
        CreateField(RBUF, 0,                            128, RDAT) // Entire return buffer
        CreateField(CBUF, FFA_PAYLOAD_START_INDEX_BITS, 128, CDAT) // Payload section in comms buffer

        RDAT = CDAT
        Return (RBUF)
    }

    //
    // EC_TAS_SET_SRT - Set real time
    //   Arguments:
    //     Arg0: Buffer containing ACPI time structure
    //   Returns:
    //     u32: 0 on success, 0xFFFFFFFF on failure.
    //
    Method (_SRT, 1, Serialized)
    {
        // Populate request buffer
        //
        UUID = ToUUID("23ea63ed-b593-46ea-b027-8924df88e92f")
        CMDD = 0x3 // EC_TAS_SET_SRT
        CreateField(CBUF, FFA_PAYLOAD_START_INDEX_BITS + 8, 128, TIME)
        TIME = Arg0

        // Call the EC via FF-A
        //
        CBUF = (\_SB_.FFA0.FFAC = CBUF)
        If (CRES != 0x0) {
            Return (0xFFFFFFFF) // Communication failure
        }

        CreateDWordField(CBUF, FFA_PAYLOAD_START_INDEX_BYTES, SRTS)
        If (SRTS != Zero) {
            Return (0xFFFFFFFF)
        }
        Return (Zero)
    }

    //
    // EC_TAS_GET_GWS - Get wake state
    // Arguments:
    //   Arg0(u32): Timer type (0: AC, 1: DC)
    // Returns: 
    //   Bitfield (u32):
    //     Bit 0: 1 if timer expired, 0 if not.
    //     Bit 1: 1 if timer caused a platform wake, 0 if not.
    //
    //    This function's contract in the ACPI spec doesn't have a facility for expressing failure,
    //    but we can probably infer that if it failed, the timer hardware isn't working  and thus
    //    the timer hasn't expired and didn't cause a wake, so we return 0 on failure.
    //
    Method (_GWS, 1, Serialized)
    {
        Return(EC_1(0x4, Zero, Arg0))
    }

    //
    // EC_TAS_SET_CWS - Clear wake state
    // Arguments:
    //   Arg0 (u32): Timer type (0: AC, 1: DC)
    // Returns:
    //   u32: 0 on success, 1 on failure.
    //
    Method (_CWS, 1, Serialized)
    {
        If (EC_1(0x5, One, Arg0) != Zero) {
            Return (One)
        }
        Return (Zero)
    }

    //
    // EC_TAS_SET_STV - Set timer value
    // Arguments:
    //   Arg0 (u32): Timer type (0: AC, 1: DC)
    //   Arg1 (u32): Timer value in seconds
    // Returns:
    //   u32: 0 on success, 1 on failure.
    //
    Method (_STV, 2, NotSerialized)
    {
        If (EC_2(0x6, One, Arg0, Arg1) != Zero) {
            Return (One)
        }
        Return (Zero)
    }

    //
    // EC_TAS_GET_TIV - Get timer value
    // Arguments:
    //  Arg0 (u32): Timer type (0: AC, 1: DC)
    // Returns:
    //  u32: Timer value in seconds, or 0xFFFFFFFF if timer is disabled.
    //
    //  This function's contract in the ACPI spec doesn't have a facility for expressing failure,
    //  but we can probably infer that if it failed, the timer hardware isn't working  and thus
    //  the timer wasn't successfully enabled, so we return 0xFFFFFFFF on failure.
    //
    Method (_TIV, 1, Serialized)
    {
        Return(EC_1(0x7, 0xFFFFFFFF, Arg0))
    }

    //
    // EC_TAS_SET_STP - Set timer policy
    // Arguments:
    //  Arg0 (u32): Timer type (0: AC, 1: DC)
    //  Arg1 (u32): Timer policy in seconds (number of seconds to wait while on the specified power source before generating a
    //                                       wake event if the timer for that wake event expired while the other power source
    //                                       was active)
    // Returns:
    //  u32: 0 on success, 1 on failure.
    //
    Method (_STP, 2, NotSerialized)
    {
        If (EC_2(0x8, One, Arg0, Arg1) != Zero) {
            Return (One)
        }
        Return (Zero)
    }

    //
    // EC_TAS_GET_TIP - Get timer policy
    // Arguments:
    //  Arg0 (u32): Timer type (0: AC, 1: DC)
    // Returns:
    //  u32: Timer policy in seconds, or 0xFFFFFFFF if the timer policy will never trigger a wake.
    //
    //  This function's contract in the ACPI spec doesn't have a facility for expressing failure,
    //  but we can probably infer that if it failed, the timer hardware isn't working and thus
    //  the timer policy wasn't successfully enabled, so we return 0xFFFFFFFF on failure.
    //
    Method (_TIP, 1, Serialized)
    {
        Return(EC_1(0x9, 0xFFFFFFFF, Arg0))
    }
}
