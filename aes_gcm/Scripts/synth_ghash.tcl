# ----------------------------------------------------------------------------
# synth_ghash.tcl - out-of-context synthesis + implementation sweep over the
# GHASH timing variants (generic MULT_CYCLES = 1 or 2).
#
# Purpose: produce the numbers behind the "GHASH determines the ceiling of the
# whole accelerator" discussion in the thesis.  The companion script
# synth_aes_core.tcl covers the AES cipher core on its own; the GHASH generic
# lives in the GCM glue, so it is NOT exercised there at all.
#
# Two levels are swept, because the generic changes more than the multiplier:
#   GHASH_wrapper  - the multiplier plus the upstream throttling it implies,
#                    isolated.  This is the number for the timing discussion.
#   gcm_enc_glue   - the same generic seen from the whole glue, so the cost is
#                    visible in context (skid buffers, muxes, tag finalizer).
#
# Usage (from the aes_gcm folder root):
#   vivado -mode batch -source Scripts/synth_ghash.tcl
#   vivado -mode batch -source Scripts/synth_ghash.tcl -tclargs ghash_c1
#       (optional: run a single configuration by name; existing rows in
#        results.csv are kept, only the re-run one is replaced)
#
# Output: Results/synth_ghash/
#   results.csv                      one row per configuration
#   <config>/utilization.rpt, timing.rpt, power.rpt
#
# Notes
#   * MULT_CYCLES is an INTEGER generic, so synth_design -generic is safe here.
#     (synth_aes_core.tcl generates a wrapper instead only because its generics
#     are strings, which are quoting-sensitive across Vivado versions.)
#   * Methodology is the one the other sweeps use: clock constraint ONLY, no
#     set_input_delay / set_output_delay, and Fmax found by tightening the period
#     rather than by meeting a fixed target -- a met constraint makes the tools
#     stop optimising, so a relaxed target measures the constraint, not the
#     design.  The reported Fmax is 1000 / (period - WNS) of the tightest pass
#     that closed timing.  Numbers are read after route_design, so they are
#     post-implementation.  Power is a vectorless estimate (no SAIF).
#   * bits_per_clk is the architectural ceiling of the authentication path:
#     128 bits per clock with a single-cycle multiply, 64 with a two-cycle one.
#     It is a property of the architecture, not a synthesis result.
# ----------------------------------------------------------------------------

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set SRC  $ROOT/Hardware/ip_cores/GCM_GLUE_ENC/src
set OUT  $ROOT/Results/synth_ghash

set PART       xck26-sfvc784-2LV-c   ;# Kria K26 SOM (KR260)
set START_MHZ  300.0                 ;# 128-bit Karatsuba tree lands well below the AES core
set MAX_PASSES 4                     ;# starting target, then up to three corrections
set SLACK_EPS  0.050                 ;# stop once within 50 ps of the target
set RESUME     1                     ;# 1 = keep rows already in results.csv, skip those configs

# START_MHZ is the seed of the search, not a target that gets reported: the loop
# tightens away from it until timing stops closing.  A configuration that spends
# every pass with slack still well above SLACK_EPS stopped on the pass count and
# not on convergence, and reseeding it near its own measured Fmax makes it
# converge in a pass or two.  SYNTH_START_MHZ in the environment does that for one
# rerun; unset, the sweep behaves exactly as it did before.
if {[info exists ::env(SYNTH_START_MHZ)]} {
    set START_MHZ [expr {double($::env(SYNTH_START_MHZ))}]
    puts "-- START_MHZ overridden via the environment: $START_MHZ MHz"
}

# ----------------------------------------------------------------------------
# Configuration list
#   name        top             MULT_CYCLES
# ----------------------------------------------------------------------------
set CONFIGS {
    {ghash_c1   GHASH_wrapper   1}
    {ghash_c2   GHASH_wrapper   2}
    {glue_c1    gcm_enc_glue    1}
    {glue_c2    gcm_enc_glue    2}
}

# ----------------------------------------------------------------------------
# Source files, leaves first so VHDL analysis order is never in question.
# The dependency tree is closed: GHASH_wrapper -> GHASH -> {GHASH_single,
# GHASH_pipelined} -> Karatsuba tree + reduction.  Both timing variants must be
# readable even though the generate block elaborates only one.
# ----------------------------------------------------------------------------
set GHASH_FILES [list \
    $SRC/GF2_karatsuba_16.vhd \
    $SRC/GF_karatsuba_32.vhd \
    $SRC/GF_Karatsuba_64.vhd \
    $SRC/GF2_Karatsuba_128.vhd \
    $SRC/GF2_Reduction_128.vhd \
    $SRC/GF_multiplier.vhd \
    $SRC/GHASH_single.vhd \
    $SRC/GHASH_pipelined.vhd \
    $SRC/GHASH.vhd \
    $SRC/GHASH_wrapper.vhd \
]

# The glue adds its own stream plumbing on top of the GHASH tree.
set GLUE_FILES [concat $GHASH_FILES [list \
    $SRC/AXIS_skid_buffer.vhd \
    $SRC/AXIS_MUX.vhd \
    $SRC/AXIS_DEMUX.vhd \
    $SRC/AXIS_GHASH_MUX.vhd \
    $SRC/axis_broadcaster.vhd \
    $SRC/Tag_Finalizer.vhd \
    $SRC/gcm_enc_glue.vhd \
]]

# ----------------------------------------------------------------------------
# Helpers (kept identical to synth_aes_core.tcl so both tables are produced the
# same way; duplicated rather than shared so neither script can break the other)
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

proc run_pass {cfg_dir period_ns vhdl_files part top cycles} {
    set xdc $cfg_dir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period_ns] \[get_ports i_clk\]"
    # No set_input_delay / set_output_delay on purpose: see the methodology note
    # in the header.  What is being characterised is the core, not its interface.
    close $fh

    create_project -in_memory -part $part
    read_vhdl -library work $vhdl_files
    read_xdc $xdc

    synth_design -top $top -part $part -mode out_of_context \
                 -generic MULT_CYCLES=$cycles
    opt_design
    place_design
    phys_opt_design
    route_design

    set util [report_utilization -return_string]
    set pwr  [report_power -return_string]
    report_utilization    -file $cfg_dir/utilization.rpt
    report_timing_summary -file $cfg_dir/timing.rpt
    report_power          -file $cfg_dir/power.rpt

    # UltraScale+ row names first, 7-series names as a fallback.
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
set csv_hdr "config,top,mult_cycles,start_MHz,period_ns,WNS_ns,Fmax_MHz,LUT,LUTRAM,FF,BRAM,DSP,power_W,bits_per_clk,ghash_ceiling_Gbps,passes"

# Optional single-configuration run: -tclargs <config name>
set only ""
if {[llength $argv] > 0} { set only [lindex $argv 0] }

# A single-configuration run keeps every existing row except the one being
# re-run; a full sweep with RESUME keeps every row and skips the configurations
# that produced them.  Rows are only reusable if this version of the script
# wrote them, so a header that does not match is treated as no file at all.
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
    lassign $cfg name top cycles
    if {$only ne "" && $name ne $only} { continue }
    if {$only eq "" && [lsearch -exact $have $name] >= 0} {
        puts "  -- $name is already in results.csv, skipping"
        continue
    }

    puts "\n==================================================================="
    puts "  $name   (top=$top, MULT_CYCLES=$cycles)"
    puts "==================================================================="

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir

    # if/else rather than expr ?: because these are lists, not scalars.
    if {$top eq "gcm_enc_glue"} {
        set files $GLUE_FILES
    } else {
        set files $GHASH_FILES
    }

    # Tightening search, identical to the AES and SHA-3 sweeps: start at
    # START_MHZ, then aim at the period the previous pass implies, and keep the
    # tightest pass that closed timing (Fmax = 1000 / (period - WNS)).
    set period [expr {1000.0 / $START_MHZ}]
    set best   ""
    set passes 0
    for {set p 0} {$p < $MAX_PASSES} {incr p} {
        puts "  -- pass [expr {$p + 1}] at period [format %.3f $period] ns"
        set res [run_pass $cfg_dir $period $files $PART $top $cycles]
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

    # Architectural ceiling of the authentication path: one 128-bit block per
    # MULT_CYCLES clocks.  This is a property of the architecture; the value is
    # multiplied by the fmax this script reports, the same methodology used for
    # the AES core and the SHA-3 accelerator.
    set bpc  [expr {128.0 / $cycles}]
    set gbps [expr {$bpc * [dict get $res fmax] / 1000.0}]

    puts $csv [format "%s,%s,%d,%.1f,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%.3f,%.1f,%.2f,%d" \
        $name $top $cycles $START_MHZ \
        [dict get $res period] [dict get $res wns] [dict get $res fmax] \
        [dict get $res luts] [dict get $res lutram] [dict get $res ffs] \
        [dict get $res bram] [dict get $res dsp] [dict get $res power] \
        $bpc $gbps $passes]
    flush $csv

    puts [format "  -> LUT %d  FF %d  |  WNS %.3f ns  Fmax %.1f MHz  |  ceiling %.2f Gb/s" \
        [dict get $res luts] [dict get $res ffs] \
        [dict get $res wns] [dict get $res fmax] $gbps]
}

close $csv
puts "\n==================================================================="
puts "  done in [expr {[clock seconds] - $t_start}] s"
puts "  results: $csv_path"
puts "==================================================================="
