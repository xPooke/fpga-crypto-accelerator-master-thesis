#------------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Design Name   : synth_gcm_final
# Tool Version  : Vivado 2025.1
#
# Description   : The closing AES-GCM table. One operating point, the GHASH multiply
#                 in a single cycle, measured for both directions and on both levels,
#                 with the two AES wrappers side by side:
#
#                   UNROLLED, one pipelined core : one block per clock from a fully
#                                                  unrolled pipeline
#
#                 The matching MULTICORE rows, fifteen rolled cores sharing one key
#                 expansion, are already measured and live in
#                 Results/synth_gcm_ipsec/results.csv. Only the unrolled half is new.
#
#                 synth_gcm_ipsec.tcl answered whether the two-cycle multiply is
#                 worth it. It is not: at fifteen cores the worst path is already in
#                 the AES block, so halving the GHASH loop buys 9.7 percent of clock
#                 for half the throughput. That question is closed and the two-cycle
#                 rows stay where they were measured. This sweep only reports the
#                 configuration that ships.
#
#                 A pipeline register on the length strobe was tried in the glue and
#                 since reverted: at fifteen cores it was worth 222.47
#                 against 222.10 MHz, a fifth of a percent where the tool noise is
#                 over three. The current RTL therefore matches the one the earlier
#                 multicore rows measured, and those rows stand.
#
# Usage         : vivado -mode batch -source Scripts/synth_gcm_final.tcl
#                 vivado -mode batch -source Scripts/synth_gcm_final.tcl -tclargs unr_ipsec_dec
#                 SYNTH_START_MHZ=240 vivado -mode batch -source Scripts/synth_gcm_final.tcl
#
# Output        : Results/synth_gcm_final/results.csv
#                 Results/synth_gcm_final/<config>/{cfg_top.vhd,clock.xdc,*.rpt}
#
# Notes         : Methodology, part and file list are identical to
#                 synth_gcm_ipsec.tcl and synth_aes_core.tcl, because all three feed
#                 the same tables. The helper procedures are duplicated on purpose so
#                 that no script can break another.
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
set OUT  $ROOT/Results/synth_gcm_final

set PART       xck26-sfvc784-2LV-c   ;# Kria K26 SOM (KR260), same part as the other sweeps
set START_MHZ  230.0                 ;# just above glue_c1 = 227 MHz, the part expected to bind
set MAX_PASSES 5
set SLACK_EPS  0.050
set RESUME     1

# Operating point, fixed for every configuration in this sweep.
set AES_BITS     256
set ROUND_STYLE  LUT
set FLOW_STYLE   GLOBAL
set DATA_WIDTH   128
set BYPASS_BYTES 34
set AAD_BYTES    16
set AAD_BEATS    [expr {($AAD_BYTES + $DATA_WIDTH/8 - 1) / ($DATA_WIDTH/8)}]

if {[info exists ::env(SYNTH_START_MHZ)]} {
    set START_MHZ [expr {double($::env(SYNTH_START_MHZ))}]
    puts "-- START_MHZ overridden via the environment: $START_MHZ MHz"
}

# {name top level kind mult_cycles num_cores wrapper_kind}
# Only the unrolled rows are here. The four multicore rows of the same operating
# point are already in Results/synth_gcm_ipsec/results.csv and match the current
# RTL: the pipeline register on the length strobe tried in between was reverted
# (since reverted), because at fifteen cores it moved 222.10 to 222.47 MHz, 0.17 percent
# against a tool noise of 3.4 percent. Repeating them would burn an hour to move
# nothing.
#
# NUM_CORES is carried for the table but the pipelined wrapper has no core array and
# ignores it.
set CONFIGS {
    {unr_kripto_enc  gcm_enc            kripto  enc  1  15  UNROLLED}
    {unr_kripto_dec  gcm_dec            kripto  dec  1  15  UNROLLED}
    {unr_ipsec_enc   ipsec_gcm_enc_top  ipsec   enc  1  15  UNROLLED}
    {unr_ipsec_dec   ipsec_gcm_dec_top  ipsec   dec  1  15  UNROLLED}
}

# Shared modules live byte-identical in both glue folders, so the ENC copy is read
# and only the four decrypt-specific files are taken from the DEC folder. The same
# holds for util_merge.vhd, which sits in both MERGE_mux and ICV_realign.
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
# Report helpers. Kept identical to synth_aes_core.tcl on purpose.
#------------------------------------------------------------------------------------
proc util_row {rpt name} {
    foreach line [split $rpt "\n"] {
        if {[regexp "^\\s*\\|\\s*[string map {( \\( ) \\)} $name]\\s*\\|\\s*(\[0-9\]+)" $line -> used]} {
            return $used
        }
    }
    return 0
}

proc worst_setup_slack {} {
    set paths [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
    if {[llength $paths] == 0} { return 0.0 }
    return [get_property SLACK [lindex $paths 0]]
}

proc total_power {rpt} {
    foreach line [split $rpt "\n"] {
        if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $line -> w]} { return $w }
    }
    return 0.0
}

#------------------------------------------------------------------------------------
# Wrapper generator. The port list follows the device under test, so nothing is
# optimised away for being unconnected at the boundary.
#------------------------------------------------------------------------------------
proc write_wrapper {path top level kind mult cores wrapper} {
    global AES_BITS ROUND_STYLE FLOW_STYLE
    global DATA_WIDTH BYPASS_BYTES AAD_BYTES AAD_BEATS

    set fh [open $path w]
    puts $fh "-- generated by synth_gcm_final.tcl -- do not edit"
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
        if {$level eq "ipsec"} {
            puts $fh "        ;o_DEC_in_proc : out std_logic"
        }
    } elseif {$level eq "ipsec"} {
        puts $fh "        ;o_ENC_in_proc : out std_logic"
        puts $fh "        ;o_TxENC       : out std_logic_vector(31 downto 0)"
    }
    puts $fh "    );"
    puts $fh "end entity;"
    puts $fh ""
    puts $fh "architecture rtl of gcm_cfg_top is"
    puts $fh "begin"
    puts $fh "    u_dut : entity work.$top"
    puts $fh "        generic map ("

    if {$level eq "kripto"} {
        # gcm_enc / gcm_dec composites: key port is AES_BITS wide, no frame logic.
        puts $fh "            AES_BITS     => $AES_BITS,"
        puts $fh "            ROUND_STYLE  => \"$ROUND_STYLE\","
        puts $fh "            FLOW_STYLE   => \"$FLOW_STYLE\","
        puts $fh "            WRAPPER_KIND => \"$wrapper\","
        puts $fh "            NUM_CORES    => $cores,"
        puts $fh "            AAD_BEATS    => $AAD_BEATS,"
        puts $fh "            AAD_BYTES    => $AAD_BYTES,"
        puts $fh "            MULT_CYCLES  => $mult,"
        puts $fh "            DATA_WIDTH   => $DATA_WIDTH"
    } else {
        puts $fh "            DATA_WIDTH   => $DATA_WIDTH,"
        puts $fh "            BYPASS_EN    => true,"
        puts $fh "            BYPASS_BYTES => $BYPASS_BYTES,"
        puts $fh "            AAD_BYTES    => $AAD_BYTES,"
        puts $fh "            MULT_CYCLES  => $mult,"
        puts $fh "            AES_BITS     => $AES_BITS,"
        puts $fh "            ROUND_STYLE  => \"$ROUND_STYLE\","
        puts $fh "            FLOW_STYLE   => \"$FLOW_STYLE\","
        puts $fh "            WRAPPER_KIND => \"$wrapper\","
        puts $fh "            NUM_CORES    => $cores"
    }

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
        if {$level eq "ipsec"} {
            puts $fh "            ,o_DEC_in_proc => o_DEC_in_proc"
        }
    } elseif {$level eq "ipsec"} {
        puts $fh "            ,o_ENC_in_proc => o_ENC_in_proc, o_TxENC => o_TxENC"
    }
    puts $fh "        );"
    puts $fh "end architecture;"
    close $fh
}

#------------------------------------------------------------------------------------
# One implementation pass at a given clock period.
#------------------------------------------------------------------------------------
proc run_pass {cfg_dir period_ns vhdl_files part} {
    set xdc $cfg_dir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period_ns] \[get_ports i_clk\]"
    if {[info exists ::env(SYNTH_IO_DELAY)]} {
        set d [format %.3f [expr {double($::env(SYNTH_IO_DELAY))}]]
        puts $fh "set_input_delay  -clock clk $d \[filter \[all_inputs\]  {NAME !~ \"i_clk\"}\]"
        puts $fh "set_output_delay -clock clk $d \[all_outputs\]"
    }
    close $fh

    create_project -in_memory -part $part
    read_vhdl -vhdl2008 -library work $vhdl_files
    read_vhdl -vhdl2008 -library work $cfg_dir/cfg_top.vhd
    read_xdc $xdc

    synth_design -top gcm_cfg_top -part $part -mode out_of_context
    opt_design
    place_design
    phys_opt_design
    route_design

    set util  [report_utilization -return_string]
    set power [report_power -return_string]

    set fh [open $cfg_dir/utilization.rpt w] ; puts $fh $util ; close $fh
    set fh [open $cfg_dir/power.rpt w]       ; puts $fh $power ; close $fh
    report_timing_summary -file $cfg_dir/timing.rpt

    set luts [util_row $util "CLB LUTs"]
    if {$luts == 0} { set luts [util_row $util "Slice LUTs"] }
    set ffs  [util_row $util "CLB Registers"]
    if {$ffs == 0}  { set ffs  [util_row $util "Slice Registers"] }
    set lutram [util_row $util "LUT as Memory"]
    set bram   [util_row $util "Block RAM Tile"]
    set dsp    [util_row $util "DSPs"]

    set wns  [worst_setup_slack]
    set fmax [expr {1000.0 / ($period_ns - $wns)}]

    set res [dict create period $period_ns wns $wns fmax $fmax \
                        luts $luts lutram $lutram ffs $ffs bram $bram dsp $dsp \
                        power [total_power $power]]
    close_project
    return $res
}

#------------------------------------------------------------------------------------
# Driver
#------------------------------------------------------------------------------------
file mkdir $OUT
set csv_path $OUT/results.csv
set csv_hdr "config,top,nivo,smer,wrapper_kind,num_cores,mult_cycles,aes_bits,round_style,bypass_B,aad_B,start_MHz,period_ns,WNS_ns,Fmax_MHz,LUT,LUTRAM,FF,BRAM,DSP,power_W,throughput_Gbps,passes"

set only ""
if {[llength $argv] > 0} { set only [lindex $argv 0] }

set keep {}
set have {}
if {[file exists $csv_path]} {
    set fh [open $csv_path r]
    set lines [split [read $fh] "\n"]
    close $fh
    if {[llength $lines] > 0 && [string trimright [lindex $lines 0] "\r"] eq $csv_hdr} {
        foreach line [lrange $lines 1 end] {
            set line [string trimright $line "\r"]
            if {$line eq ""} { continue }
            set row_name [lindex [split $line ","] 0]
            if {$row_name eq $only} { continue }
            lappend keep $line
            lappend have $row_name
        }
    } else {
        puts "  -- results.csv was written with an older header, starting over"
    }
}
if {$only eq "" && !$RESUME} { set keep {} ; set have {} }

set csv [open $csv_path w]
puts $csv $csv_hdr
foreach line $keep { puts $csv $line }
if {[llength $keep] > 0} {
    puts "  -- kept [llength $keep] existing rows kept in results.csv"
}
flush $csv

puts "== synth_gcm_final =="
puts "   [version -short]"
puts "   part $PART, seed $START_MHZ MHz"
puts "   points: UNROLLED, MULT_CYCLES 1, $ROUND_STYLE, AES-$AES_BITS"
puts "   IPsec ESP tunnel: bypass $BYPASS_BYTES B, AAD $AAD_BYTES B ($AAD_BEATS words)"

foreach cfg $CONFIGS {
    lassign $cfg name top level kind mult cores wrapper

    if {$only ne "" && $name ne $only} { continue }
    if {$only eq "" && [lsearch -exact $have $name] >= 0} {
        puts "  -- $name is already in results.csv, skipping"
        continue
    }

    puts ""
    puts "############ $name   (top $top, level $level, direction $kind, wrapper $wrapper, MULT_CYCLES $mult, NUM_CORES $cores)"

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir
    write_wrapper $cfg_dir/cfg_top.vhd $top $level $kind $mult $cores $wrapper

    set period [expr {1000.0 / $START_MHZ}]
    set best   ""
    set passes 0
    for {set p 0} {$p < $MAX_PASSES} {incr p} {
        puts "  -- pass [expr {$p + 1}] at period [format %.3f $period] ns"
        set res [run_pass $cfg_dir $period $VHDL_FILES $PART]
        incr passes
        set wns [dict get $res wns]
        if {$wns > -0.001} {
            set best $period
            set best_res $res
            if {$wns < $SLACK_EPS} { break }
            set period [expr {$period - $wns + $SLACK_EPS}]
        } else {
            if {$best eq ""} {
                set period [expr {$period - $wns + $SLACK_EPS}]
            } else {
                break
            }
        }
    }
    if {$best eq ""} {
        puts "  !! no pass closed timing for $name"
        set best_res $res
    }
    set res $best_res

    # One block per clock at NUM_CORES = N_r+1 and a single-cycle GHASH multiply.
    set nr  [expr {$AES_BITS / 32 + 6}]
    if {$wrapper eq "UNROLLED"} {
        set bpc 1.0
    } else {
        set bpc [expr {double($cores) / ($nr + 1)}]
    }
    if {$bpc > 1.0} { set bpc 1.0 }
    if {$bpc > 1.0 / $mult} { set bpc [expr {1.0 / $mult}] }
    set gbps [expr {$bpc * 128.0 * [dict get $res fmax] / 1000.0}]

    puts $csv [format "%s,%s,%s,%s,%s,%d,%d,%d,%s,%d,%d,%.1f,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%.3f,%.2f,%d" \
        $name $top $level $kind $wrapper $cores $mult $AES_BITS $ROUND_STYLE \
        $BYPASS_BYTES $AAD_BYTES $START_MHZ \
        [dict get $res period] [dict get $res wns] [dict get $res fmax] \
        [dict get $res luts] [dict get $res lutram] [dict get $res ffs] \
        [dict get $res bram] [dict get $res dsp] [dict get $res power] \
        $gbps $passes]
    flush $csv

    puts [format "  == %s: %d LUT, %d FF, %d BRAM, Fmax %.2f MHz, %.2f Gb/s (%d passes)" \
        $name [dict get $res luts] [dict get $res ffs] [dict get $res bram] \
        [dict get $res fmax] $gbps $passes]
}

close $csv
puts ""
puts "== done -> $csv_path"
