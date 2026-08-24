/** @file
  Contains root level name space objects for the platform

  Copyright (c) 2024, MediaTek Inc. All rights reserved.<BR>
  SPDX-License-Identifier: BSD-2-Clause-Patent

**/

DefinitionBlock ("SsdtEc.aml", "SSDT", 2, "QEMUAR", "EC      ", 1) {

  Scope(\_SB)
  {
    #include "ffa.asl"
    #include "hid.asl"
    //#include "battery.asl"
    #include "thermal.asl"
    //#include "rtc.asl"

  //
  // EC Test interface to load KMDF driver and map methods
  //
  Device (ECT0) {
    Name (_HID, "ETST0001")
    Name (_UID, 0x0)
    Name (_CCA, 0x0)

    /*********************** General Methods **********************************/
    Name (NEVT, 0x1234)

    Name(BUFF, Buffer(144){})   // Create buffer for send/recv data
  
    Method(ECHO, 0x1, NotSerialized) {
      Return(Arg0) // Echo back input
    }

    Method (RTMP, 0x0, NotSerialized) {
      Return (\_SB.SKIN._TMP ())
    }

    Method (_STA) {
      Return (0xf)
    }

  } // Device (ECT0)

  }

}
