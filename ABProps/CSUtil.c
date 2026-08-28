#include "CSUtil.h"
#include <capstone/capstone.h>
#include <stdio.h>
#include <string.h>

static csh g_handle;
static int g_ok = 0;

int ab_cs_init(void) {
    if (g_ok) return 0;
    cs_err e = cs_open(
#ifdef CS_ARCH_AARCH64
        CS_ARCH_AARCH64,
#else
        CS_ARCH_ARM64,
#endif
        CS_MODE_ARM, &g_handle);
    if (e != CS_ERR_OK) return (int)e;
    cs_option(g_handle, CS_OPT_SYNTAX, CS_OPT_SYNTAX_DEFAULT);
    g_ok = 1;
    return 0;
}

int ab_cs_disasm(const uint8_t *code, size_t n, uint64_t addr, char *out, size_t outsz) {
    if (!g_ok && ab_cs_init() != 0) return -1;
    cs_insn *insn = NULL;
    size_t count = cs_disasm(g_handle, code, n, addr, 0, &insn);
    if (count == 0) return 0;
    size_t used = 0;
    out[0] = 0;
    for (size_t i = 0; i < count; i++) {
        char line[256];
        int w = snprintf(line, sizeof(line), "%llx\t%s\t%s\n",
                         (unsigned long long)insn[i].address,
                         insn[i].mnemonic,
                         insn[i].op_str);
        if (w < 0) break;
        if (used + (size_t)w + 1 >= outsz) break;
        memcpy(out + used, line, (size_t)w);
        used += (size_t)w;
        out[used] = 0;
    }
    cs_free(insn, count);
    return (int)count;
}
