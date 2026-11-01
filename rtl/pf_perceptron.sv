// Online, source-banked perceptron admission filter. Metadata is {source,x[7:0]}.
// Binary features encode bipolar inputs: bit 1 => +1, bit 0 => -1.
// Feedback is ONLY from installed lines, never from a dropped queue candidate.
`default_nettype none
module pf_perceptron #(
  parameter bit ENABLE = 0,
  parameter int MARGIN = 16,
  parameter int EXPLORE_LOG2 = 5
)(
  input wire clk, rst_n,
  input wire candidate,
  input wire [9:0] meta,
  output wire allow,
  input wire useful, useless,
  input wire [9:0] useful_meta, useless_meta
);
  // Bank zero is unused; retained to avoid source-minus-one indexing logic.
  logic signed [5:0] weights [4][9];
  logic signed [5:0] next_weights [4][9];
  logic [EXPLORE_LOG2-1:0] reject_clock;
  logic [31:0] candidates, rejected, explored, positive, negative, updates;
  integer score, train_score, bank, delta;
  logic [1:0] nupdate;
  logic [9:0] train_meta;
  logic explore;

  function automatic logic signed [5:0] sat(input integer v);
    if (v > 31) sat = 6'sd31;
    else if (v < -32) sat = -6'sd32;
    else sat = 6'(v);
  endfunction

  always_comb begin
    score = int'($signed(weights[meta[9:8]][0]));
    for (int k=0;k<8;k++)
      score = score + (meta[k] ? int'($signed(weights[meta[9:8]][k+1])) :
                                -int'($signed(weights[meta[9:8]][k+1])));
  end
  assign explore = (reject_clock == '0);
  assign allow = !ENABLE || score >= 0 || explore;

  // Two feedback events may coincide. Apply useful then useless to next state,
  // so neither is silently overwritten when both refer to the same bank.
  always_comb begin
    for (int b=0;b<4;b++)
      for (int k=0;k<9;k++) next_weights[b][k] = weights[b][k];
    nupdate=0; train_meta=0; bank=0; train_score=0; delta=0;
    for (int e=0;e<2;e++) begin
      train_meta = (e==0) ? useful_meta : useless_meta;
      bank = int'(train_meta[9:8]);
      train_score = int'($signed(next_weights[bank][0]));
      for (int k=0;k<8;k++)
        train_score += train_meta[k] ? int'($signed(next_weights[bank][k+1])) :
                                      -int'($signed(next_weights[bank][k+1]));
      if (ENABLE && bank != 0 && ((e==0 && useful) || (e==1 && useless)) &&
          ((e==0 && train_score <= MARGIN) || (e==1 && train_score >= -MARGIN))) begin
        delta = (e==0) ? 1 : -1;
        next_weights[bank][0] = sat(int'($signed(next_weights[bank][0]))+delta);
        for (int k=0;k<8;k++)
          next_weights[bank][k+1] = sat(int'($signed(next_weights[bank][k+1])) +
                                      (train_meta[k] ? delta : -delta));
        nupdate = nupdate + 1'b1;
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b=0;b<4;b++)
        for (int k=0;k<9;k++) weights[b][k] <= (k==0) ? 6'sd8 : 6'sd0;
      reject_clock <= '0;
      candidates<=0; rejected<=0; explored<=0;
      positive<=0; negative<=0; updates<=0;
    end else if (ENABLE) begin
      for (int b=0;b<4;b++)
        for (int k=0;k<9;k++) weights[b][k] <= next_weights[b][k];
      updates <= updates + {30'd0,nupdate};
      if (useful) positive <= positive+1'b1;
      if (useless) negative <= negative+1'b1;
      if (candidate) begin
        candidates <= candidates+1'b1;
        if (score < 0) begin
          reject_clock <= reject_clock+1'b1;
          if (explore) explored <= explored+1'b1;
          else rejected <= rejected+1'b1;
        end
      end
    end
  end
endmodule
`default_nettype wire
