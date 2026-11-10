module soc_top (
  input  logic        clk,
  input  logic        rst,

  // Retirement trace and trap, passed straight through from the core
  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_inst,
  output logic [4:0]  ret_rd,
  output logic [31:0] ret_rd_data,
  output logic        ret_mem_re,
  output logic        ret_mem_we,
  output logic [31:0] ret_mem_addr,
  output logic [31:0] ret_mem_data,
  output logic        trap
);

  // Memory starts here, and so does the PC after reset (Spike's default layout)
  localparam logic [31:0] BASE = 32'h8000_0000;

  logic [31:2] imem_addr, dmem_addr;
  logic [31:0] imem_rdata, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;

  core #(.RESET_PC(BASE)) u_core (
    .clk(clk), .rst(rst),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_be(dmem_be),
    .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_inst(ret_inst),
    .ret_rd(ret_rd), .ret_rd_data(ret_rd_data),
    .ret_mem_re(ret_mem_re), .ret_mem_we(ret_mem_we),
    .ret_mem_addr(ret_mem_addr), .ret_mem_data(ret_mem_data),
    .trap(trap)
  );

  mem #(.BASE(BASE)) u_mem (
    .clk(clk),
    .iaddr(imem_addr), .irdata(imem_rdata),
    .daddr(dmem_addr), .dbe(dmem_be), .dwdata(dmem_wdata), .drdata(dmem_rdata)
  );

endmodule
