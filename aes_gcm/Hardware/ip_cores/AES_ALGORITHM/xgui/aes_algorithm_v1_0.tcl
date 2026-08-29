# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AES_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FLOW_STYLE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "NUM_CORES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ROUND_STYLE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "WRAPPER_KIND" -parent ${Page_0}


}

proc update_PARAM_VALUE.AES_BITS { PARAM_VALUE.AES_BITS } {
	# Procedure called to update AES_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AES_BITS { PARAM_VALUE.AES_BITS } {
	# Procedure called to validate AES_BITS
	return true
}

proc update_PARAM_VALUE.FLOW_STYLE { PARAM_VALUE.FLOW_STYLE } {
	# Procedure called to update FLOW_STYLE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FLOW_STYLE { PARAM_VALUE.FLOW_STYLE } {
	# Procedure called to validate FLOW_STYLE
	return true
}

proc update_PARAM_VALUE.NUM_CORES { PARAM_VALUE.NUM_CORES } {
	# Procedure called to update NUM_CORES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.NUM_CORES { PARAM_VALUE.NUM_CORES } {
	# Procedure called to validate NUM_CORES
	return true
}

proc update_PARAM_VALUE.ROUND_STYLE { PARAM_VALUE.ROUND_STYLE } {
	# Procedure called to update ROUND_STYLE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ROUND_STYLE { PARAM_VALUE.ROUND_STYLE } {
	# Procedure called to validate ROUND_STYLE
	return true
}

proc update_PARAM_VALUE.WRAPPER_KIND { PARAM_VALUE.WRAPPER_KIND } {
	# Procedure called to update WRAPPER_KIND when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.WRAPPER_KIND { PARAM_VALUE.WRAPPER_KIND } {
	# Procedure called to validate WRAPPER_KIND
	return true
}


proc update_MODELPARAM_VALUE.AES_BITS { MODELPARAM_VALUE.AES_BITS PARAM_VALUE.AES_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AES_BITS}] ${MODELPARAM_VALUE.AES_BITS}
}

proc update_MODELPARAM_VALUE.ROUND_STYLE { MODELPARAM_VALUE.ROUND_STYLE PARAM_VALUE.ROUND_STYLE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ROUND_STYLE}] ${MODELPARAM_VALUE.ROUND_STYLE}
}

proc update_MODELPARAM_VALUE.FLOW_STYLE { MODELPARAM_VALUE.FLOW_STYLE PARAM_VALUE.FLOW_STYLE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FLOW_STYLE}] ${MODELPARAM_VALUE.FLOW_STYLE}
}

proc update_MODELPARAM_VALUE.WRAPPER_KIND { MODELPARAM_VALUE.WRAPPER_KIND PARAM_VALUE.WRAPPER_KIND } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.WRAPPER_KIND}] ${MODELPARAM_VALUE.WRAPPER_KIND}
}

proc update_MODELPARAM_VALUE.NUM_CORES { MODELPARAM_VALUE.NUM_CORES PARAM_VALUE.NUM_CORES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.NUM_CORES}] ${MODELPARAM_VALUE.NUM_CORES}
}

