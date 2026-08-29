# ----------------------------------------------------------------------------
# synth_aes_core.tcl - out-of-context synthesis + implementation sweep over the
# AES-256 cipher core (AES_algorithm) on its own, without the GCM glue.
#
# Purpose: produce the resource / fmax numbers behind the Multicore-vs-Pipeline
# comparison in the thesis. Throughput is NOT taken from here -- it is measured
# cycle-accurately in simulation (bits per clock) and multiplied by the fmax
# this script reports, the same methodology used for the SHA-3 accelerator.
#
# Usage (from the aes_gcm folder root):
#   vivado -mode batch -source Scripts/synth_aes_core.tcl
#   vivado -mode batch -source Scripts/synth_aes_core.tcl -tclargs unrolled_bram_global
#       (optional: run a single configuration by name)
#
# Output: Results/synth_aes_core/
#   results.csv                      one row per configuration (the thesis table)
#   <config>/utilization.rpt         full utilization report
#   <config>/timing.rpt              timing summary
#   <config>/power.rpt               power estimate
#
# Methodology: clock constraint ONLY, no set_input_delay / set_output_delay, and
#   fmax found by tightening the period rather than by meeting a fixed target.
#   Both choices match sha3/Scripts/synth_sha3_core.tcl, which is what lets the
#   thesis put the three cores in one table.
#
#   The quantity being characterised is the core's own critical path, so the
#   interface budget is deliberately left out.  And a met constraint makes the
#   tools stop optimising: a relaxed target measures the constraint, not the
#   design.  Each configuration therefore starts at START_MHZ and then aims at
#   the period the previous pass implies, up to MAX_PASSES times; the tightest
#   pass that closed timing is the one reported, as Fmax = 1000 / (period - WNS).
#
#   Numbers are read AFTER route_design, so they are post-implementation, never
#   post-synthesis.  Power is a vectorless estimate: report_power runs without a
#   SAIF, hence with default switching activity.
#
# Notes
#   * Every configuration is driven through a generated wrapper with a fixed
#     generic map instead of synth_design -generic. String generics through
#     -generic are quoting-sensitive across Vivado versions; a wrapper is
#     unambiguous and leaves the reported resources unchanged (it adds no
#     logic, only a hierarchy level).
# ----------------------------------------------------------------------------

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set SRC  $ROOT/Hardware/ip_cores/AES_ALGORITHM/src
set OUT  $ROOT/Results/synth_aes_core

set PART       xck26-sfvc784-2LV-c   ;# Kria K26 SOM (KR260), same part as SHA-3
# Constrain aggressively from the first pass; the search below tightens from
# there.  Vivado optimises to the constraint and no further, so a relaxed seed
# measures the constraint, not the design, and each pass gains only ~0.1 ns.
# 400 MHz is the same seed the SHA-3 sweep uses for architecture I; the wide
# configurations miss it and back off, which costs one pass, while the narrow
# ones save several.
set START_MHZ  400.0
set MAX_PASSES 5                     ;# starting target, then up to four corrections
set SLACK_EPS  0.050                 ;# stop once within 50 ps of the target
set RESUME     1                     ;# 1 = keep rows already in results.csv, skip those configs
set AES_BITS   256                   ;# AES-256 only, per the thesis scope

# START_MHZ is the seed of the search, not a target that gets reported: the loop
# tightens away from it until timing stops closing.  A configuration that spends
# every pass with slack still well above SLACK_EPS stopped on the pass count and
# not on convergence, and reseeding it near its own measured Fmax makes it
# converge in a pass or two instead of five.  SYNTH_START_MHZ in the environment
# does that for one rerun; unset, the sweep behaves exactly as it did before.
if {[info exists ::env(SYNTH_START_MHZ)]} {
    set START_MHZ [expr {double($::env(SYNTH_START_MHZ))}]
    puts "-- START_MHZ overridden via the environment: $START_MHZ MHz"
}

# ----------------------------------------------------------------------------
# Configuration list
#   name                     WRAPPER_KIND  ROUND_STYLE  FLOW_STYLE  NUM_CORES
# UNROLLED: every combination of round style and flow control.
# MULTICORE: core counts chosen around the GHASH ceilings.  A rolled core is
#   busy NR+1 clocks per block, not NR: NR clocks of rounds plus one clock in
#   S_DONE holding the result until the wrapper takes it.  So a c-core wrapper
#   retires c/(NR+1) blocks/clk, and with NR = 14 the ceilings sit at c = 8
#   (8/15 = 0.53, just over the two-cycle GHASH ceiling of 0.5) and c = 15
#   (15/15 = 1.0, the single-cycle GHASH ceiling).  c = 7 and c = 14, which an
#   earlier c/NR reading made look exact, in fact give 0.47 and 0.93; both are
#   kept because the simulation series measured them.
# ----------------------------------------------------------------------------
set CONFIGS {
    {unrolled_bram_global      UNROLLED   BRAM  GLOBAL      0}
    {unrolled_bram_perstage    UNROLLED   BRAM  PER_STAGE   0}
    {unrolled_lut_global       UNROLLED   LUT   GLOBAL      0}
    {unrolled_lut_perstage     UNROLLED   LUT   PER_STAGE   0}

    {multicore_bram_c1         MULTICORE  BRAM  GLOBAL      1}
    {multicore_bram_c2         MULTICORE  BRAM  GLOBAL      2}
    {multicore_bram_c4         MULTICORE  BRAM  GLOBAL      4}
    {multicore_bram_c7         MULTICORE  BRAM  GLOBAL      7}
    {multicore_bram_c14        MULTICORE  BRAM  GLOBAL     14}
    {multicore_bram_c15        MULTICORE  BRAM  GLOBAL     15}

    {multicore_lut_c1          MULTICORE  LUT   GLOBAL      1}
    {multicore_lut_c2          MULTICORE  LUT   GLOBAL      2}
    {multicore_lut_c4          MULTICORE  LUT   GLOBAL      4}
    {multicore_lut_c5          MULTICORE  LUT   GLOBAL      5}
    {multicore_lut_c7          MULTICORE  LUT   GLOBAL      7}
    {multicore_lut_c8          MULTICORE  LUT   GLOBAL      8}
    {multicore_lut_c14         MULTICORE  LUT   GLOBAL     14}
    {multicore_lut_c15         MULTICORE  LUT   GLOBAL     15}
}

# Source files, package first so VHDL analysis order is never in question.
set VHDL_FILES [list \
    $SRC/aes_pkg.vhd \
    $SRC/key_expansion.vhd \
    $SRC/aes_round_column.vhd \
    $SRC/aes_round.vhd \
    $SRC/aes_enc_rolled.vhd \
    $SRC/aes_enc_pipelined.vhd \
    $SRC/AES_multicore_wrapper.vhd \
    $SRC/AES_pipelined_wrapper.vhd \
    $SRC/AES_algorithm.vhd \
]

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Pull one "| <row name> | <used> | ..." value out of a report_utilization dump.
# Returns 0 when the row is absent (e.g. no BRAM in a LUT-only build).
proc util_row {rpt name} {
    foreach line [split $rpt "\n"] {
        if {[regexp "^\\s*\\|\\s*[string map {( \\( ) \\)} $name]\\s*\\|\\s*(\[0-9\]+)" $line -> used]} {
            return $used
        }
    }
    return 0
}

# Worst setup slack of the routed design, in ns.
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

# Write the per-configuration wrapper: a fixed generic map, ports passed straight
# through. Keeping the port list identical to AES_algorithm means out-of-context
# synthesis preserves exactly the same boundary.
proc write_wrapper {path kind round flow cores bits} {
    set fh [open $path w]
    puts $fh "-- generated by synth_aes_core.tcl -- do not edit"
    puts $fh "library ieee;"
    puts $fh "use ieee.std_logic_1164.all;"
    puts $fh ""
    puts $fh "entity aes_cfg_top is"
    puts $fh "    port ("
    puts $fh "        i_clk         : in  std_logic;"
    puts $fh "        i_rstn        : in  std_logic;"
    puts $fh "        i_key         : in  std_logic_vector(255 downto 0);"
    puts $fh "        i_key_valid   : in  std_logic;"
    puts $fh "        i_nonce       : in  std_logic_vector(95 downto 0);"
    puts $fh "        i_nonce_valid : in  std_logic;"
    puts $fh "        s_axis_tdata  : in  std_logic_vector(127 downto 0);"
    puts $fh "        s_axis_tvalid : in  std_logic;"
    puts $fh "        s_axis_tready : out std_logic;"
    puts $fh "        s_axis_tlast  : in  std_logic;"
    puts $fh "        s_axis_tkeep  : in  std_logic_vector(15 downto 0);"
    puts $fh "        m_axis_tdata  : out std_logic_vector(127 downto 0);"
    puts $fh "        m_axis_tvalid : out std_logic;"
    puts $fh "        m_axis_tready : in  std_logic;"
    puts $fh "        m_axis_tlast  : out std_logic;"
    puts $fh "        m_axis_tkeep  : out std_logic_vector(15 downto 0);"
    puts $fh "        o_H           : out std_logic_vector(127 downto 0);"
    puts $fh "        o_H_valid     : out std_logic;"
    puts $fh "        o_E_k         : out std_logic_vector(127 downto 0);"
    puts $fh "        o_E_k_valid   : out std_logic;"
    puts $fh "        o_h_stale     : out std_logic;"
    puts $fh "        o_encryption_in_proc : out std_logic"
    puts $fh "    );"
    puts $fh "end entity;"
    puts $fh ""
    puts $fh "architecture rtl of aes_cfg_top is"
    puts $fh "begin"
    puts $fh "    u_dut : entity work.AES_algorithm"
    puts $fh "        generic map ("
    puts $fh "            AES_BITS     => $bits,"
    puts $fh "            ROUND_STYLE  => \"$round\","
    puts $fh "            FLOW_STYLE   => \"$flow\","
    puts $fh "            WRAPPER_KIND => \"$kind\","
    puts $fh "            NUM_CORES    => [expr {$cores > 0 ? $cores : 1}]"
    puts $fh "        )"
    puts $fh "        port map ("
    puts $fh "            i_clk => i_clk, i_rstn => i_rstn,"
    puts $fh "            i_key => i_key, i_key_valid => i_key_valid,"
    puts $fh "            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,"
    puts $fh "            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid,"
    puts $fh "            s_axis_tready => s_axis_tready, s_axis_tlast => s_axis_tlast,"
    puts $fh "            s_axis_tkeep => s_axis_tkeep,"
    puts $fh "            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,"
    puts $fh "            m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast,"
    puts $fh "            m_axis_tkeep => m_axis_tkeep,"
    puts $fh "            o_H => o_H, o_H_valid => o_H_valid,"
    puts $fh "            o_E_k => o_E_k, o_E_k_valid => o_E_k_valid,"
    puts $fh "            o_h_stale => o_h_stale,"
    puts $fh "            o_encryption_in_proc => o_encryption_in_proc"
    puts $fh "        );"
    puts $fh "end architecture;"
    close $fh
}

# One synthesis + implementation pass. Returns a dict of the collected metrics.
proc run_pass {cfg_dir period_ns vhdl_files part} {
    set xdc $cfg_dir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period_ns] \[get_ports i_clk\]"
    # No set_input_delay / set_output_delay on purpose: see the methodology note
    # in the header.  What is being characterised is the core, not its interface.
    #
    # SYNTH_IO_DELAY reinstates the interface budget for a side-by-side study of
    # how much it costs.  The two lines are verbatim what this script wrote before
    # the three sweeps were unified, so the comparison is against the real former
    # methodology and not against a reconstruction of it.  Unset, nothing changes.
    if {[info exists ::env(SYNTH_IO_DELAY)]} {
        set d [format %.3f [expr {double($::env(SYNTH_IO_DELAY))}]]
        puts $fh "set_input_delay  -clock clk $d \[filter \[all_inputs\]  {NAME !~ \"i_clk\"}\]"
        puts $fh "set_output_delay -clock clk $d \[all_outputs\]"
    }
    close $fh

    create_project -in_memory -part $part
    read_vhdl -library work $vhdl_files
    read_vhdl -library work $cfg_dir/aes_cfg_top.vhd
    read_xdc $xdc

    synth_design -top aes_cfg_top -part $part -mode out_of_context
    opt_design
    place_design
    phys_opt_design
    route_design

    set util [report_utilization -return_string]
    set pwr  [report_power -return_string]
    report_utilization    -file $cfg_dir/utilization.rpt
    report_timing_summary -file $cfg_dir/timing.rpt
    report_power          -file $cfg_dir/power.rpt

    # UltraScale+ row names first, 7-series names as a fallback so the script
    # survives a change of target device.
    set luts [util_row $util "CLB LUTs"]
    if {$luts == 0} { set luts [util_row $util "Slice LUTs"] }
    set ffs  [util_row $util "CLB Registers"]
    if {$ffs == 0}  { set ffs  [util_row $util "Slice Registers"] }
    set lutram [util_row $util "LUT as Memory"]
    set bram   [util_row $util "Block RAM Tile"]
    set dsp    [util_row $util "DSPs"]

    set wns  [worst_setup_slack]
    set fmax [expr {1000.0 / ($period_ns - $wns)}]

    set res [dict create luts $luts ffs $ffs lutram $lutram bram $bram dsp $dsp \
                         wns $wns fmax $fmax power [total_power $pwr] period $period_ns]
    close_project
    return $res
}

# ----------------------------------------------------------------------------
# Sweep
# ----------------------------------------------------------------------------
file mkdir $OUT
set csv_path $OUT/results.csv
set csv_hdr "config,wrapper_kind,round_style,flow_style,num_cores,aes_bits,start_MHz,period_ns,WNS_ns,Fmax_MHz,LUT,LUTRAM,FF,BRAM,DSP,power_W,blocks_per_clk,throughput_Gbps,passes"

# Optional single-configuration run: -tclargs <config name>
set only ""
if {[llength $argv] > 0} { set only [lindex $argv 0] }

# Rows already in the file.  A single-configuration run drops the one row it is
# about to replace and keeps the rest; a full sweep with RESUME keeps every row
# and skips the configurations that produced them.  A sweep this long gets
# interrupted often enough that starting over is not an acceptable answer.
#
# Rows are only reusable if they were written by this version of the script, so
# a header that does not match is treated as no file at all.
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

set t_start [clock seconds]
foreach cfg $CONFIGS {
    lassign $cfg name kind round flow cores
    if {$only ne "" && $name ne $only} { continue }
    if {$only eq "" && [lsearch -exact $have $name] >= 0} {
        puts "  -- $name is already in results.csv, skipping"
        continue
    }

    puts "\n==================================================================="
    puts "  $name   ($kind, $round, $flow, cores=$cores, AES-$AES_BITS)"
    puts "==================================================================="

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir
    write_wrapper $cfg_dir/aes_cfg_top.vhd $kind $round $flow $cores $AES_BITS

    # Tightening search.  Start at START_MHZ, then aim at the period the previous
    # pass implies.  The tightest pass that closed timing is kept and reported
    # as Fmax = 1000 / (period - WNS).
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
            # Missed: relax toward what this pass implies, or stop if some
            # earlier, looser period already closed.
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

    # Analytic ceiling of the core itself: the pipelined core retires one block
    # per clock; NUM_CORES rolled cores retire NUM_CORES / (NR+1), because a
    # block occupies a core for NR round clocks plus one clock in S_DONE while
    # the wrapper takes the result. The single output port caps that at one.
    # The value that goes into the thesis is the one measured in simulation;
    # this column is the sanity check, and it agrees with that measurement to
    # within 0.6 % for every core count from 1 to 15.
    set nr [expr {$AES_BITS / 32 + 6}]
    if {$kind eq "UNROLLED"} {
        set bpc 1.0
    } else {
        set bpc [expr {double($cores) / ($nr + 1)}]
        if {$bpc > 1.0} { set bpc 1.0 }
    }
    set gbps [expr {$bpc * 128.0 * [dict get $res fmax] / 1000.0}]

    puts $csv [format "%s,%s,%s,%s,%d,%d,%.1f,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%.3f,%.4f,%.2f,%d" \
        $name $kind $round $flow $cores $AES_BITS $START_MHZ \
        [dict get $res period] [dict get $res wns] [dict get $res fmax] \
        [dict get $res luts] [dict get $res lutram] [dict get $res ffs] \
        [dict get $res bram] [dict get $res dsp] [dict get $res power] \
        $bpc $gbps $passes]
    flush $csv

    puts [format "  -> LUT %d  FF %d  BRAM %d  DSP %d  |  WNS %.3f ns  Fmax %.1f MHz  |  %.2f Gb/s  (%d passes)" \
        [dict get $res luts] [dict get $res ffs] [dict get $res bram] [dict get $res dsp] \
        [dict get $res wns] [dict get $res fmax] $gbps $passes]
}

close $csv
puts "\n==================================================================="
puts "  done in [expr {[clock seconds] - $t_start}] s"
puts "  results: $csv_path"
puts "==================================================================="
