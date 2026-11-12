/* SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors */
/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#define BPMP_ABI_HAVE_STDC
#include "bpmp-abi.h"
#include "bpmp-host-proxy.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define KERNEL_VERSION(a, b, c) (((a) << 16) | ((b) << 8) | (c))
#define LINUX_VERSION_CODE KERNEL_VERSION(6, 12, 0)
#define MRQ_CLK_ID_MASK 0xffffffU
#define MRQ_CLK_CMD_SHIFT 24
#define offsetofend(type, field) (offsetof(type, field) + sizeof(((type *)0)->field))
#define deb_warn(...) do { if (0) fprintf(stderr, __VA_ARGS__); } while (0)
typedef uint32_t u32;
struct tegra_bpmp_message {
    unsigned int mrq;
    struct { void *data; size_t size; } tx;
};
#include "policy-under-test.h"

int main(void)
{
    struct bpmp_allowed_res allowed = { .clocks_size = 1, .resets_size = 1, .reset = { 4 } };
    struct mrq_clk_request clk = { 0 };
    struct tegra_bpmp_message msg = { .mrq = MRQ_CLK, .tx = { &clk, sizeof(clk) } };
    const unsigned int roots[] = { 94, 14, 102, 103, 292, 91, 288, 327 };
    const unsigned int denied[] = { CMD_CLK_DISABLE, CMD_CLK_SET_RATE, CMD_CLK_SET_PARENT, CMD_CLK_RESET_REFCOUNTS, 255 };
    for (size_t i = 0; i < ARRAY_SIZE(roots); ++i) {
        allowed.clock[0] = roots[i];
        for (size_t j = 0; j < ARRAY_SIZE(denied); ++j) {
            clk.cmd_and_id = (denied[j] << 24) | roots[i];
            assert(!check_if_allowed(&allowed, &msg));
        }
        clk.cmd_and_id = (CMD_CLK_ENABLE << 24) | roots[i];
        assert(check_if_allowed(&allowed, &msg));
        clk.cmd_and_id = (CMD_CLK_GET_RATE << 24) | roots[i];
        assert(check_if_allowed(&allowed, &msg));
        clk.cmd_and_id = (CMD_CLK_ROUND_RATE << 24) | roots[i];
        assert(check_if_allowed(&allowed, &msg));
    }
    allowed.clock[0] = 9;
    clk.cmd_and_id = (CMD_CLK_SET_RATE << 24) | 9;
    assert(check_if_allowed(&allowed, &msg));
    clk.cmd_and_id = (CMD_CLK_SET_RATE << 24) | 10;
    assert(!check_if_allowed(&allowed, &msg));
    clk.cmd_and_id = (CMD_CLK_ROUND_RATE << 24) | 10;
    assert(check_if_allowed(&allowed, &msg));
    clk.cmd_and_id = (CMD_CLK_RESET_REFCOUNTS << 24) | 9;
    assert(!check_if_allowed(&allowed, &msg));
    msg.tx.size = 0;
    msg.tx.data = NULL;
    assert(!check_if_allowed(&allowed, &msg));
    msg.mrq = MRQ_RESET;
    assert(!check_if_allowed(&allowed, &msg));
    msg.mrq = MRQ_PG;
    assert(!check_if_allowed(&allowed, &msg));

    const unsigned int memory[] = { MRQ_BWMGR, MRQ_ISO_CLIENT, MRQ_EMC_DVFS_LATENCY, MRQ_EMC_DVFS_EMCHUB };
    for (size_t i = 0; i < ARRAY_SIZE(memory); ++i) {
        msg.mrq = memory[i];
        allowed.allow_memory_control = false;
        assert(!check_if_allowed(&allowed, &msg));
        allowed.allow_memory_control = true;
        assert(check_if_allowed(&allowed, &msg));
    }
    msg.mrq = MRQ_PING;
    allowed.allow_memory_control = false;
    assert(check_if_allowed(&allowed, &msg));
    msg.mrq = 0xffffffffU;
    assert(!check_if_allowed(&allowed, &msg));
    puts("BPMP policy checks passed");
}
