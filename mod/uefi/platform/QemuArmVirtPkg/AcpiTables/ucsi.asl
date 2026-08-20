// UCSI FF-A backend: owns the request/response envelope and the serialized
// command method routed over the FF-A doorbell (FFA0.FFAC). The EC test
// endpoint ECT0.USND forwards to \_SB.FFA0.UCMD.
//
// SPDX-License-Identifier: MIT
//

Scope(FFA0) {
  Name(BUFF, Buffer(144){})   // FF-A send/recv envelope

  // Arg0: 8-byte CONTROL buffer (opcode @0, connector @2). BUFF layout:
  // status @0, service UUID @bit128, doorbell tag @byte32 (payload byte 0),
  // the 48-byte request mailbox @byte33 (payload byte 1), and the 48-byte
  // response mailbox @byte32 (payload byte 0). Returns the response mailbox
  // (VERSION @0, CCI @4, MESSAGE IN @16).
  Method(UCMD, 1, Serialized) {
    CreateDwordField(BUFF, 0, STAT)     // Out - FF-A status
    CreateField(BUFF, 128, 128, UUID)   // Service UUID
    CreateByteField(BUFF, 32, CMDD)     // In  - doorbell tag
    CreateField(BUFF, 264, 384, WMBX)   // In  - request mailbox (payload byte 1)
    CreateField(BUFF, 256, 384, RMBX)   // Out - response mailbox (payload byte 0)
    CreateField(BUFF, 328, 64, UCTL)    // In  - CONTROL at request mailbox offset 8

    Store(0x00, CMDD)
    Store(Buffer(48){}, WMBX)           // zero the request mailbox
    Store(Arg0, UCTL)                   // 8-byte CONTROL into mailbox offset 8
    Store(ToUUID("65467f50-827f-4e4f-8770-dbf4c3f77f45"), UUID)

    Store(Store(BUFF, FFAC), BUFF)
    If(LEqual(STAT, 0x0)) {  // FF-A successful?
      Return(RMBX)
    }
    Return(Buffer(48){})
  }
}
