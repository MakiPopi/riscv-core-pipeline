module branch_cmp (
  input  logic [31:0] a,        // rs1 value
  input  logic [31:0] b,        // rs2 value
  input  logic [2:0]  funct3,   // which comparison
  output logic        taken
);

  always_comb begin
    case (funct3)
      3'b000:  taken = (a == b);                 // beq
      3'b001:  taken = (a != b);                 // bne
      3'b100:  taken = ($signed(a) <  $signed(b)); // blt
      3'b101:  taken = ($signed(a) >= $signed(b)); // bge
      3'b110:  taken = (a <  b);                 // bltu
      3'b111:  taken = (a >= b);                 // bgeu
      default: taken = 1'b0;                     // 010, 011 are not branches
    endcase
  end

endmodule
