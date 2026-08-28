#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int ab_cs_init(void);
/// Disassemble `n` bytes at `addr`. Writes lines "hexaddr\tmnem\top" into out.
/// Returns instruction count, or <0 on error.
int ab_cs_disasm(const uint8_t *code, size_t n, uint64_t addr, char *out, size_t outsz);

#ifdef __cplusplus
}
#endif
