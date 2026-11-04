module lsu (
  input  logic [1:0]  addr_lo,      // address bits [1:0]: byte offset in the word
  input  logic [2:0]  funct3,       // size (bits 1:0) and unsigned flag (bit 2)
  input  logic [31:0] store_data,   // rs2 value, for stores
  input  logic [31:0] load_raw,     // full aligned word read from memory
  output logic [3:0]  store_be,     // which byte lanes to write
  output logic [31:0] store_wdata,  // data to write (replicated across lanes)
  output logic [31:0] load_data,    // loaded value, extended to 32 bits
  output logic        misaligned    // access is not naturally aligned
);

  logic [1:0] size;                 // 00 byte, 01 half, 10 word, 11 invalid
  assign size = funct3[1:0];

  // ---- Alignment: a half must be 2-aligned, a word must be 4-aligned ----
  always_comb begin
    case (size)
      2'b01:   misaligned = addr_lo[0];
      2'b10:   misaligned = (addr_lo != 2'b00);
      default: misaligned = 1'b0;   // bytes are always aligned; 11 is rejected by the decoder
    endcase
  end

  // ---- Store path ----
  always_comb begin
    store_be    = 4'b0000;
    store_wdata = store_data;
    case (size)
      2'b00: begin                          // sb: one lane
        store_be    = 4'b0001 << addr_lo;
        store_wdata = {4{store_data[7:0]}};
      end
      2'b01: begin                          // sh: lower or upper half
        store_be    = addr_lo[1] ? 4'b1100 : 4'b0011;
        store_wdata = {2{store_data[15:0]}};
      end
      2'b10: store_be = 4'b1111;            // sw: all lanes
      default: store_be = 4'b0000;
    endcase
    // A misaligned store must not touch memory
    if (misaligned) store_be = 4'b0000;
  end

  // ---- Load path ----
  logic [7:0]  byte_sel;
  logic [15:0] half_sel;

  always_comb begin
    case (addr_lo)
      2'd0: byte_sel = load_raw[7:0];
      2'd1: byte_sel = load_raw[15:8];
      2'd2: byte_sel = load_raw[23:16];
      2'd3: byte_sel = load_raw[31:24];
    endcase
    half_sel = addr_lo[1] ? load_raw[31:16] : load_raw[15:0];
  end

  always_comb begin
    case (size)
      2'b00:   load_data = funct3[2] ? {24'b0, byte_sel}
                                     : {{24{byte_sel[7]}}, byte_sel};   // lbu : lb
      2'b01:   load_data = funct3[2] ? {16'b0, half_sel}
                                     : {{16{half_sel[15]}}, half_sel};  // lhu : lh
      2'b10:   load_data = load_raw;                                    // lw
      default: load_data = 32'b0;
    endcase
  end

endmodule
