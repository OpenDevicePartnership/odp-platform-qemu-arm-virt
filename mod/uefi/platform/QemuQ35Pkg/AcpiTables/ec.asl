DefinitionBlock ("", "SSDT", 2, "ODP", "Q35HID", 0x00000001)
{
    Scope (\_SB)
    {
        Include ("../../AcpiTables/hid.asl")
    }
}
