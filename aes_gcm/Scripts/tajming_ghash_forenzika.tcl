#------------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Design Name   : tajming_ghash_forenzika
# Tool Version  : Vivado 2025.1
#
# Description   : Answers one question that synth_gcm_ipsec.tcl only measures the
#                 outcome of: a two-cycle GHASH multiply lifts the GHASH unit on its
#                 own from 262.86 to 348.51 MHz, and gcm_enc_glue from 227.46 to
#                 302.18 MHz, yet at fifteen AES cores the same change was worth
#                 9.7 % and in the full IP nothing at all (numbers of the sweep
#                 series this study ran against; see the RTL note below).
#
#                 The sweep reports one worst path per configuration, which is not
#                 enough to say why. This script re-implements a configuration at its
#                 own converged period and then ranks the worst path of every
#                 hierarchy block separately, so the GHASH accumulator loop can be
#                 read next to the AES key expansion and the round-robin dispatcher
#                 rather than only when it happens to win.
#
#                 What it prints per configuration:
#                   * the twenty worst setup paths, with delay split into logic and
#                     routing
#                   * the worst path of each block, bucketed by instance name, with
#                     how far behind the critical path it is
#                   * routing congestion after placement
#
# Usage         : vivado -mode batch -source Scripts/tajming_ghash_forenzika.tcl
#                 vivado -mode batch -source Scripts/tajming_ghash_forenzika.tcl -tclargs kripto_enc
#
# Output        : Results/tajming_ghash_forenzika/<config>/{paths.rpt,blocks.csv,
#                                                           congestion.rpt,critical.rpt}
#
# Notes         : The flow, the part and the file list are copied from
#                 synth_gcm_ipsec.tcl on purpose, so a number here can be compared
#                 with a number there. The period is fixed at the value that sweep
#                 converged to, because a path delay only means something at the
#                 constraint the tool was optimising under.
#
#                 The recorded runs were taken while the glue temporarily carried
#                 the pipeline register on the length strobe, so their one-core
#                 rows correspond to the _reg rows of the sweep. That register was
#                 later reverted, so a rerun on the current RTL
#                 corresponds to the plain one-core rows instead.
#
# Revision      :
#   0.01 - August 2026 - File Created
#------------------------------------------------------------------------------------

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set HW   $ROOT/Hardware
set AES  $HW/ip_cores/AES_ALGORITHM/src
set ENC  $HW/ip_cores/GCM_GLUE_ENC/src
set DEC  $HW/ip_cores/GCM_GLUE_DEC/src
set L3   $HW/ip_cores/L3_WRAPPER_IP_CORES
set TOPS $HW/synth_tops
set LIB  $HW/tests/gcm_core_AES/_lib
set OUT  $ROOT/Results/tajming_ghash_forenzika

set PART xck26-sfvc784-2LV-c

set AES_BITS     256
set ROUND_STYLE  LUT
set FLOW_STYLE   GLOBAL
set WRAPPER_KIND MULTICORE
set DATA_WIDTH   128
set BYPASS_BYTES 34
set AAD_BYTES    16
set AAD_BEATS    [expr {($AAD_BYTES + $DATA_WIDTH/8 - 1) / ($DATA_WIDTH/8)}]

# {name top level kind mult_cycles num_cores period_ns}
# The period is the one synth_gcm_ipsec.tcl had converged to for that row when
# this study ran.  Two rows no longer match the current sweep CSV: the
# fifteen-core periods come from the series measured before the multicore
# wrapper revision (archived as aes_gcm_ipsec_stari_omotac.csv), and the plain
# one-core row carries the period of its _reg twin, per the RTL note in the
# header.
set CONFIGS {
    {kripto_enc       gcm_enc  kripto  enc  1  15  4.545}
    {kripto_enc_m2    gcm_enc  kripto  enc  2  15  4.225}
    {kripto_enc_c1    gcm_enc  kripto  enc  1   1  4.422}
    {kripto_enc_c1_m2 gcm_enc  kripto  enc  2   1  3.372}
}

set VHDL_FILES [list \
    $AES/aes_pkg.vhd \
    $AES/key_expansion.vhd \
    $AES/aes_round_column.vhd \
    $AES/aes_round.vhd \
    $AES/aes_enc_rolled.vhd \
    $AES/aes_enc_pipelined.vhd \
    $AES/AES_multicore_wrapper.vhd \
    $AES/AES_pipelined_wrapper.vhd \
    $AES/AES_algorithm.vhd \
    $ENC/GF2_karatsuba_16.vhd \
    $ENC/GF_karatsuba_32.vhd \
    $ENC/GF_Karatsuba_64.vhd \
    $ENC/GF2_Karatsuba_128.vhd \
    $ENC/GF2_Reduction_128.vhd \
    $ENC/GF_multiplier.vhd \
    $ENC/GHASH_single.vhd \
    $ENC/GHASH_pipelined.vhd \
    $ENC/GHASH.vhd \
    $ENC/GHASH_wrapper.vhd \
    $ENC/AXIS_skid_buffer.vhd \
    $ENC/axis_broadcaster.vhd \
    $ENC/AXIS_DEMUX.vhd \
    $ENC/AXIS_GHASH_MUX.vhd \
    $ENC/AXIS_MUX.vhd \
    $ENC/Tag_Finalizer.vhd \
    $ENC/gcm_enc_glue.vhd \
    $DEC/AXIS_DEMUX_dec.vhd \
    $DEC/AXIS_MUX_DEC.vhd \
    $DEC/Tag_Verifier.vhd \
    $DEC/gcm_dec_glue.vhd \
    $L3/SPLIT_demux/src/util_split.vhd \
    $L3/SPLIT_demux/src/SPLIT_demux.vhd \
    $L3/MERGE_mux/src/util_merge.vhd \
    $L3/MERGE_mux/src/MERGE_mux.vhd \
    $L3/ICV_realign/src/ICV_realign.vhd \
    $L3/AXIS_full_skid_buffer/src/AXIS_full_skid_buffer.vhd \
    $LIB/gcm_composites.vhd \
    $TOPS/ipsec_gcm_enc_top.vhd \
    $TOPS/ipsec_gcm_dec_top.vhd ]

#------------------------------------------------------------------------------------
# Wrapper generator, identical to the one in synth_gcm_ipsec.tcl but trimmed to the
# crypto level, which is the only level this study needs.
#------------------------------------------------------------------------------------
proc write_wrapper {path top kind mult cores} {
    global AES_BITS ROUND_STYLE FLOW_STYLE WRAPPER_KIND DATA_WIDTH AAD_BYTES AAD_BEATS

    set fh [open $path w]
    puts $fh "-- generated by tajming_ghash_forenzika.tcl -- do not edit"
    puts $fh "library ieee;"
    puts $fh "use ieee.std_logic_1164.all;"
    puts $fh ""
    puts $fh "entity gcm_cfg_top is"
    puts $fh "    port ("
    puts $fh "        i_clk         : in  std_logic;"
    puts $fh "        i_rstn        : in  std_logic;"
    puts $fh "        i_key         : in  std_logic_vector(255 downto 0);"
    puts $fh "        i_key_valid   : in  std_logic;"
    puts $fh "        i_nonce       : in  std_logic_vector(95 downto 0);"
    puts $fh "        i_nonce_valid : in  std_logic;"
    puts $fh "        s_axis_tdata  : in  std_logic_vector([expr {$DATA_WIDTH - 1}] downto 0);"
    puts $fh "        s_axis_tkeep  : in  std_logic_vector([expr {$DATA_WIDTH/8 - 1}] downto 0);"
    puts $fh "        s_axis_tvalid : in  std_logic;"
    puts $fh "        s_axis_tlast  : in  std_logic;"
    puts $fh "        s_axis_tready : out std_logic;"
    puts $fh "        m_axis_tdata  : out std_logic_vector([expr {$DATA_WIDTH - 1}] downto 0);"
    puts $fh "        m_axis_tkeep  : out std_logic_vector([expr {$DATA_WIDTH/8 - 1}] downto 0);"
    puts $fh "        m_axis_tvalid : out std_logic;"
    puts $fh "        m_axis_tlast  : out std_logic;"
    puts $fh "        m_axis_tready : in  std_logic"
    if {$kind eq "dec"} {
        puts $fh "        ;o_auth_ok     : out std_logic"
        puts $fh "        ;o_dec_done    : out std_logic"
    }
    puts $fh "    );"
    puts $fh "end entity;"
    puts $fh ""
    puts $fh "architecture rtl of gcm_cfg_top is"
    puts $fh "begin"
    puts $fh "    u_dut : entity work.$top"
    puts $fh "        generic map ("
    puts $fh "            AES_BITS     => $AES_BITS,"
    puts $fh "            ROUND_STYLE  => \"$ROUND_STYLE\","
    puts $fh "            FLOW_STYLE   => \"$FLOW_STYLE\","
    puts $fh "            WRAPPER_KIND => \"$WRAPPER_KIND\","
    puts $fh "            NUM_CORES    => $cores,"
    puts $fh "            AAD_BEATS    => $AAD_BEATS,"
    puts $fh "            AAD_BYTES    => $AAD_BYTES,"
    puts $fh "            MULT_CYCLES  => $mult,"
    puts $fh "            DATA_WIDTH   => $DATA_WIDTH"
    puts $fh "        )"
    puts $fh "        port map ("
    puts $fh "            i_clk => i_clk, i_rstn => i_rstn,"
    puts $fh "            i_key => i_key, i_key_valid => i_key_valid,"
    puts $fh "            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,"
    puts $fh "            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,"
    puts $fh "            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,"
    puts $fh "            s_axis_tready => s_axis_tready,"
    puts $fh "            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,"
    puts $fh "            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,"
    puts $fh "            m_axis_tready => m_axis_tready"
    if {$kind eq "dec"} {
        puts $fh "            ,o_auth_ok => o_auth_ok, o_dec_done => o_dec_done"
    }
    puts $fh "        );"
    puts $fh "end architecture;"
    close $fh
}

#------------------------------------------------------------------------------------
# Buckets a path endpoint into the block it belongs to. The order matters, the first
# match wins, so the more specific patterns come first.
#------------------------------------------------------------------------------------
proc block_of {pin} {
    foreach {pat name} {
        {u_ghash/u_ghash/gen_pipelined} "GHASH multiplier, two cycles"
        {u_ghash/u_ghash/gen_single}    "GHASH accumulator, one cycle"
        {u_ghash}                       "GHASH control"
        {u_ke}                          "AES key expansion"
        {gen_cores}                     "AES core, round"
        {gen_multicore}                 "AES core dispatch"
        {u_aes}                         "AES other"
        {u_demux}                       "AXIS demultiplexer"
        {u_mux}                         "AXIS multiplexer"
        {u_tag}                         "tag computation"
        {u_skid}                        "skid buffer"
        {u_split}                       "SPLIT_demux"
        {u_merge}                       "MERGE_mux"
        {u_icv}                         "ICV_realign"
    } {
        if {[string first $pat $pin] >= 0} { return $name }
    }
    return "other"
}

#------------------------------------------------------------------------------------
# Driver
#------------------------------------------------------------------------------------
file mkdir $OUT
set only [lindex $argv 0]

foreach cfg $CONFIGS {
    lassign $cfg name top level kind mult cores period

    if {$only ne "" && $only ne $name} { continue }

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir
    puts "=================================================================="
    puts "== $name : MULT_CYCLES=$mult NUM_CORES=$cores period=$period ns"
    puts "=================================================================="

    write_wrapper $cfg_dir/cfg_top.vhd $top $kind $mult $cores

    set fh [open $cfg_dir/clock.xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period] \[get_ports i_clk\]"
    close $fh

    create_project -in_memory -part $PART
    read_vhdl -vhdl2008 -library work $VHDL_FILES
    read_vhdl -vhdl2008 -library work $cfg_dir/cfg_top.vhd
    read_xdc $cfg_dir/clock.xdc

    synth_design -top gcm_cfg_top -part $PART -mode out_of_context
    opt_design
    place_design

    # Congestion is a placement property, so it is taken before routing perturbs it.
    report_design_analysis -congestion -file $cfg_dir/congestion.rpt -quiet

    phys_opt_design
    route_design

    # Twenty worst paths in full, for reading by hand.
    report_timing -setup -max_paths 20 -nworst 1 -path_type full_clock_expanded \
                  -file $cfg_dir/paths.rpt

    # The critical path alone, with every cell on it.
    report_timing -setup -max_paths 1 -nworst 1 -input_pins -file $cfg_dir/critical.rpt

    # Worst path of every block. Four hundred endpoints is far more than the design
    # has distinct blocks, so every block that carries a path shows up.
    set paths [get_timing_paths -setup -max_paths 400 -nworst 1 -quiet]
    set best  [dict create]
    foreach p $paths {
        set ep    [get_property ENDPOINT_PIN $p]
        set sp    [get_property STARTPOINT_PIN $p]
        set slack [get_property SLACK $p]
        set blk   [block_of $ep]
        if {![dict exists $best $blk] || $slack < [dict get $best $blk slack]} {
            dict set best $blk [dict create slack $slack \
                                            delay [get_property DATAPATH_DELAY $p] \
                                            levels [get_property LOGIC_LEVELS $p] \
                                            src $sp dst $ep]
        }
    }

    set worst 1e9
    dict for {blk d} $best {
        if {[dict get $d slack] < $worst} { set worst [dict get $d slack] }
    }

    set fh [open $cfg_dir/blocks.csv w]
    puts $fh "config,mult_cycles,num_cores,period_ns,block,slack_ns,gap_to_critical_ns,delay_ns,logic_levels,startpoint,endpoint"
    set rows {}
    dict for {blk d} $best {
        lappend rows [list [dict get $d slack] $blk $d]
    }
    foreach row [lsort -real -index 0 $rows] {
        lassign $row slack blk d
        puts $fh "$name,$mult,$cores,$period,\"$blk\",[format %.3f $slack],[format %.3f [expr {$slack - $worst}]],[format %.3f [dict get $d delay]],[dict get $d levels],[dict get $d src],[dict get $d dst]"
        puts [format "  %-32s slack %7.3f  gap %6.3f  delay %6.3f  levels %2d" \
              $blk $slack [expr {$slack - $worst}] [dict get $d delay] [dict get $d levels]]
    }
    close $fh

    close_project
}

puts "DONE -- results in $OUT"
