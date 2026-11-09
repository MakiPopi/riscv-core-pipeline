module regfile #(
  // 1: a read of the register being written this cycle returns the new value.
  //    Needed in a pipeline, where Write-back and Decode overlap.
  // 0: reads always return the value stored before this cycle's clock edge.
  //    Needed in a single-cycle core, where an instruction reads and writes
  //    the same register in the same cycle (addi x1, x1, 1).
  parameter bit BYPASS = 1'b1
) (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);

  // x1..x31 only. x0 has no storage because it is always zero.
  logic [31:0] regs [31:1];

  // Synchronous write. Writes to x0 are ignored.
  always_ff @(posedge clk) begin
    if (we && waddr != 5'd0) begin
      regs[waddr] <= wdata;
    end
  end

  // Plain lookup of the stored value. x0 reads as zero.
  logic [31:0] stored1, stored2;
  assign stored1 = (raddr1 == 5'd0) ? 32'b0 : regs[raddr1];
  assign stored2 = (raddr2 == 5'd0) ? 32'b0 : regs[raddr2];

  if (BYPASS) begin : g_bypass
    // Same-cycle bypass. x0 is excluded so a write to x0 never leaks through.
    assign rdata1 = (we && waddr == raddr1 && raddr1 != 5'd0) ? wdata : stored1;
    assign rdata2 = (we && waddr == raddr2 && raddr2 != 5'd0) ? wdata : stored2;
  end else begin : g_no_bypass
    assign rdata1 = stored1;
    assign rdata2 = stored2;
  end

endmodule
