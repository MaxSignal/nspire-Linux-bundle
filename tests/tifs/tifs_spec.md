# TI-Nspire internal filesystem, as modelled here

Source: Hackspire "Internal Filesystem" (FlashFX Pro + Reliance). Everything
the documentation leaves open is a *parameter* of the synthetic images and is
*learned or verified* by the kernel driver, never assumed:

| Open point | Synthetic images | Driver |
|---|---|---|
| Spare offset of the 16-bit allocation info | parameter `alloc_off` | found from unit headers (0x48E2) |
| Spare check bytes (`~(b0^b1)`, Hamming of bytes 0-2) | some function | copied from the existing copy of the same logical page, never computed |
| Page data ECC (algorithm, step, placement) | parameter | learned by matching candidates against existing pages; writes stay off unless every sample matches |
| Directory entry details | documented layout | parsed as documented; any inconsistency fails the mount |
| Placement of the image file's blocks | — | verified against the tags the loader writes into every 4 KiB chunk |
