module mem #(
  parameter int          WORDS = 16384,         // size in 32-bit words (power of two): 64 KiB
  parameter logic [31:0] BASE  = 32'h8000_0000  // byte address of the first word
) (
  input  logic        clk,

  // Instruction port: read only. Word address (byte address >> 2).
  input  logic [31:2] iaddr,
  output logic [31:0] irdata,

  // Data port: combinational read, synchronous write with byte enables.
  input  logic [31:2] daddr,
  input  logic [3:0]  dbe,        // one bit per byte lane; 0 means no write
  input  logic [31:0] dwdata,
  output logic [31:0] drdata
);

  localparam int AW = $clog2(WORDS);   // index width: 14 bits for 16384 words

  logic [31:0] words [WORDS];

  // Word offset from the base. Valid only if all bits above the index are zero,
  // which also rejects addresses below the base (they wrap to huge offsets).
  logic [31:2] ioff, doff;
  assign ioff = iaddr - BASE[31:2];
  assign doff = daddr - BASE[31:2];

  logic i_ok, d_ok;
  assign i_ok = (ioff[31:AW+2] == '0);
  assign d_ok = (doff[31:AW+2] == '0);

  assign irdata = i_ok ? words[ioff[AW+1:2]] : 32'b0;
  assign drdata = d_ok ? words[doff[AW+1:2]] : 32'b0;

  // Each byte lane is written only if its enable bit is set.
  always_ff @(posedge clk) begin
    if (d_ok) begin
      if (dbe[0]) words[doff[AW+1:2]][7:0]   <= dwdata[7:0];
      if (dbe[1]) words[doff[AW+1:2]][15:8]  <= dwdata[15:8];
      if (dbe[2]) words[doff[AW+1:2]][23:16] <= dwdata[23:16];
      if (dbe[3]) words[doff[AW+1:2]][31:24] <= dwdata[31:24];
    end
  end

  // Start from all zeros, then load the program if +hex=<file> was given.
  string hexfile;
  initial begin
    for (int i = 0; i < WORDS; i++) words[i] = 32'b0;
    if ($value$plusargs("hex=%s", hexfile)) $readmemh(hexfile, words);
  end

endmodule
