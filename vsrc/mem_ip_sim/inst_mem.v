`include "configs.vh"

module
    InstrMem(
        input           [`INSTR_MEM_DEPTH - 1 : 0]           a,
        output          [31 : 0]                            spo
    );

    localparam                                              WORD_COUNT      = (1 << `INSTR_MEM_DEPTH);
    localparam                                              BYTE_COUNT      = WORD_COUNT << 2;
    reg                 [31 : 0]                            mem             [0 : (1 << `INSTR_MEM_DEPTH) - 1];
    reg                 [ 7 : 0]                            raw_mem         [0 : BYTE_COUNT - 1];
    integer                                                 i;

    initial begin
        for(i = 0; i < WORD_COUNT; i = i + 1) begin
            mem[i] = 32'd0;
        end
        for(i = 0; i < BYTE_COUNT; i = i + 1) begin
            raw_mem[i] = 8'd0;
        end
        $readmemh(`INSTR_MEM_INI, raw_mem);
        for(i = 0; i < WORD_COUNT; i = i + 1) begin
            mem[i] = {raw_mem[i * 4 + 3], raw_mem[i * 4 + 2], raw_mem[i * 4 + 1], raw_mem[i * 4]};
        end
    end

    assign spo = mem[a];

endmodule