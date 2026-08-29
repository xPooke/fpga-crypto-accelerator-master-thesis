#-----------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Script Name   : synth_sha3_core.tcl
# Tool Version  : Vivado 2025.1
#
# Description   : Out-of-context implementation sweep for the SHA-3 core, the
#                 counterpart of aes_gcm/Scripts/synth_aes_core.tcl.  Covers all
#                 configurations chapter 5 reports: four variants of the
#                 standard, the two AXIS data widths the throughput series also
#                 uses (32 and 64) and both architectures (ROUNDS_PER_CYCLE 1
#                 and 2), less the one that elaboration rejects -- 14 runs.
#
# Methodology   : clock constraint ONLY, no set_input_delay / set_output_delay.
#                 The measured quantity is the core's internal critical path, so
#                 the interface budget is deliberately left out (SYNTH_IO_DELAY
#                 below reinstates it for a sensitivity study only).  Numbers
#                 are read AFTER route_design, so they are post-implementation,
#                 never post-synthesis.  Power is a vectorless estimate:
#                 report_power runs without a SAIF, i.e. with default switching
#                 activity.
#
#                 Fmax is not "the target was met": the period is tightened by
#                 the slack found, up to MAX_PASSES times, and the reported row
#                 is the tightest pass that closed timing, with
#                 Fmax = 1000 / (period - WNS).
#
# Usage         : vivado -mode batch -source Scripts/synth_sha3_core.tcl
#                 vivado -mode batch -source Scripts/synth_sha3_core.tcl -tclargs sha3_256_dw64_a1
# Output        : Results/synth_sha3_core/results.csv  (+ per-config reports)
#-----------------------------------------------------------------------------

set HERE [file dirname [file normalize [info script]]]
set ROOT [file dirname $HERE]
set SRC  $ROOT/Hardware/src
set OUT  $ROOT/Results/synth_sha3_core

set PART        xck26-sfvc784-2LV-c   ;# Kria K26 SOM (KR260), same part as AES
# Starting frequency per architecture: a seed for the search, not a target.
# Vivado optimises to the constraint and no further, so a relaxed first pass
# measures the constraint, not the design -- the seed must be aggressive.  An
# unreachable one is also wasteful: it burns a full routing pass on a miss.
# Architecture II chains two Keccak rounds per clock and lands far below
# architecture I, so each gets its own seed and the search tightens from there.
set START_MHZ_A1 400.0
set START_MHZ_A2 250.0
set MAX_PASSES  3                     ;# starting target, then up to two corrections
set SLACK_EPS   0.050                 ;# stop once within 50 ps of the target
set RESUME      1                     ;# 1 = keep rows already in results.csv, skip those configs

# The starting frequency is the seed of the search, not a target that gets
# reported: the loop tightens away from it until timing stops closing.  A
# configuration that spends every pass with slack still well above SLACK_EPS
# stopped on the pass count and not on convergence, and reseeding it near its own
# measured Fmax makes it converge in a pass or two.  SYNTH_START_MHZ in the
# environment does that for one rerun -- it seeds both architectures, and only
# the one belonging to the config being rerun is used.  Unset, the sweep behaves
# exactly as it did before.
if {[info exists ::env(SYNTH_START_MHZ)]} {
    set START_MHZ_A1 [expr {double($::env(SYNTH_START_MHZ))}]
    set START_MHZ_A2 $START_MHZ_A1
    puts "-- start frequency overridden via the environment: $START_MHZ_A1 MHz"
}

# ----------------------------------------------------------------------------
# Configuration list: variant x data width x architecture.
#   a1 = ROUNDS_PER_CYCLE 1 (architecture I), a2 = 2 (architecture II)
# ----------------------------------------------------------------------------
# Widths 8 and 16 are out of scope: the throughput series characterises 32 and
# 64, so keeping both tables on the same set is what makes them comparable.
# SHA3-224 with DATA_WIDTH 64 is rejected at elaboration anyway -- the digest is
# 224 bits, which DATA_WIDTH must divide -- leaving 14 configurations.
set CONFIGS {}
foreach ver {224 256 384 512} {
    foreach dw {32 64} {
        if {$ver == 224 && $dw == 64} { continue }
        foreach rpc {1 2} {
            lappend CONFIGS [list sha3_${ver}_dw${dw}_a${rpc} $ver $dw $rpc]
        }
    }
}

# Package first so VHDL analysis order is never in question.
set VHDL_FILES [list \
    $SRC/keccak_pkg.vhd \
    $SRC/keccak_sponge.vhd \
    $SRC/sha3_input_buffer.vhd \
    $SRC/sha3_output_buffer.vhd \
    $SRC/sha3_top.vhd \
    $SRC/sha3_axis_ip.vhd \
]

# ----------------------------------------------------------------------------
# Helpers (same as the AES sweep, so both series are read the same way)
# ----------------------------------------------------------------------------
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

# Per-configuration wrapper.  SHA3_VERSION is a string generic, and string
# generics do not survive synth_design -generic reliably, so the configuration
# is frozen in VHDL instead.  Port widths depend on DATA_WIDTH, so they are
# written out concretely for each run.
proc write_wrapper {path ver dw rpc} {
    set kw [expr {$dw / 8}]
    set fh [open $path w]
    puts $fh "library ieee;"
    puts $fh "use ieee.std_logic_1164.all;"
    puts $fh ""
    puts $fh "entity sha3_cfg_top is"
    puts $fh "    port ("
    puts $fh "        axis_aclk     : in  std_logic;"
    puts $fh "        axis_aresetn  : in  std_logic;"
    puts $fh "        s_axis_tvalid : in  std_logic;"
    puts $fh "        s_axis_tready : out std_logic;"
    puts $fh "        s_axis_tdata  : in  std_logic_vector([expr {$dw - 1}] downto 0);"
    puts $fh "        s_axis_tkeep  : in  std_logic_vector([expr {$kw - 1}] downto 0);"
    puts $fh "        s_axis_tlast  : in  std_logic;"
    puts $fh "        m_axis_tvalid : out std_logic;"
    puts $fh "        m_axis_tready : in  std_logic;"
    puts $fh "        m_axis_tdata  : out std_logic_vector([expr {$dw - 1}] downto 0);"
    puts $fh "        m_axis_tkeep  : out std_logic_vector([expr {$kw - 1}] downto 0);"
    puts $fh "        m_axis_tlast  : out std_logic"
    puts $fh "    );"
    puts $fh "end entity;"
    puts $fh ""
    puts $fh "architecture rtl of sha3_cfg_top is"
    puts $fh "begin"
    puts $fh "    u_dut : entity work.sha3_axis_ip"
    puts $fh "        generic map ("
    puts $fh "            ALGORITHM        => \"SHA3\","
    puts $fh "            SHA3_VERSION     => \"$ver\","
    puts $fh "            SHAKE_VERSION    => \"256\","
    puts $fh "            SHAKE_BITS       => 1024,"
    puts $fh "            DATA_WIDTH       => $dw,"
    puts $fh "            ROUNDS_PER_CYCLE => $rpc"
    puts $fh "        )"
    puts $fh "        port map ("
    puts $fh "            axis_aclk     => axis_aclk,"
    puts $fh "            axis_aresetn  => axis_aresetn,"
    puts $fh "            s_axis_tvalid => s_axis_tvalid,"
    puts $fh "            s_axis_tready => s_axis_tready,"
    puts $fh "            s_axis_tdata  => s_axis_tdata,"
    puts $fh "            s_axis_tkeep  => s_axis_tkeep,"
    puts $fh "            s_axis_tlast  => s_axis_tlast,"
    puts $fh "            m_axis_tvalid => m_axis_tvalid,"
    puts $fh "            m_axis_tready => m_axis_tready,"
    puts $fh "            m_axis_tdata  => m_axis_tdata,"
    puts $fh "            m_axis_tkeep  => m_axis_tkeep,"
    puts $fh "            m_axis_tlast  => m_axis_tlast"
    puts $fh "        );"
    puts $fh "end architecture;"
    close $fh
}

# One synthesis + implementation pass.  Returns a dict of collected metrics.
proc run_pass {cfg_dir period_ns vhdl_files part} {
    set xdc $cfg_dir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period_ns] \[get_ports axis_aclk\]"
    # No set_input_delay / set_output_delay on purpose: see the methodology note
    # in the header.  What is being characterised is the core, not its interface.
    #
    # SYNTH_IO_DELAY reinstates the interface budget for a side-by-side study of
    # how much it costs.  The form is the one AES and GHASH used before the three
    # sweeps were unified, so both cores are studied the same way.  Unset, nothing
    # changes.
    if {[info exists ::env(SYNTH_IO_DELAY)]} {
        set d [format %.3f [expr {double($::env(SYNTH_IO_DELAY))}]]
        puts $fh "set_input_delay  -clock clk $d \[filter \[all_inputs\]  {NAME !~ \"axis_aclk\"}\]"
        puts $fh "set_output_delay -clock clk $d \[all_outputs\]"
    }
    close $fh

    create_project -in_memory -part $part
    read_vhdl -library work $vhdl_files
    read_vhdl -library work $cfg_dir/sha3_cfg_top.vhd
    read_xdc $xdc

    synth_design -top sha3_cfg_top -part $part -mode out_of_context
    opt_design
    place_design
    phys_opt_design
    route_design

    set util [report_utilization -return_string]
    set pwr  [report_power -return_string]
    report_utilization    -file $cfg_dir/utilization.rpt
    report_timing_summary -file $cfg_dir/timing.rpt
    report_power          -file $cfg_dir/power.rpt

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
set csv_hdr "config,variant,data_width,rounds_per_cycle,arhitektura,period_ns,WNS_ns,Fmax_MHz,LUT,LUTRAM,FF,BRAM,DSP,power_W,passes"

set only ""
if {[llength $argv] > 0} { set only [lindex $argv 0] }

# A single-configuration run keeps every other row already in the file; a full
# sweep with RESUME keeps every row and skips the configurations that produced
# them.  Fourteen configurations at up to three implementation passes each run
# for hours, and an interrupted sweep that started over would never finish.
# Rows are only reusable if this version of the script wrote them, so a header
# that does not match is treated as no file at all.
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
    lassign $cfg name ver dw rpc
    if {$only ne "" && $name ne $only} { continue }
    if {$only eq "" && [lsearch -exact $have $name] >= 0} {
        puts "  -- $name is already in results.csv, skipping"
        continue
    }

    set arch [expr {$rpc == 1 ? "I" : "II"}]
    puts "\n==================================================================="
    puts "  $name   (SHA3-$ver, DATA_WIDTH=$dw, architecture $arch)"
    puts "==================================================================="

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir
    write_wrapper $cfg_dir/sha3_cfg_top.vhd $ver $dw $rpc

    # Tightening search.  Start from the seed, then aim at the period the
    # previous pass implies.  The tightest pass that closed timing is kept and
    # reported as Fmax = 1000 / (period - WNS).
    set period [expr {1000.0 / ($rpc == 1 ? $START_MHZ_A1 : $START_MHZ_A2)}]
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
            # Missed: back off toward the last period that closed.
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

    puts $csv [format "%s,%s,%d,%d,%s,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%.3f,%d" \
        $name $ver $dw $rpc $arch \
        [dict get $best_res period] [dict get $best_res wns] [dict get $best_res fmax] \
        [dict get $best_res luts] [dict get $best_res lutram] [dict get $best_res ffs] \
        [dict get $best_res bram] [dict get $best_res dsp] [dict get $best_res power] \
        $passes]
    flush $csv

    puts [format "  -> Fmax %.2f MHz, LUT %d, FF %d, WNS %.3f ns (%d passes)" \
        [dict get $best_res fmax] [dict get $best_res luts] [dict get $best_res ffs] \
        [dict get $best_res wns] $passes]
}

close $csv
puts "\nfinished in [expr {[clock seconds] - $t_start}] s"
puts "results: $csv_path"
