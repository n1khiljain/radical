// =============================================================================
// tb_chip.sv — named-pipe harness for chip.sv
//
// Protocol over sim_cmd.fifo / sim_resp.fifo:
//   READ XXXXXXXX              → DATA XXXXXXXX
//   WRITE XXXXXXXX XXXXXXXX    → OK
//   BACKDOOR_LOAD /path/file   → OK  (loads weights.bin directly into regs,
//                                      bypassing AXI-stream — fast path)
//   STREAM N /path/file        → OK  (AXI-stream, one byte at a time — slow)
//   INJECT M A B               → OK
//   QUIT                       → (terminates)
//
// BACKDOOR_LOAD format matches weights.bin exactly (length-prefixed int8 blobs):
//   [4B uint32-LE len][len bytes int8] × {conv1_w,conv1_b,conv2_w,conv2_b,
//                                          fc1_w,fc1_b,fc2_w,fc2_b}
//   conv1_b / conv2_b consumed and discarded (no bias ports on conv stages).
//   fc1_b / fc2_b sign-extended int8 → int32 before storing.
// =============================================================================
`timescale 1ns/1ps
module tb_chip;

    logic clock=0, reset=1;

    logic [31:0] s_axil_awaddr=0; logic s_axil_awvalid=0; logic s_axil_awready;
    logic [31:0] s_axil_wdata=0;  logic s_axil_wvalid=0;  logic s_axil_wready;
    logic [1:0]  s_axil_bresp;    logic s_axil_bvalid;    logic s_axil_bready=0;
    logic [31:0] s_axil_araddr=0; logic s_axil_arvalid=0; logic s_axil_arready;
    logic [31:0] s_axil_rdata;    logic s_axil_rvalid;    logic s_axil_rready=0;
    logic [1:0]  s_axil_rresp;

    logic [7:0] s_axis_tdata=0; logic s_axis_tvalid=0;
    logic s_axis_tready;        logic s_axis_tlast=0;

    always #5 clock = ~clock;

    chip u_chip (
        .clock(clock),.reset(reset),
        .s_axil_awaddr(s_axil_awaddr),.s_axil_awvalid(s_axil_awvalid),.s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),  .s_axil_wvalid(s_axil_wvalid),  .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),  .s_axil_bvalid(s_axil_bvalid),  .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),.s_axil_arvalid(s_axil_arvalid),.s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),  .s_axil_rvalid(s_axil_rvalid),  .s_axil_rready(s_axil_rready),
        .s_axil_rresp(s_axil_rresp),
        .s_axis_tdata(s_axis_tdata),  .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast)
    );

    // =========================================================================
    // AXI tasks
    // =========================================================================
    task axi_write(input logic [31:0] addr, input logic [31:0] data);
        @(posedge clock); #1;
        s_axil_awaddr=addr; s_axil_awvalid=1;
        s_axil_wdata=data;  s_axil_wvalid=1; s_axil_bready=1;
        @(posedge clock); #1; s_axil_awvalid=0; s_axil_wvalid=0;
        @(posedge clock); #1; s_axil_bready=0;
    endtask

    task axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(posedge clock); #1;
        s_axil_araddr=addr; s_axil_arvalid=1; s_axil_rready=1;
        @(posedge clock); #1; s_axil_arvalid=0;
        @(posedge clock); #1;
        data=s_axil_rdata; s_axil_rready=0;
    endtask

    task axi_stream_file(input string filename, input integer n_bytes);
        integer fd, i; logic [7:0] b;
        fd=$fopen(filename,"rb");
        for (i=0; i<n_bytes; i++) begin
            void'($fread(b,fd));
            @(posedge clock); #1;
            s_axis_tdata=b; s_axis_tvalid=1;
            s_axis_tlast=(i==n_bytes-1)?1'b1:1'b0;
            @(posedge clock); #1;
            s_axis_tvalid=0; s_axis_tlast=0;
        end
        $fclose(fd);
    endtask

    // =========================================================================
    // BACKDOOR_LOAD — directly write weight registers from weights.bin.
    // No AXI-stream simulation — bypasses the compute-stage comb triggers.
    // Marks wts_done so ctrl_seq gets the correct weights at inference time.
    // =========================================================================
    task backdoor_load(input string filename);
        integer fd, i;
        logic [7:0] b;
        logic [31:0] hdr;

        fd = $fopen(filename, "rb");

        // conv1_w: skip 4-byte header, load 72 bytes
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<72;i++) begin void'($fread(b,fd)); u_chip.c1w[i]=signed'(b); end

        // conv1_b: skip header + 8 bytes (no bias port)
        for (i=0;i<4+8;i++) void'($fread(b,fd));

        // conv2_w: skip 4-byte header, load 1152 bytes
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<1152;i++) begin void'($fread(b,fd)); u_chip.c2w[i]=signed'(b); end

        // conv2_b: skip header + 16 bytes
        for (i=0;i<4+16;i++) void'($fread(b,fd));

        // fc1_w: skip 4-byte header, load 25088 bytes
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<25088;i++) begin void'($fread(b,fd)); u_chip.f1w[i]=signed'(b); end

        // fc1_b: skip 4-byte header, load 32 bytes (sign-extend to int32)
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<32;i++) begin
            void'($fread(b,fd));
            u_chip.f1b[i]={{24{b[7]}},b};
        end

        // fc2_w: skip 4-byte header, load 320 bytes
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<320;i++) begin void'($fread(b,fd)); u_chip.f2w[i]=signed'(b); end

        // fc2_b: skip 4-byte header, load 10 bytes (sign-extend to int32)
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<10;i++) begin
            void'($fread(b,fd));
            u_chip.f2b[i]={{24{b[7]}},b};
        end

        $fclose(fd);

        // Mark weights loaded so the stream FSM moves to image-capture phase
        u_chip.wts_done = 1'b1;
        @(posedge clock);
    endtask

    // =========================================================================
    // Fault injection backdoor
    // =========================================================================
    task inject_fault(input integer mem_id, input integer addr, input integer bit_idx);
        if (mem_id==0) begin
            if      (addr<   72) u_chip.c1w[addr]       = u_chip.c1w[addr]       ^ (8'b1<<bit_idx);
            else if (addr< 1224) u_chip.c2w[addr-72]    = u_chip.c2w[addr-72]    ^ (8'b1<<bit_idx);
            else if (addr<26312) u_chip.f1w[addr-1224]  = u_chip.f1w[addr-1224]  ^ (8'b1<<bit_idx);
            else                 u_chip.f2w[addr-26312] = u_chip.f2w[addr-26312] ^ (8'b1<<bit_idx);
        end else begin
            u_chip.img[addr%784] = u_chip.img[addr%784] ^ (8'b1<<bit_idx);
        end
    endtask

    // =========================================================================
    // Command server
    // =========================================================================
    integer      cmd_fd, resp_fd;
    string       line, resp, fname;
    logic [31:0] rdata, aw, wd;
    integer      n, m, a, b_idx;

    initial begin
        repeat(10) @(posedge clock);
        reset=0; @(posedge clock);

        cmd_fd  = $fopen("sim_cmd.fifo",  "r");
        resp_fd = $fopen("sim_resp.fifo", "w");
        $fdisplay(resp_fd,"READY"); $fflush(resp_fd);

        while (!$feof(cmd_fd)) begin
            void'($fgets(line,cmd_fd));
            if (line.len() < 2) continue;

            if (line.substr(0,3)=="READ") begin
                void'($sscanf(line,"READ %h",aw));
                axi_read(aw,rdata);
                $sformat(resp,"DATA %08h",rdata);
                $fdisplay(resp_fd,"%s",resp); $fflush(resp_fd);

            end else if (line.substr(0,5)=="WRITE") begin
                void'($sscanf(line,"WRITE %h %h",aw,wd));
                axi_write(aw,wd);
                $fdisplay(resp_fd,"OK"); $fflush(resp_fd);

            end else if (line.substr(0,14)=="BACKDOOR_LOAD") begin
                void'($sscanf(line,"BACKDOOR_LOAD %s",fname));
                backdoor_load(fname);
                $fdisplay(resp_fd,"OK"); $fflush(resp_fd);

            end else if (line.substr(0,6)=="STREAM") begin
                void'($sscanf(line,"STREAM %d %s",n,fname));
                axi_stream_file(fname,n);
                $fdisplay(resp_fd,"OK"); $fflush(resp_fd);

            end else if (line.substr(0,6)=="INJECT") begin
                void'($sscanf(line,"INJECT %d %d %d",m,a,b_idx));
                inject_fault(m,a,b_idx);
                $fdisplay(resp_fd,"OK"); $fflush(resp_fd);

            end else if (line.substr(0,4)=="QUIT") begin
                $fclose(cmd_fd); $fclose(resp_fd); $finish;
            end
        end
        $finish;
    end
endmodule : tb_chip
