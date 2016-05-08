
                  GCDROM -- DOS SATA Native IDE CD-ROM Disk Driver, V2.3
                ==========================================

1. General Description
   -------------------

   GCDROM is a DOS driver for PC system SATA Native IDE CD-ROM drives. 
   The source code derive from XCDROM22 Projects.
   Not support Legacy PATA mode IDE CD-ROM.


2. Setup and Configuration
   -----------------------

   GCDROM is loaded by the CONFIG.SYS file, which must have a command line
   similar to:

            DEVICE[HIGH] = [path]GCDROM.SYS [/D:DeviceNm] [/CNm]

   you can use switch "/CNm" to select target controller, default is "/C0"	    
    	    
   Examples:    DEVICE=C:\DOS\GCDROM.SYS
                DEVICEHIGH=C:\BIN\GCDROM.SYS /D:CDROM1 /C0

   				

