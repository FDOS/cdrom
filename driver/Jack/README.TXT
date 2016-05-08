
                  XCDROM -- DOS CD-ROM Disk Driver, V2.2
                ==========================================

1. General Description
   -------------------

   XCDROM is a DOS driver for PC system CD-ROM drives.    It is for use on
   "end user" PC systems with normal IDE channels, including 1997 or later
   mainboards using an Intel/VIA/SiS/ALi or other UltraDMA controller chip
   set to "Legacy IDE mode".   XCDROM is NOT for SCSI, Serial-ATA, "Native
   PCI mode" servers, or any "add-on" IDE adapter card offered by Promise,
   SiiG, etc.    XCDROM handles normal mainboard IDE channels and AVOIDS a
   need for an "add-on" card!

   XCDROM runs from 1 to 3 CD-ROM drives.   On loading, it checks both IDE
   channels, in order from primary-master to secondary-slave, and runs the
   first two CD-ROM drives found.   It has switch options (see below) that
   specify the "driver name" and request testing of specific IDE units for
   CD-ROM drives, instead of checking all units in "IDE order".   Both old
   PIO-mode drives and newer UltraDMA drives may be used, as XCDROM checks
   for and uses a mainboard UltraDMA controller as well.    XCDROM handles
   requests from a "CD-ROM redirector" program (SHCDX33A, MSCDEX etc.) for
   its CD-ROM drives, and it supports the same "audio functions" and other
   features as any DOS-compatible CD-ROM driver program.

   XCDROM runs only the normal IDE channels at their "default" I-O address
   ranges of 1F0h-1F7h (primary) and 170h-177h (secondary).    It does not
   use interrupts, and it defaults to normal "PIO mode" for data transfers
   when no UltraDMA controller is found.   This allows XCDROM to work with
   older mainboards and with plug-in "IDE cards" used on pre-1997 systems.
   XCDROM sets a local-stack, does a load-time 80386+ test and I-O timeout
   tests, and it has other items that make the driver SAFE!    XCDROM uses
   less than 2560 bytes of memory and has a file size of under 4096 bytes.

   If the version 3.1 (or newer) XDMA disk driver is present and using its
   output-overlap feature, XCDROM will "synchronize" CD-ROM functions with
   disk I-O.   This ELIMINATES the previous restriction of "no overlap" if
   an IDE channel must "share" an UltraDMA disk and a CD-ROM drive!   When
   a channel is busy with XDMA overlap, XCDROM "delays" CD-ROM I-O on that
   channel until overlap ends.    Letting IDE channels "share" an UltraDMA
   disk and a CD-ROM drive makes system setup easier, and allowing XDMA to
   use output-overlap in such a configuration improves system performance!
   For this to work, XCDROM must load after XDMA, so XCDROM can "find" the
   disk driver and access common variables.    XCDROM does so by using the
   "Int13 vector" set by XDMA for disk I-O.   If a disk "cache" program is
   also loaded, the "cache" must load AFTER both XDMA and XCDROM ("caches"
   also set Int13).   If V3.1+ XDMA is absent or not using overlap, XCDROM
   runs independently (NO "synchronization"!).

   [NOTE:  Even if XCDROM and V3.1+ XDMA "synchronize", system performance
   is LOWER if an UltraDMA disk and a CD-ROM "share" a channel.   The disk
   and CD-ROM cannot BOTH be running at the same time!   More speed can be
   achieved if UltraDMA disks use the primary IDE channel and ATAPI drives
   use the secondary channel.   The "no overlap" restriction is eliminated
   ONLY if XDMA V3.1+ and XCDROM are used together and are "synchronized".
   Overlap still CANNOT be used when XDMA "shares" an IDE channel with any
   other driver except XCDROM!]


2. Revision History
   ----------------

      V2.2   8-Feb-06  Corrected DVD handling and "regular" UltraDMA.

      V2.1  31-Jan-06  Deleted init "Set Mode" commands (BIOS will do
                         them anyway) to avoid conflicts.

      V2.0  27-Jan-06  Startup and seek timeouts increased.  Added up
                         to ATA-133 support.  Minor size reductions.

      V1.9  20-Jan-06  Fixed errors in Multi-Session and I-O logic.

      V1.8  17-Jan-06  Fixed Multi-Session "TOC input" to support ALL
                         drives, added a drive "reset" on I-O errors.

      V1.7  14-Jan-06  Updated XCDROM to read a "Multi Session" disk.

      V1.6  10-Jan-06  XCDROM now has stand-alone UltraDMA capability
                         and no longer requires XDMA/XDMAJR!   "Audio
                         Busy" status is now updated on ALL requests.

      V1.5   5-Jan-06  Fixed "Audio Status" & /AX device-status flags
                         and added support for up to 3 CD-ROM drives.

      V1.4   2-Jan-06  Initial release, added /AX and dual drives.

      V1.3  30-Dec-05  4th "Beta" issue, uses V3.1+ XDMA "OCheck".

      V1.2  23-Dec-05  3rd "Beta" issue, new /UF and /UX switches.

      V1.1  15-Dec-05  2nd "Beta" issue, improved XDMA linkage.

      V1.0  14-Dec-05  Original "Beta" XCDROM issue.


3. Switch Options
   --------------

   XCDROM switch options are as follows:

      /AX   Excludes ALL audio functions.   This makes the driver report
              on a Device-Status request that it reads DATA tracks only!
              /AX reduces the resident driver by 480 bytes.    UltraDMA,
              multi-drives, and other driver features are NOT affected!

      /D:   Specifies the desired "device name" which SHCDX33A or MSCDEX
              will use during their initialization to address the CD-ROM
              drives.   Examples are:  /D:CDROM1  /D:MYCDROM  etc.   The
              device name must be from 1 to 8 bytes valid for use in DOS
              filenames.   If /D: is omitted, or the "device name" after
              a /D: is missing or invalid, "XCDROM" will be the default.

      /L    Limits UltraDMA to "low memory" below 640K.   /L is REQUIRED
              to use UMBPCI or a similar driver whose upper-memory areas
              cannot do UltraDMA.   If /L is given, the driver must load
              in LOW memory so its DMA command-lists can fetch preperly,
              or driver loading will ABORT!   /L causes any I-O requests
              above 640K to use "PIO mode" input.   Note that /L will be
              IGNORED if /UX is also given.

      /Mn   Specifies the MAXIMUM UltraDMA "mode" to be set for a CD-ROM
              drive, where  n  is a number between 0 and 6, as follows:
                  0 = ATA-16, 16 MB/sec.    4 = ATA-66,   66 MB/sec.
                  1 = ATA-25, 25 MB/sec.    5 = ATA-100, 100 MB/sec.
                  2 = ATA-33, 33 MB/sec.    6 = ATA-133, 133 MB/sec.
                  3 = ATA-44, 44 MB/sec.
              A CD-ROM drive designed to use "modes" LESS than the given
              value will be limited to its own highest "mode".   /M will
              be IGNORED for CD-ROM drives which cannot do UltraDMA, and
              it will be ignored for ALL drives if /UX is also given.

      /PM   Requests the driver to check the IDE primary-master unit for
              a CD-ROM drive during driver init.    If a CD-ROM drive is
              NOT found as primary-master, driver loading will ABORT!

      /PS   Same as /PM but tests the primary-slave unit only.

      /SM   Same as /PM but tests the secondary-master unit only.

      /SS   Same as /PM but tests the secondary-slave unit only.

              --- NOTE ---
              Using multiple drives, multiple  /PM /PS /SM /SS  switches
              can be given.    The first-specified drive is addressed as
              "unit 0", the second as "unit 1", etc.   If fewer switches
              than drives are given, the unreferenced drives will NOT be
              used.    If NO such switches are given, the driver "scans"
              for CD-ROM drives, from primary-master to secondary-slave.
              The first drive found will be "unit 0", the second will be
              "unit 1", etc.

      /UF   Enables "Fast UltraDMA".   Data input requests that cross an
              UltraDMA "64K boundary" are executed using a 2-element DMA
              command list, one for data up to the boundary, and one for
              data beyond it.   CD-ROM speed is increased significantly.
              "PIO mode" input is still needed for user buffers that are
              misaligned (not at an even 4-byte address).    /UF will be
              IGNORED for CD-ROM drives which cannot do UltraDMA.

              --- NOTE ---
              Despite any UltraDMA specs, NOT ALL chipsets or mainboards
              can run multi-element DMA commands properly!   Although it
              is valuable, /UF must be TESTED on every system, and "Fast
              UltraDMA" should be enabled with CARE!!

      /UX   Disables ALL UltraDMA, even for CD-ROM drives capable of it.
              The driver then uses "PIO mode" for all data input.    /UX
              should be needed only for tests and diagnostic work.

   For each switch, a dash may replace the slash and lower-case characters
   may be used.


4. Setup and Configuration
   -----------------------

   XCDROM is loaded by the CONFIG.SYS file, which must have a command line
   similar to:

            DEVICE[HIGH] = [path]XCDROM.SYS [/D:DeviceNm] [...]

   Examples:    DEVICE=C:\DOS\XCDROM.SYS
                DEVICEHIGH=C:\BIN\XCDROM.SYS /D:CDROM1 /SM /SS

   If the CD-ROM drive "shares" an IDE channel with an UltraDMA disk which
   will use XDMA output-overlap, the following RULES apply:

      A) The version 3.1+ XDMA disk driver (or later) must be used.

      B) V3.1+ XDMA must be loaded before XCDROM.

      C) XDMA and XCDROM must BOTH load before any disk "cache" program.

   Without IDE channel "sharing", XCDROM may be loaded at any point in the
   CONFIG.SYS file.   See section 1 above, which explains these rules.


5. Error Reporting
   ---------------

   XCDROM reports an I-O error to its "CD-ROM redirector" program the same
   as all other DOS CD-ROM drivers.    For full details, see the Microsoft
   "MS-DOS CD-ROM Extensions 2.1", which includes information about CD-ROM
   device drivers for use with SHCDX33A or MSCDEX.


6. SPECIAL NOTES
   -------------

   Some CD-ROM drives (Sony, etc.) DO NOT follow all ATAPI "standards" and
   may require DISABLING UltraDMA with the /UX switch!

   Be sure to "enable" your CD-ROM drive(s) with the BIOS set-up routines!
   A drive that is "disabled" may cause the BIOS to clear all its UltraDMA
   flags and leave the drive in "PIO mode" zero, which is terribly SLOW!

   When cabling a CD-ROM drive by itself to an IDE channel, note that both
   "ends" of the cable must be used, NOT one end and the middle connector!
   This prevents ERRORS, as an unused cable-end CAN pick up "noise" like a
   RADIO antenna!

   If the driver "scans" for CD-ROM drives to use, error events WILL occur
   (select error, not a CD-ROM found, etc.).    Such events cause that IDE
   unit to be ignored.   However, the driver WILL display an error message
   when "told" with the  /PM /PS /SM /SS  switches to check a specific IDE
   unit, and the unit is a problem.   If an actual CD-ROM drive is ignored
   during a normal scan, users can add the proper  /PM /PS /SM /SS  switch
   to the XCDROM line in their CONFIG.SYS file, then re-boot.    This will
   force the error condition to be "displayed".

   If no CD-ROM drives are found, XCDROM displays "No CD-ROM drive to use;
   XCDROM not loaded!" and aborts.   But note that some BIOS programs will
   NOT "configure" mainboard UltraDMA chips when they find no IDE devices!
   Users who get the above message must first verify that the CD-ROM drive
   is "enabled" through the BIOS set-up routines.   If this HAS been done,
   "No CD-ROM drive found" says the UltraDMA chip was NOT set for "legacy"
   IDE channel addresses (1F0h/170h), and the BIOS may need to be UPDATED!

