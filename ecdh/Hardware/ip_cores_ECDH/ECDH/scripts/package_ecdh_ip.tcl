# ------------------------------------------------------------------------------
# package_ecdh_ip.tcl — packages the unified ECDH IP core (top entity ecdh_axis_ip)
#
# One IP with the boolean generic G_LOW_LATENCY (a checkbox in the GUI):
#   true  -> ecdh_core_low_latency (parallel step, minimum latency)
#   false -> ecdh_core_basic       (baseline, small area)
# Both configurations give a bit-identical result; only the resource/latency
# trade-off differs.
#
# Run (from any directory):
#   /tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch -source package_ecdh_ip.tcl
#
# Output: component.xml + xgui/ in the IP root (ip_cores_ECDH/ECDH) —
# the ip_cores_ECDH/ folder is added in Vivado as an IP Repository path.
# Build artifacts (temporary project, logs) go to scripts/build/ (git-ignored).
# ------------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
set ip_root    [file normalize "$script_dir/.."]
set build_dir  "$script_dir/build"
file mkdir $build_dir

# Kria K26 SOM (the thesis target platform); packaging itself is part-agnostic.
set part xck26-sfvc784-2LV-c
if {[lsearch -exact [get_parts] $part] < 0} {
    set part [lindex [get_parts] 0]
    puts "WARNING: K26 part not in this installation, using $part (packaging is part-agnostic)"
}

create_project -force pkg_ecdh "$build_dir/pkg_ecdh" -part $part

# All 16 modules (shared + BOTH cores + the unified top). The if-generate in
# ecdh_axis_ip picks the core by G_LOW_LATENCY; only the chosen branch is
# synthesized.
set active_files {}
foreach f {gf_alu_pkg gf_add gf_sqr gf_mul gf_inv gf_alu ec_cswap \
           ec_step_mxy ecdh_core_basic \
           ec_point_step_par ec_scalar_mult_par ec_mxy_batch ecdh_core_low_latency \
           ecdh_deserializer ecdh_serializer ecdh_axis_ip} {
    lappend active_files "$ip_root/src/$f.vhd"
}
add_files -norecurse $active_files
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top ecdh_axis_ip [current_fileset]
update_compile_order -fileset sources_1

# Package into the IP root; files are referenced relatively (not copied)
ipx::package_project -root_dir $ip_root -vendor etf.bg.ac.rs -library user \
    -taxonomy /UserIP -import_files false -set_current true

set core [ipx::current_core]
set_property name          ECDH $core
set_property display_name  {ECDH accelerator (GF(2^571), G_LOW_LATENCY select)} $core
set_property description   {ECDH k*P accelerator over GF(2^m), NIST B-571. AXI-Stream wrapper: packet cmd|Qx|Qy in, public result on m_axis, shared secret x(S) on m_axis_z (straight to KMAC, never the PS). Private scalar k via side-band strobe. Boolean generic G_LOW_LATENCY selects the compute core: true = parallel min-latency (ecdh_core_low_latency), false = baseline small-area (ecdh_core_basic); identical result, only area/latency differ.} $core
set_property version       1.0 $core
# ECDH v1.0: one IP, both cores; G_LOW_LATENCY selects the core (if-generate)
set_property core_revision 1 $core
set_property auto_family_support_level level_2 $core

# i_clk does not follow the *aclk pattern, so the AXIS clock associations are set here
ipx::associate_bus_interfaces -busif s_axis   -clock i_clk $core
ipx::associate_bus_interfaces -busif m_axis   -clock i_clk $core
ipx::associate_bus_interfaces -busif m_axis_z -clock i_clk $core

# create_xgui_files picks up all entity generics automatically, including the
# boolean G_LOW_LATENCY (rendered as a checkbox in the IP customization GUI).
ipx::create_xgui_files  $core
ipx::update_checksums   $core
ipx::check_integrity    $core
ipx::save_core          $core
close_project

puts "PACKAGING DONE: $ip_root/component.xml"
