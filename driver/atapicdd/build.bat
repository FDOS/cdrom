@echo Building public domain ATAPI CD-ROM driver
@echo requires TASM (or MASM), a linker (e.g. TLINK), and EXE2BIN
tasm32 /m5 atapicdd.asm
tlink atapicdd.obj
exe2bin atapicdd.exe atapicdd.sys
@rem this line can be commented out if you want the .exe file
@del atapicdd.exe
@del atapicdd.map
@del atapicdd.obj
@rem this line can be commented out for uncompressed binary
upx --8086 --best atapicdd.sys
