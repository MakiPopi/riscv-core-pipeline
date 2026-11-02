module regfile (
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

  // Combinational read, in priority order:
  //   1. x0 always reads as zero
  //   2. same-cycle bypass: a write to this address is happening now
  //   3. otherwise read the stored value
  assign rdata1 = (raddr1 == 5'd0)             ? 32'b0 :
                  (we && waddr == raddr1)      ? wdata :
                                                 regs[raddr1];

  assign rdata2 = (raddr2 == 5'd0)             ? 32'b0 :
                  (we && waddr == raddr2)      ? wdata :
                                                 regs[raddr2];

endmodule
