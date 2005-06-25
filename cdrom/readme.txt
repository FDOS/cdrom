AtapiCDD - a public domain DOS CD-ROM device driver for
ATAPI/IDE CD-drives, currently limited to PIO mode.

This is the source (v 0.2.6 alpha) to an older release.
Requires TASM (3 & 5 tested).
This should closely match the binary that has been available
for a while (0.2.5 alpha) but with some additional debug
output (disabling/removing them should produce a nearly
identically functioning binary).

My newer versions support Nasm and/or Fasm, but should not
be used (bugs or missing functionality) so I'm not posting their
source yet.  I really hope to have a NASM compatible source
with much better performance available later this year.

Notes: this version is largely unsupported; meaning I know
it has issues, but do not have the free time to help with
its use -- though I will try to answer any questions
and help any way possible for those wishing to further
its development.  Until a non-alpha version is available,
I do not encourage use in production systems without careful
testing.

The code is meant to be easy to read, using as simple
asm as possible to allow easy porting to other assemblers.
It is not an example of elegant assembly programming.

Jeremy
20050529
