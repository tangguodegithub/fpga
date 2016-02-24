//
// Copyright 2016 Ettus Research LLC
//

// Command Packet Processor
//   Accepts 64-bit AXI stream with compressed VITA (CVITA) command packet data:
//     0: Header
//     1: Optional 64 bit VITA time
//     2: { 24'h0, settings bus address [7:0], data [31:0] }   Note: Address / data width are parameterized
//     Note: If long command packet (i.e. more than one settings bus transaction in payload),
//           additional settings bus transactions can follow.
//
// Generates a response packet with the same sequence number, the src/dst stream ID swapped,
// (optional) the actual time the setting was sent, and readback data as the payload.
//
// TODO: Should long command packets have one readback per settings bus transaction?
//       Should the response be a 'long' reponse packet or one packet per transaction?
//
// Settings register bus:
// - The settings register bus is a simple strobed interface.
// - Transactions include both a write and a readback.
// - The write occurs when set_stb is asserted.
//   The settings register with the address matching set_addr will
//   be loaded with the data on set_data.
// - Readback occurs when rb_stb is asserted. The read back strobe
//   must assert at least one clock cycle after set_stb asserts /
//   rb_stb is ignored if asserted on the same clock cycle of set_stb.
//   Example valid and invalid timing:
//              __    __    __    __
//   clk     __|  |__|  |__|  |__|  |__
//               _____
//   set_stb ___|     |________________
//                    _____
//   rb_stb  ________|     |___________     (Valid)
//                           _____
//   rb_stb  _______________|     |____     (Valid)
//           __________________________
//   rb_stb                                 (Valid if readback data is a constant)
//               _____
//   rb_stb  ___|     |________________     (Invalid / ignored, same cycle as set_stb)

module cmd_pkt_proc #(
  parameter SR_AWIDTH = 8,
  parameter SR_DWIDTH = 32,
  parameter RB_AWIDTH = 8,
  parameter RB_USER_AWIDTH = 8,
  parameter RB_DWIDTH = 64,
  parameter USE_TIME = 1,           // 0: Ignore command packet time, 1: Support timed command packets
  // TODO: Eliminate extra readback address output once NoC Shell / user register readback address spaces are merged
  parameter SR_RB_ADDR = 0,         // Settings bus address to set NoC Shell readback address register
  parameter SR_RB_ADDR_USER = 1,    // Settings bus address to set user readback address register
  parameter FIFO_SIZE = 5           // Depth of command FIFO
)(
  input clk, input reset, input clear,
  input [63:0] cmd_tdata, input cmd_tlast, input cmd_tvalid, output cmd_tready,
  output reg [63:0] resp_tdata, output reg resp_tlast, output reg resp_tvalid, input resp_tready,
  input [63:0] vita_time,
  output reg set_stb, output reg [SR_AWIDTH-1:0] set_addr, output reg [SR_DWIDTH-1:0] set_data, output reg [63:0] set_time,
  input rb_stb, input [RB_DWIDTH-1:0] rb_data, output reg [RB_AWIDTH-1:0] rb_addr, output reg [RB_USER_AWIDTH-1:0] rb_addr_user
);

  // Input FIFO
  wire [63:0] cmd_fifo_tdata;
  wire cmd_fifo_tlast, cmd_fifo_tvalid, cmd_fifo_tready;
  axi_fifo #(.WIDTH(65), .SIZE(FIFO_SIZE)) axi_fifo (
    .clk(clk), .reset(reset), .clear(clear),
    .i_tdata({cmd_tlast,cmd_tdata}), .i_tvalid(cmd_tvalid), .i_tready(cmd_tready),
    .o_tdata({cmd_fifo_tlast,cmd_fifo_tdata}), .o_tvalid(cmd_fifo_tvalid), .o_tready(cmd_fifo_tready),
    .space(), .occupied());

  wire [63:0] pkt_vita_time;
  wire [1:0] pkt_type;
  wire has_time;
  wire [11:0] seqnum;
  wire [31:0] sid;
  wire [63:0] int_tdata;
  reg int_tready;
  wire int_tlast, int_tvalid;
  // Extracts header fields and also acts as a register stage latching the header fields until the next packet
  cvita_hdr_parser #(.REGISTER(1)) cvita_hdr_parser (
    .clk(clk), .reset(reset), .clear(clear),
    .hdr_stb(),
    .pkt_type(pkt_type), .eob(), .has_time(has_time),
    .seqnum(seqnum), .pkt_len(), .sid(sid),
    .vita_time_stb(), .vita_time(pkt_vita_time),
    .i_tdata(cmd_fifo_tdata), .i_tlast(cmd_fifo_tlast), .i_tvalid(cmd_fifo_tvalid), .i_tready(cmd_fifo_tready),
    .o_tdata(int_tdata), .o_tlast(int_tlast), .o_tvalid(int_tvalid), .o_tready(int_tready));

  wire [15:0] src_sid = sid[31:16];
  wire [15:0] dst_sid = sid[15:0];
  wire is_cmd_pkt = pkt_type == 2'b10;
  reg is_long_cmd_pkt;

  reg [3:0] state;
  localparam S_CMD_HEAD         = 4'd0;
  localparam S_CMD_TIME         = 4'd1;
  localparam S_CMD_DATA         = 4'd2;
  localparam S_CMD_TIMED_DATA   = 4'd3;
  localparam S_SET_WAIT         = 4'd4;
  localparam S_READBACK         = 4'd5;
  localparam S_RESP_HEAD        = 4'd6;
  localparam S_RESP_TIME        = 4'd7;
  localparam S_RESP_DATA        = 4'd8;
  localparam S_DROP             = 4'd9;

  // Setting the readback address requires special handling in the state machine
  wire set_rb_addr      = int_tdata[SR_AWIDTH-1+32:32] == SR_RB_ADDR[SR_AWIDTH-1:0];
  wire set_rb_addr_user = int_tdata[SR_AWIDTH-1+32:32] == SR_RB_ADDR_USER[SR_AWIDTH-1:0];

  reg [63:0] resp_time;
  wire [63:0] resp_header = {2'b11, USE_TIME[0], 1'b0, seqnum, (USE_TIME[0] ? 16'd24 : 16'd16), dst_sid, src_sid};

  reg [63:0] rb_data_hold;
  integer k;

  reg [63:0] pkt_vita_time_minus2;
  always @(posedge clk) begin
    pkt_vita_time_minus2 <= pkt_vita_time - 2'd2;
  end

  // State machine
  always @(posedge clk) begin
    if (reset) begin
      state           <= S_CMD_HEAD;
      int_tready      <= 1'b0;
      resp_tvalid     <= 1'b0;
      resp_tlast      <= 1'b0;
      resp_tdata      <= 'd0;
      resp_time       <= 'd0;
      set_stb         <= 'd0;
      set_data        <= 'd0;
      set_addr        <= 'd0;
      set_time        <= 'd0;
      rb_addr         <= 'd0;
      rb_addr_user    <= 'd0;
      rb_data_hold    <= 'd0;
      is_long_cmd_pkt <= 1'b0;
    end else begin
      case (state)
        S_CMD_HEAD : begin
          int_tready      <= 1'b1;
          resp_tvalid     <= 1'b0;
          resp_tlast      <= 1'b0;
          set_stb         <= 'd0;
          if (int_tvalid & int_tready) begin
            // Packet must be of correct type and for an existing block port
            if (is_cmd_pkt) begin
              if (has_time) begin
                state    <= S_CMD_TIME;
              end else begin
                set_time <= 64'd0;
                state    <= S_CMD_DATA;
              end
            end else begin
              // Drop all non-command packets.
              if (~int_tlast) begin
                state    <= S_DROP;
              end
            end
          end
        end

        S_CMD_TIME : begin
          if (int_tvalid & int_tready) begin
            if (int_tlast) begin
              // Command packet with time but missing command? Drop it.
              int_tready   <= 1'b0;
              state        <= S_DROP;
            end else begin
              set_time     <= pkt_vita_time;
              if (USE_TIME) begin
                int_tready <= 1'b0;
                state      <= S_CMD_TIMED_DATA;
              end else begin
                int_tready <= 1'b1;
                state      <= S_CMD_DATA;
              end
            end
          end
        end

        S_CMD_TIMED_DATA : begin
          // Offset vita time by 2 to account for register delays
          if (vita_time >= pkt_vita_time_minus2) begin
            int_tready <= 1'b1;
            state      <= S_CMD_DATA;
          end
        end

        S_CMD_DATA : begin
          if (int_tvalid & int_tready) begin
            is_long_cmd_pkt <= ~int_tlast;
            set_addr        <= int_tdata[SR_AWIDTH-1+32:32];
            set_data        <= int_tdata[SR_DWIDTH-1:0];
            // Update rb_addr on same clock cycle as asserting set_stb
            if (set_rb_addr) begin
              rb_addr       <= int_tdata[RB_AWIDTH-1:0];
            end else if (set_rb_addr_user) begin
              rb_addr_user  <= int_tdata[RB_USER_AWIDTH-1:0];
            end
            set_stb         <= 1'b1;
            if (int_tlast) begin
              int_tready    <= 1'b0;
              state         <= S_SET_WAIT;
            // Long command packet support
            end else begin
              int_tready    <= 1'b1;
              state         <= S_CMD_DATA;
            end
          end
        end

        // Wait a clock cycle to allow settings register to output
        S_SET_WAIT : begin
          set_stb <= 1'b0;
          state   <= S_READBACK;
        end

        // Wait for readback data
        S_READBACK : begin
          if (rb_stb) begin
            resp_time    <= vita_time;
            rb_data_hold <= rb_data;
            resp_tlast   <= 1'b0;
            resp_tdata   <= resp_header;
            resp_tvalid  <= 1'b1;
            state        <= S_RESP_HEAD;
          end
        end

        S_RESP_HEAD : begin
          if (resp_tvalid & resp_tready) begin
            resp_tvalid <= 1'b1;
            if (USE_TIME) begin
              resp_tlast <= 1'b0;
              resp_tdata <= resp_time;
              state      <= S_RESP_TIME;
            end else begin
              resp_tlast <= 1'b1;
              resp_tdata <= rb_data_hold;
              state      <= S_RESP_DATA;
            end
          end
        end

        S_RESP_TIME : begin
          if (resp_tvalid & resp_tready) begin
            resp_tlast  <= 1'b1;
            resp_tdata  <= rb_data_hold;
            resp_tvalid <= 1'b1;
            state       <= S_RESP_DATA;
          end
        end

        S_RESP_DATA : begin
          if (resp_tvalid & resp_tready) begin
            resp_tlast  <= 1'b0;
            resp_tvalid <= 1'b0;
            state       <= S_CMD_HEAD;
          end
        end

        // Drop malformed / non-command packets
        S_DROP : begin
          if (int_tvalid & int_tready) begin
            if (int_tlast) begin
              int_tready <= 1'b0;
              state      <= S_CMD_HEAD;
            end
          end
        end

        default : state <= S_CMD_HEAD;
      endcase
    end
  end

endmodule
