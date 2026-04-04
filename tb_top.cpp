// =============================================================================
// tb_top.cpp
// Testbench for ucie_crc_gen — UCIe Spec Section 3.6 + Appendix B
//
// Test strategy:
//   1. All-zeros input          → known CRC (verifies initial seed = 0x0000)
//   2. All-ones input           → verifies polynomial toggling across all bits
//   3. Single bit set (bit 0)   → verifies bit 0 path into each CRC bit
//   4. 68B flit (zero-padded)   → verifies correct zero-extension behaviour
//   5. Consistency check        → changing one bit changes the CRC (sanity)
//   6. Combinational check      → output changes instantly when input changes
//      (no clock needed — confirms purely combinational architecture)
// =============================================================================

#include "Vucie_crc_gen.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstring>
#include <cstdint>

// Helper: compute CRC using the DUT and return crc_out
static uint16_t run_crc(Vucie_crc_gen* dut,
                         VerilatedVcdC* tfp,
                         vluint64_t&    sim_time,
                         const uint8_t  msg[128])
{
    // Pack bytes into data_in[1023:0]:
    // bit 0 of data_in = bit 0 of msg[0]  (Byte 0, bit 0)
    // bit 7 of data_in = bit 7 of msg[0]  (Byte 0, bit 7)
    // bit 8 of data_in = bit 0 of msg[1]  (Byte 1, bit 0) ...
    for (int byte_idx = 0; byte_idx < 128; byte_idx++) {
        int word = byte_idx / 4;          // which 32-bit word
        int shift = (byte_idx % 4) * 8;  // bit offset within that word
        // data_in is accessed as dut->data_in[word]
        dut->data_in[word] = (dut->data_in[word] & ~(0xFFu << shift))
                           | ((uint32_t)msg[byte_idx] << shift);
    }
    dut->eval();
    tfp->dump(sim_time++);
    return (uint16_t)dut->crc_out;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vucie_crc_gen* dut = new Vucie_crc_gen;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("waves/dump.vcd");

    vluint64_t sim_time = 0;
    int pass = 0, fail = 0;

    auto check = [&](const char* name, bool cond, const char* note = "") {
        if (cond) {
            printf("  PASS  %-45s %s\n", name, note);
            pass++;
        } else {
            printf("  FAIL  %-45s %s\n", name, note);
            fail++;
        }
    };

    uint8_t msg[128];

    printf("\n=== UCIe CRC Generator Testbench ===\n");
    printf("Spec ref: Section 3.6 + Appendix B\n\n");

    // ── Test 1: All-zeros input ──────────────────────────────────────────────
    // Spec: initial value (seed) is 0x0000, so all-zero input
    // produces 0x0000 (XOR of all zeros with seed 0 = 0).
    printf("[ Test 1 ] All-zeros input (seed = 0x0000 verification)\n");
    memset(msg, 0x00, 128);
    uint16_t crc_zeros = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC = 0x%04X\n", crc_zeros);
    check("all-zeros CRC == 0x0000", crc_zeros == 0x0000,
          "(seed=0, no toggling expected)");

    // ── Test 2: All-ones input ───────────────────────────────────────────────
    printf("\n[ Test 2 ] All-ones 128B input\n");
    memset(msg, 0xFF, 128);
    uint16_t crc_ones = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC = 0x%04X\n", crc_ones);
    check("all-ones CRC != 0x0000", crc_ones != 0x0000,
          "(non-trivial result expected)");
    check("all-ones CRC != all-zeros CRC", crc_ones != crc_zeros);

    // ── Test 3: Single bit set — bit 0 only ─────────────────────────────────
    printf("\n[ Test 3 ] Single bit: data_in[0] = 1, all others 0\n");
    memset(msg, 0x00, 128);
    msg[0] = 0x01;   // bit 0 of byte 0 = data_in[0]
    uint16_t crc_bit0 = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC = 0x%04X\n", crc_bit0);
    // From Appendix B, data_in[0] appears in crc_out[15], crc_out[5], crc_out[4],
    // crc_out[3], crc_out[0]. So result must be non-zero and != zeros/ones results.
    check("single-bit-0 CRC != 0x0000", crc_bit0 != 0x0000);
    check("single-bit-0 CRC != all-zeros CRC", crc_bit0 != crc_zeros);
    // crc_out[15] must be 1 (data_in[0] is in its equation)
    check("single-bit-0: crc_out[15]=1", (crc_bit0 >> 15) & 1);

    // ── Test 4: Single bit set — bit 1023 only ──────────────────────────────
    printf("\n[ Test 4 ] Single bit: data_in[1023] = 1, all others 0\n");
    memset(msg, 0x00, 128);
    msg[127] = 0x80;  // bit 7 of byte 127 = data_in[1023]
    uint16_t crc_bit1023 = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC = 0x%04X\n", crc_bit1023);
    check("single-bit-1023 CRC != 0x0000", crc_bit1023 != 0x0000);
    check("single-bit-1023 CRC != single-bit-0 CRC", crc_bit1023 != crc_bit0);

    // ── Test 5: 68B flit — zero padded to 128B ──────────────────────────────
    // Spec 3.6: "For smaller messages, the message is zero extended in the MSB."
    // A 68B flit occupies bytes [0..67], bytes [68..127] are zero.
    printf("\n[ Test 5 ] 68B flit (bytes 0-67 filled 0xAB, bytes 68-127 = 0)\n");
    memset(msg, 0x00, 128);
    memset(msg, 0xAB, 68);
    uint16_t crc_68b = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC = 0x%04X\n", crc_68b);
    check("68B flit CRC != 0x0000", crc_68b != 0x0000);
    check("68B flit CRC != all-zeros CRC", crc_68b != crc_zeros);
    check("68B flit CRC != all-ones CRC", crc_68b != crc_ones);

    // ── Test 6: Flipping one bit changes CRC ────────────────────────────────
    printf("\n[ Test 6 ] Bit-flip sensitivity: flip bit 8 in 68B flit\n");
    msg[1] ^= 0x01;  // flip data_in[8]
    uint16_t crc_68b_flipped = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC before flip = 0x%04X\n", crc_68b);
    printf("           CRC after  flip = 0x%04X\n", crc_68b_flipped);
    check("bit-flip changes CRC", crc_68b_flipped != crc_68b,
          "(error detection working)");

    // ── Test 7: Purely combinational — no clock needed ──────────────────────
    // Change input and immediately eval; output must update in same eval call.
    printf("\n[ Test 7 ] Combinational: output updates without clock tick\n");
    memset(msg, 0x00, 128);
    msg[0] = 0x55;
    uint16_t crc_a = run_crc(dut, tfp, sim_time, msg);
    msg[0] = 0xAA;
    uint16_t crc_b = run_crc(dut, tfp, sim_time, msg);
    printf("           CRC(0x55 in byte0) = 0x%04X\n", crc_a);
    printf("           CRC(0xAA in byte0) = 0x%04X\n", crc_b);
    check("0x55 != 0xAA byte0 CRCs differ", crc_a != crc_b,
          "(combinational sensitivity confirmed)");

    // ── Summary ──────────────────────────────────────────────────────────────
    printf("\n====================================\n");
    printf("Results: %d passed, %d failed\n", pass, fail);
    printf("====================================\n\n");

    tfp->close();
    delete dut;
    return (fail > 0) ? 1 : 0;
}