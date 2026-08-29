# ---------------------------------------------------------------------------
# repackage_bypass_en.tcl
#
# Vivado batch script. For SPLIT_demux and MERGE_mux it:
#   1) keeps every generic user-editable in the IP customization GUI,
#   2) makes the bypass AXI-Stream interface DISAPPEAR from the Block Design
#      when the boolean generic BYPASS_EN = false
#      (SPLIT_demux : m_bypass_axis   MERGE_mux : s_bypass_axis),
#   3) ties off the disabled interface's input ports, refreshes the xgui and
#      packaging checksums, and re-packages.
#
# Run once from the repo root:
#
#   /tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
#       -source aes_gcm/Hardware/ip_cores/L3_WRAPPER_IP_CORES/repackage_bypass_en.tcl
#
# Afterwards, in the Block Design: remove + re-add the IP (or Report IP Status
# -> Upgrade Selected). With BYPASS_EN unticked the bypass interface pin is gone.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]

proc fix_core {core_dir iface} {
    set xml [file join $core_dir component.xml]
    if {![file exists $xml]} { error "no component.xml in $core_dir" }

    set core [ipx::open_core $xml]

    # 1) Every generic stays user-editable (never greyed out in the GUI).
    foreach up [ipx::get_user_parameters -of_objects $core] {
        set n [get_property name $up]
        if {$n eq "Component_Name"} continue
        set_property value_resolve_type user $up
    }

    # 2) Present the bypass interface only when BYPASS_EN is true. The
    #    INTERFACE-level enablement (busInterfaceInfo) is what makes the whole
    #    interface disappear from the Block Design symbol; the per-port
    #    enablement + input tie-offs keep the underlying pins consistent.
    set expr {spirit:decode(id('MODELPARAM_VALUE.BYPASS_EN')) = true}

    set bif [ipx::get_bus_interfaces $iface -of_objects $core]
    if {$bif eq ""} { error "no interface $iface in $core_dir" }
    set_property enablement_resolve_type dependent $bif
    set_property enablement_dependency   $expr      $bif

    set ports [ipx::get_ports ${iface}_* -of_objects $core]
    if {[llength $ports] == 0} { error "no ports matched ${iface}_* in $core_dir" }
    foreach p $ports {
        set_property enablement_resolve_type dependent $p
        set_property enablement_dependency   $expr      $p
        # A disable-able input needs a tie-off so it is defined when absent.
        if {[get_property direction $p] eq "in"} {
            set_property driver_value 0 $p
        }
    }

    # 3) Regenerate GUI + checksums and save.
    ipx::create_xgui_files $core
    ipx::update_checksums  $core
    ipx::check_integrity   $core
    ipx::save_core         $core

    puts "  == $core_dir =="
    foreach up [ipx::get_user_parameters -of_objects $core] {
        puts "     param [get_property name $up]  editable=[expr {[get_property value_resolve_type $up] eq {user}}]"
    }
    ipx::unload_core $core
}

fix_core [file join $here SPLIT_demux] m_bypass_axis
fix_core [file join $here MERGE_mux]   s_bypass_axis
puts "== DONE. Re-add / upgrade the IP in the Block Design to apply. =="
