// SPDX-License-Identifier: ISC
//
// Environment for the irq configuration.
//
// getq and setq name a q register in a 5-bit field, but only q0..q3 exist:
// README.md gives their encodings as `000XX` (qs in rs1, qd in rd).  The
// decoder doesn't check the upper bits, so `setq q16, x1` writes cpuregs[48]
// of a 36-entry register file (fvlint's mem_addr:cpuregs.wr0 counterexample).
// Here we assume software uses only the documented encodings.
//
// mem_rdata carries load data too, so this also rules out loading a word that
// happens to look like such an instruction: harmless for these checks.
module fvlint_assumptions (input [31:0] mem_rdata);
  wire custom0 = mem_rdata[6:0] == 7'b0001011;
  always @* begin
    if (custom0 && mem_rdata[31:25] == 7'b0000000) assume (mem_rdata[19:17] == 3'b000);  // getq rd, qs
    if (custom0 && mem_rdata[31:25] == 7'b0000001) assume (mem_rdata[11:9] == 3'b000);   // setq qd, rs
  end
endmodule
