#-----------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Script Name   : synth_ecdh_core.tcl
# Tool Version  : Vivado 2025.1
#
# Description   : Out-of-context implementation sweep for the unified ECDH IP,
#                 the counterpart of sha3/Scripts/synth_sha3_core.tcl and
#                 aes_gcm/Scripts/synth_aes_core.tcl.  One top (ecdh_axis_ip)
#                 covers both cores through the boolean G_LOW_LATENCY generic
#                 (if-generate, only the chosen branch is synthesised):
#                   faza1 = G_LOW_LATENCY false -> ecdh_core_basic
#                           (sequential baseline, one gf_alu)
#                   faza2 = G_LOW_LATENCY true  -> ecdh_core_low_latency
#                           (parallel step, 3 multipliers)
#                 The grid is G_LOW_LATENCY x G_D, the two parameters the
#                 architecture exposes:
#                 D in {1, 2, 4, 8, 16, 32, 64, 128} for each core -- 16 runs.
#
#                 The tops are the full AXIS IPs, the same level the rest of
#                 the family measures (sha3_axis_ip, AES_algorithm,
#                 gcm_enc_glue).  DATA_WIDTH is fixed at 64 -- the AXIS shell
#                 does not depend on G_D, so sweeping it would multiply runs
#                 without saying anything new about the core.  G_B carries the
#                 REAL B-571 coefficient b from SP 800-186: the deployed IP is
#                 fixed to this curve, so letting synthesis fold the real
#                 constant is what the deployed netlist actually looks like
#                 (b = 1 from the fixedb simulation vectors would trivialise
#                 the b*Z^4 path).
#
# Methodology   : identical to the SHA-3 and AES sweeps, so the three series
#                 are directly comparable.  Clock constraint ONLY, no
#                 set_input_delay / set_output_delay: what is being measured is
#                 the core's internal critical path, not the interface budget
#                 (SYNTH_IO_DELAY reinstates it for a sensitivity study only).
#                 Numbers are read AFTER route_design, so they are
#                 post-implementation, never post-synthesis.  Power is a
#                 vectorless estimate (report_power without a SAIF).
#
#                 Fmax is not "the target was met": the period is tightened by
#                 the slack found, up to MAX_PASSES times, and the reported row
#                 is the tightest pass that closed timing, with
#                 Fmax = 1000 / (period - WNS).
#
# Usage         : vivado -mode batch -source Scripts/synth_ecdh_core.tcl
#                 vivado -mode batch -source Scripts/synth_ecdh_core.tcl -tclargs ecdh_f1_d8
# Output        : Results/synth_ecdh_core/results.csv  (+ per-config reports)
#-----------------------------------------------------------------------------

set HERE [file dirname [file normalize [info script]]]
set ROOT [file dirname $HERE]
set SRC  $ROOT/Hardware/ip_cores_ECDH/ECDH/src
set OUT  $ROOT/Results/synth_ecdh_core

set PART        xck26-sfvc784-2LV-c   ;# Kria K26 SOM (KR260), same part as SHA-3/AES
set DATA_WIDTH  64                    ;# fixed: the AXIS shell does not depend on G_D
set MAX_PASSES  3                     ;# starting target, then up to two corrections
set SLACK_EPS   0.050                 ;# stop once within 50 ps of the target
set RESUME      1                     ;# 1 = keep rows already in results.csv, skip those configs

# Per-digit starting frequency.  The multiplier's combinational path grows with
# the digit width, so one seed cannot fit all sixteen runs.  The table is scaled
# off a measured post-implementation point, not off post-synthesis estimates:
# this core is route-bound (the worst path of ecdh_f1_d1 is ~72 % routing), so
# pre-placement estimates overshoot by roughly a third.  Seeds are biased LOW on
# purpose -- a pass that closes corrects the period by the exact slack found,
# while a seed above the truth burns one of only MAX_PASSES passes on a miss.
# See results/ecdh_kriticna_putanja.md.  Reseed any configuration that
# stops on the pass count instead of on convergence (SYNTH_START_MHZ below).
set SEED_MHZ [dict create \
    1 300.0   2 300.0   4 260.0   8 260.0 \
    16 230.0  32 200.0  64 170.0  128 140.0]

# The starting frequency is the seed of the search, not a target that gets
# reported: the loop tightens away from it until timing stops closing.
# SYNTH_START_MHZ in the environment overrides the whole seed table for one
# rerun.  Unset, the sweep behaves exactly as before.
set SEED_OVERRIDE ""
if {[info exists ::env(SYNTH_START_MHZ)]} {
    set SEED_OVERRIDE [expr {double($::env(SYNTH_START_MHZ))}]
    puts "-- start frequency overridden via the environment: $SEED_OVERRIDE MHz"
}

# ----------------------------------------------------------------------------
# Configuration list: phase x digit width.
# ----------------------------------------------------------------------------
set D_SET {1 2 4 8 16 32 64 128}
set CONFIGS {}
foreach faza {1 2} {
    foreach d $D_SET {
        lappend CONFIGS [list ecdh_f${faza}_d${d} $faza $d]
    }
}

# Package first so VHDL analysis order is never in question.  The unified IP
# keeps a single copy of every module in one src/ tree; both cores and their
# shared GF/EC primitives are analysed together and the if-generate in
# ecdh_axis_ip elaborates only the branch G_LOW_LATENCY selects.
set VHDL_FILES [list \
    $SRC/gf_alu_pkg.vhd \
    $SRC/gf_add.vhd \
    $SRC/gf_sqr.vhd \
    $SRC/gf_mul.vhd \
    $SRC/gf_inv.vhd \
    $SRC/gf_alu.vhd \
    $SRC/ec_cswap.vhd \
    $SRC/ec_step_mxy.vhd \
    $SRC/ecdh_core_basic.vhd \
    $SRC/ec_point_step_par.vhd \
    $SRC/ec_scalar_mult_par.vhd \
    $SRC/ec_mxy_batch.vhd \
    $SRC/ecdh_core_low_latency.vhd \
    $SRC/ecdh_deserializer.vhd \
    $SRC/ecdh_serializer.vhd \
    $SRC/ecdh_axis_ip.vhd \
]

# ----------------------------------------------------------------------------
# Helpers (same as the SHA-3/AES sweeps, so all series are read the same way)
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

# Per-configuration wrapper.  G_F and G_B are 572/571-bit std_logic_vector
# generics; long vector generics do not survive synth_design -generic reliably,
# so the configuration is frozen in VHDL instead, the same way the SHA-3 sweep
# does it.  The DUT is always the unified ecdh_axis_ip; faza only decides the
# G_LOW_LATENCY value.  C_B is the REAL B-571 coefficient b (SP 800-186,
# appendix C of the thesis), written as a VHDL-2008 sized hex literal.
proc write_wrapper {path faza d dw} {
    set dut "ecdh_axis_ip"
    set ll  [expr {$faza == 1 ? "false" : "true"}]
    set kw  [expr {$dw / 8}]
    set fh [open $path w]
    puts $fh "library ieee;"
    puts $fh "use ieee.std_logic_1164.all;"
    puts $fh ""
    puts $fh "entity ecdh_cfg_top is"
    puts $fh "    port ("
    puts $fh "        i_clk           : in  std_logic;"
    puts $fh "        i_resetn        : in  std_logic;"
    puts $fh "        i_k             : in  std_logic_vector(570 downto 0);"
    puts $fh "        i_k_valid       : in  std_logic;"
    puts $fh "        s_axis_tvalid   : in  std_logic;"
    puts $fh "        s_axis_tready   : out std_logic;"
    puts $fh "        s_axis_tdata    : in  std_logic_vector([expr {$dw - 1}] downto 0);"
    puts $fh "        s_axis_tkeep    : in  std_logic_vector([expr {$kw - 1}] downto 0);"
    puts $fh "        s_axis_tlast    : in  std_logic;"
    puts $fh "        m_axis_tvalid   : out std_logic;"
    puts $fh "        m_axis_tready   : in  std_logic;"
    puts $fh "        m_axis_tdata    : out std_logic_vector([expr {$dw - 1}] downto 0);"
    puts $fh "        m_axis_tkeep    : out std_logic_vector([expr {$kw - 1}] downto 0);"
    puts $fh "        m_axis_tlast    : out std_logic;"
    puts $fh "        m_axis_z_tvalid : out std_logic;"
    puts $fh "        m_axis_z_tready : in  std_logic;"
    puts $fh "        m_axis_z_tdata  : out std_logic_vector([expr {$dw - 1}] downto 0);"
    puts $fh "        m_axis_z_tkeep  : out std_logic_vector([expr {$kw - 1}] downto 0);"
    puts $fh "        m_axis_z_tlast  : out std_logic"
    puts $fh "    );"
    puts $fh "end entity;"
    puts $fh ""
    puts $fh "architecture rtl of ecdh_cfg_top is"
    puts $fh "    -- B-571 pentanomial f = x^571 + x^10 + x^5 + x^2 + 1 (572 bits)"
    puts $fh "    constant C_F : std_logic_vector(571 downto 0) :="
    puts $fh "        (571 => '1', 10 => '1', 5 => '1', 2 => '1', 0 => '1', others => '0');"
    puts $fh "    -- Real B-571 coefficient b (SP 800-186); VHDL-2008 sized hex literal"
    puts $fh "    constant C_B : std_logic_vector(570 downto 0) :="
    puts $fh "        571x\"02F40E7E2221F295DE297117B7F3D62F5C6A97FFCB8CEFF1CD6BA8CE4A9A18AD84FFABBD8EFA59332BE7AD6756A66E294AFD185A78FF12AA520E4DE739BACA0C7FFEFF7F2955727A\";"
    puts $fh "begin"
    puts $fh "    u_dut : entity work.$dut"
    puts $fh "        generic map ("
    puts $fh "            G_M           => 571,"
    puts $fh "            G_D           => $d,"
    puts $fh "            G_F           => C_F,"
    puts $fh "            G_B           => C_B,"
    puts $fh "            DATA_WIDTH    => $dw,"
    puts $fh "            G_LOW_LATENCY => $ll"
    puts $fh "        )"
    puts $fh "        port map ("
    puts $fh "            i_clk           => i_clk,"
    puts $fh "            i_resetn        => i_resetn,"
    puts $fh "            i_k             => i_k,"
    puts $fh "            i_k_valid       => i_k_valid,"
    puts $fh "            s_axis_tvalid   => s_axis_tvalid,"
    puts $fh "            s_axis_tready   => s_axis_tready,"
    puts $fh "            s_axis_tdata    => s_axis_tdata,"
    puts $fh "            s_axis_tkeep    => s_axis_tkeep,"
    puts $fh "            s_axis_tlast    => s_axis_tlast,"
    puts $fh "            m_axis_tvalid   => m_axis_tvalid,"
    puts $fh "            m_axis_tready   => m_axis_tready,"
    puts $fh "            m_axis_tdata    => m_axis_tdata,"
    puts $fh "            m_axis_tkeep    => m_axis_tkeep,"
    puts $fh "            m_axis_tlast    => m_axis_tlast,"
    puts $fh "            m_axis_z_tvalid => m_axis_z_tvalid,"
    puts $fh "            m_axis_z_tready => m_axis_z_tready,"
    puts $fh "            m_axis_z_tdata  => m_axis_z_tdata,"
    puts $fh "            m_axis_z_tkeep  => m_axis_z_tkeep,"
    puts $fh "            m_axis_z_tlast  => m_axis_z_tlast"
    puts $fh "        );"
    puts $fh "end architecture;"
    close $fh
}

# One synthesis + implementation pass.  Returns a dict of collected metrics.
proc run_pass {cfg_dir period_ns vhdl_files part} {
    set xdc $cfg_dir/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period [format %.3f $period_ns] \[get_ports i_clk\]"
    # No set_input_delay / set_output_delay on purpose: see the methodology note
    # in the header.  What is being characterised is the core, not its interface.
    #
    # SYNTH_IO_DELAY reinstates the interface budget for a side-by-side study of
    # how much it costs, the same switch the SHA-3 and AES sweeps carry.  Unset,
    # nothing changes.
    if {[info exists ::env(SYNTH_IO_DELAY)]} {
        set d [format %.3f [expr {double($::env(SYNTH_IO_DELAY))}]]
        puts $fh "set_input_delay  -clock clk $d \[filter \[all_inputs\]  {NAME !~ \"i_clk\"}\]"
        puts $fh "set_output_delay -clock clk $d \[all_outputs\]"
    }
    close $fh

    create_project -in_memory -part $part
    foreach f $vhdl_files { read_vhdl -vhdl2008 -library work $f }
    read_vhdl -vhdl2008 -library work $cfg_dir/ecdh_cfg_top.vhd
    read_xdc $xdc

    synth_design -top ecdh_cfg_top -part $part -mode out_of_context
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
set csv_hdr "config,faza,G_D,period_ns,WNS_ns,Fmax_MHz,LUT,LUTRAM,FF,BRAM,DSP,power_W,passes"

set only ""
if {[llength $argv] > 0} { set only [lindex $argv 0] }

# A single-configuration run keeps every other row already in the file; a full
# sweep with RESUME keeps every row and skips the configurations that produced
# them.  Sixteen configurations at up to three implementation passes each run
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
    lassign $cfg name faza d
    if {$only ne "" && $name ne $only} { continue }
    if {$only eq "" && [lsearch -exact $have $name] >= 0} {
        puts "  -- $name is already in results.csv, skipping"
        continue
    }

    set core [expr {$faza == 1 ? "ecdh_core_basic" : "ecdh_core_low_latency"}]
    puts "\n==================================================================="
    puts "  $name   (faza $faza, $core, G_D=$d, DATA_WIDTH=$DATA_WIDTH)"
    puts "==================================================================="

    set cfg_dir $OUT/$name
    file mkdir $cfg_dir
    write_wrapper $cfg_dir/ecdh_cfg_top.vhd $faza $d $DATA_WIDTH

    set vhdl_files $VHDL_FILES

    # Tightening search.  Start from the per-digit seed, then aim at the period
    # the previous pass implies.  The tightest pass that closed timing is kept
    # and reported as Fmax = 1000 / (period - WNS).
    set seed [expr {$SEED_OVERRIDE ne "" ? $SEED_OVERRIDE : [dict get $SEED_MHZ $d]}]
    set period [expr {1000.0 / $seed}]
    set best   ""
    set passes 0
    for {set p 0} {$p < $MAX_PASSES} {incr p} {
        puts "  -- pass [expr {$p + 1}] at period [format %.3f $period] ns"
        set res [run_pass $cfg_dir $period $vhdl_files $PART]
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

    puts $csv [format "%s,%d,%d,%.3f,%.3f,%.2f,%d,%d,%d,%d,%d,%.3f,%d" \
        $name $faza $d \
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
puts "rezultati: $csv_path"
