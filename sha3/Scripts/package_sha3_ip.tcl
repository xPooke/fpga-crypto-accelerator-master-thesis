# ----------------------------------------------------------------------------
# package_sha3_ip.tcl - one-shot, fully scripted packaging of the SHA-3/SHAKE
# accelerator IP. No manual IP Packager work; GUI polish included: drop-downs,
# tooltips, English display names, defaults, dynamic gray-out (SHA3_VERSION
# only for ALGORITHM=SHA3; SHAKE_VERSION/SHAKE_BITS only for ALGORITHM=SHAKE).
#
# Usage (from the sha3 folder root):
#   vivado -mode batch -source Scripts/package_sha3_ip.tcl
#
# The IP is packaged IN PLACE into Hardware/ (component.xml + xgui/ + gui/
# written next to the live src/), the same scheme the ECDH and AES cores
# use, so there is no second copy of the sources to drift out of date.
# Afterwards add Hardware/ as an IP repository path (Settings -> IP ->
# Repository). Re-running is safe (-force; revision bumps on each run).
#
# Packaging pitfalls this script guards against:
#   * enablement via [string equal ...], NEVER bare $X == "Y"  (bareword error)
#   * enablement_value snapshot so the FIRST GUI open matches the defaults
#     (update procs only fire on changes)
#   * xgui/gtcl written AFTER ipx::save_core so nothing clobbers them
#   * stale xgui leftovers deleted (only <name>_v1_0.tcl is referenced)
#   * explicit clock<->AXIS association (ipx::associate_bus_interfaces)
#     -- without ASSOCIATED_BUSIF on the clock, BD connection automation
#     skips the streams and they must be wired by hand.
# ----------------------------------------------------------------------------

set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set IPDIR  $ROOT/Hardware
set PART   xck26-sfvc784-2LV-c
set VENDOR etf.bg.ac.rs

set TOP    sha3_axis_ip
set IPNAME sha3_axis_ip
set DISP   "SHA-3 / SHAKE Hash Accelerator (FIPS 202)"
set DESC   "SHA-3 family hash engine: SHA3-224/256/384/512 fixed-length digests, SHAKE128/256 extendable-output (XOF) with a generic-selected output length, or cSHAKE (SP 800-185, KMAC-capable with software-side formatting). AXI-Stream in/out, one TLAST-delimited packet per message."

# ============================================================================
# xgui text builders (same templates as the AES/DFX round)
# ============================================================================
proc xgui_param_line {name widget tooltip} {
    set w ""
    if {$widget ne ""} { set w " -widget $widget" }
    set t {
  set p [ipgui::add_param $IPINST -name "__NAME__" -parent ${Page_0}__W__]
  set_property tooltip {__TIP__} $p
}
    return [string map [list __NAME__ $name __W__ $w __TIP__ $tooltip] $t]
}

proc xgui_plain_procs {name} {
    set t {
proc update_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ } {
}

proc validate_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ } {
	return true
}
}
    return [string map [list __NAME__ $name] $t]
}

# update proc fires on every MASTER change; quote-trim hardening because the
# packager hands string generics over with embedded quotes
proc xgui_dynamic_procs {name master value} {
    set t {
proc update_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ PARAM_VALUE.__MASTER__ } {
	set wk [string trim [get_property value ${PARAM_VALUE.__MASTER__}] "\""]
	set v [expr {$wk eq "__VALUE__"}]
	set_property enabled $v ${PARAM_VALUE.__NAME__}
	if {[catch {set_property visible $v ${PARAM_VALUE.__NAME__}}]} {}
}

proc validate_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ } {
	return true
}
}
    return [string map [list __NAME__ $name __MASTER__ $master __VALUE__ $value] $t]
}

# same, but enabled when the master equals EITHER of two values
proc xgui_dynamic_procs_or {name master v1 v2} {
    set t {
proc update_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ PARAM_VALUE.__MASTER__ } {
	set wk [string trim [get_property value ${PARAM_VALUE.__MASTER__}] "\""]
	set v [expr {$wk eq "__V1__" || $wk eq "__V2__"}]
	set_property enabled $v ${PARAM_VALUE.__NAME__}
	if {[catch {set_property visible $v ${PARAM_VALUE.__NAME__}}]} {}
}

proc validate_PARAM_VALUE.__NAME__ { PARAM_VALUE.__NAME__ } {
	return true
}
}
    return [string map [list __NAME__ $name __MASTER__ $master __V1__ $v1 __V2__ $v2] $t]
}

proc xgui_modelparam_procs {name} {
    set t {
proc update_MODELPARAM_VALUE.__NAME__ { MODELPARAM_VALUE.__NAME__ PARAM_VALUE.__NAME__ } {
	set_property value [get_property value ${PARAM_VALUE.__NAME__}] ${MODELPARAM_VALUE.__NAME__}
}
}
    return [string map [list __NAME__ $name] $t]
}

proc set_choice_list {core pname values} {
    set p [ipx::get_user_parameters $pname -of_objects $core]
    set_property value_validation_type list   $p
    set_property value_validation_list $values $p
}

proc set_range {core pname lo hi} {
    set p [ipx::get_user_parameters $pname -of_objects $core]
    set_property value_validation_type          range_long $p
    set_property value_validation_range_minimum $lo        $p
    set_property value_validation_range_maximum $hi        $p
}

# ============================================================================
# in-memory project + sources
# ============================================================================
create_project -in_memory -part $PART
foreach f [lsort [glob $IPDIR/src/*.vhd]] {
    read_vhdl -vhdl2008 $f
}
set_property top $TOP [current_fileset]
update_compile_order -fileset sources_1

# ============================================================================
# package in place
# ============================================================================
ipx::package_project -root_dir $IPDIR -vendor $VENDOR -library user \
    -taxonomy /UserIP -import_files false -set_current true -force
set core [ipx::current_core]
set_property name          $IPNAME $core
set_property display_name  $DISP   $core
set_property description   $DESC   $core
set_property version       1.0     $core

# ============================================================================
# clock <-> AXIS association (without it, BD automation skips the streams):
# put ASSOCIATED_BUSIF on axis_aclk so BD connection automation drags the
# streams (and the reset) along with the clock.
# ============================================================================
if {[catch {
    ipx::associate_bus_interfaces -busif s_axis -clock axis_aclk $core
    ipx::associate_bus_interfaces -busif m_axis -clock axis_aclk $core
} err]} { puts "WARN: clock/busif association: $err" }
if {[catch {
    ipx::associate_bus_interfaces -clock axis_aclk -reset axis_aresetn $core
} err]} { puts "WARN: clock/reset association: $err" }

# ============================================================================
# parameter polish: drop-downs, defaults, display names, enablement
# ============================================================================
set_choice_list $core ALGORITHM        {SHA3 SHAKE CSHAKE}
set_choice_list $core SHA3_VERSION     {224 256 384 512}
set_choice_list $core SHAKE_VERSION    {128 256}
set_choice_list $core DATA_WIDTH       {8 16 32 64}
set_choice_list $core ROUNDS_PER_CYCLE {1 2 3 4 6 8 12 24}
set_range       $core SHAKE_BITS 8 65536

# defaults: plain SHA3-256 hash, 32-bit AXIS, one round per clock
set_property value SHA3 [ipx::get_user_parameters ALGORITHM        -of_objects $core]
set_property value 256  [ipx::get_user_parameters SHA3_VERSION     -of_objects $core]
set_property value 256  [ipx::get_user_parameters SHAKE_VERSION    -of_objects $core]
set_property value 1024 [ipx::get_user_parameters SHAKE_BITS       -of_objects $core]
set_property value 32   [ipx::get_user_parameters DATA_WIDTH       -of_objects $core]
set_property value 1    [ipx::get_user_parameters ROUNDS_PER_CYCLE -of_objects $core]

set_property display_name {Algorithm}                  [ipx::get_user_parameters ALGORITHM        -of_objects $core]
set_property display_name {SHA-3 digest size (bits)}   [ipx::get_user_parameters SHA3_VERSION     -of_objects $core]
set_property display_name {SHAKE security strength}    [ipx::get_user_parameters SHAKE_VERSION    -of_objects $core]
set_property display_name {SHAKE output length (bits)} [ipx::get_user_parameters SHAKE_BITS       -of_objects $core]
set_property display_name {AXIS data width (bits)}     [ipx::get_user_parameters DATA_WIDTH       -of_objects $core]
set_property display_name {Keccak rounds per cycle}    [ipx::get_user_parameters ROUNDS_PER_CYCLE -of_objects $core]

# dynamic enablement -- safe [string equal ...] form, never bare == (bareword!)
if {[catch {
    set_property enablement_tcl_expr {[string equal $ALGORITHM "SHA3"]} \
        [ipx::get_user_parameters SHA3_VERSION -of_objects $core]
    set_property enablement_tcl_expr {[expr [string equal $ALGORITHM "SHAKE"] || [string equal $ALGORITHM "CSHAKE"]]} \
        [ipx::get_user_parameters SHAKE_VERSION -of_objects $core]
    set_property enablement_tcl_expr {[expr [string equal $ALGORITHM "SHAKE"] || [string equal $ALGORITHM "CSHAKE"]]} \
        [ipx::get_user_parameters SHAKE_BITS -of_objects $core]
} err]} { puts "WARN: enablement_tcl_expr: $err" }

# initial enablement snapshot (what the GUI shows BEFORE the first ALGORITHM
# change -- update procs only fire on changes). Must match ALGORITHM=SHA3.
if {[catch {
    set_property enablement_value true  [ipx::get_user_parameters SHA3_VERSION  -of_objects $core]
    set_property enablement_value false [ipx::get_user_parameters SHAKE_VERSION -of_objects $core]
    set_property enablement_value false [ipx::get_user_parameters SHAKE_BITS    -of_objects $core]
} err]} { puts "WARN: enablement snapshot: $err" }

# ============================================================================
# save
# ============================================================================
set_property core_revision [expr {[get_property core_revision $core] + 1}] $core
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core
close_project

# ============================================================================
# gtcl + xgui rewrite (AFTER save so nothing clobbers it)
# ============================================================================
set base "${IPNAME}_v1_0"

# gtcl: enablement bodies in the safe string-equal form
file mkdir $IPDIR/gui
set f [open $IPDIR/gui/$base.gtcl w]
puts $f {# This file is automatically written.  Do not modify.}
puts $f {proc gen_USERPARAMETER_SHA3_VERSION_ENABLEMENT {ALGORITHM } {expr [string equal $ALGORITHM "SHA3"]}}
puts $f {proc gen_USERPARAMETER_SHAKE_VERSION_ENABLEMENT {ALGORITHM } {expr [string equal $ALGORITHM "SHAKE"] || [string equal $ALGORITHM "CSHAKE"]}}
puts $f {proc gen_USERPARAMETER_SHAKE_BITS_ENABLEMENT {ALGORITHM } {expr [string equal $ALGORITHM "SHAKE"] || [string equal $ALGORITHM "CSHAKE"]}}
close $f

set out ""
append out "\n# Loading additional proc with user specified bodies to compute parameter values.\n"
append out "source \[file join \[file dirname \[file dirname \[info script\]\]\] gui/$base.gtcl\]\n"
append out "\n# Definitional proc to organize widgets for parameters.\n"
append out "proc init_gui \{ IPINST \} \{\n"
append out "  ipgui::add_param \$IPINST -name \"Component_Name\"\n"
append out "  #Adding Page\n"
append out "  set Page_0 \[ipgui::add_page \$IPINST -name \"Page 0\"\]\n"

append out [xgui_param_line ALGORITHM comboBox \
    {SHA3 = fixed-length hash (SHA3-224/256/384/512); SHAKE = extendable-output function (XOF); CSHAKE = customizable SHAKE (SP 800-185, also covers KMAC) -- the N/S prefix block and KMAC key/length encodings are sent by software as ordinary message data}]
append out [xgui_param_line SHA3_VERSION comboBox \
    {SHA3 only: digest size in bits; sponge rate = 1600 - 2*digest. Note: SHA3-224 supports AXIS data width up to 32 (224 is not divisible by 64)}]
append out [xgui_param_line SHAKE_VERSION comboBox \
    {SHAKE/CSHAKE only: security strength. 128 -> rate 1344 bits (faster), 256 -> rate 1088 bits (stronger). Output length is set separately by SHAKE output length}]
append out [xgui_param_line SHAKE_BITS "" \
    {SHAKE/CSHAKE only: total XOF output length in bits; any multiple of the AXIS data width. Outputs longer than the rate are squeezed in several chunks (one extra 24-round permutation per chunk); resources do not grow with this value}]
append out [xgui_param_line DATA_WIDTH comboBox \
    {AXI-Stream data width in bits. Must divide both the sponge rate and the output size -- illegal combinations are rejected at elaboration}]
append out [xgui_param_line ROUNDS_PER_CYCLE comboBox \
    {Keccak-f[1600] rounds applied per clock cycle (any divisor of 24). Values above 2 give diminishing fmax returns -- 1 or 2 recommended}]
append out "\}\n"

append out [xgui_dynamic_procs    SHA3_VERSION  ALGORITHM SHA3]
append out [xgui_dynamic_procs_or SHAKE_VERSION ALGORITHM SHAKE CSHAKE]
append out [xgui_dynamic_procs_or SHAKE_BITS    ALGORITHM SHAKE CSHAKE]
foreach p {ALGORITHM DATA_WIDTH ROUNDS_PER_CYCLE} {
    append out [xgui_plain_procs $p]
}
foreach p {ALGORITHM SHA3_VERSION SHAKE_VERSION SHAKE_BITS DATA_WIDTH ROUNDS_PER_CYCLE} {
    append out [xgui_modelparam_procs $p]
}

file mkdir $IPDIR/xgui
set f [open $IPDIR/xgui/$base.tcl w]
puts $f $out
close $f

# Remove stale xgui leftovers -- only $base.tcl is referenced by component.xml
foreach f [glob -nocomplain $IPDIR/xgui/*.tcl] {
    if {[file tail $f] ne "$base.tcl"} {
        file delete $f
        puts "removed stale xgui: [file tail $f]"
    }
}

puts ""
puts "==== DONE -> $IPDIR/component.xml ($IPNAME v1.0) ===="
puts "Add [file normalize $IPDIR] as an IP repository path"
puts "(Settings -> IP -> Repository); the core appears as \"$DISP\"."
exit 0
