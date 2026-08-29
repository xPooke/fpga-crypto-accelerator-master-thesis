# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_B" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_D" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_F" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_LOW_LATENCY" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_M" -parent ${Page_0}


}

proc update_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to update DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to validate DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.G_B { PARAM_VALUE.G_B } {
	# Procedure called to update G_B when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_B { PARAM_VALUE.G_B } {
	# Procedure called to validate G_B
	return true
}

proc update_PARAM_VALUE.G_D { PARAM_VALUE.G_D } {
	# Procedure called to update G_D when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_D { PARAM_VALUE.G_D } {
	# Procedure called to validate G_D
	return true
}

proc update_PARAM_VALUE.G_F { PARAM_VALUE.G_F } {
	# Procedure called to update G_F when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_F { PARAM_VALUE.G_F } {
	# Procedure called to validate G_F
	return true
}

proc update_PARAM_VALUE.G_LOW_LATENCY { PARAM_VALUE.G_LOW_LATENCY } {
	# Procedure called to update G_LOW_LATENCY when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_LOW_LATENCY { PARAM_VALUE.G_LOW_LATENCY } {
	# Procedure called to validate G_LOW_LATENCY
	return true
}

proc update_PARAM_VALUE.G_M { PARAM_VALUE.G_M } {
	# Procedure called to update G_M when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_M { PARAM_VALUE.G_M } {
	# Procedure called to validate G_M
	return true
}


proc update_MODELPARAM_VALUE.G_M { MODELPARAM_VALUE.G_M PARAM_VALUE.G_M } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_M}] ${MODELPARAM_VALUE.G_M}
}

proc update_MODELPARAM_VALUE.G_D { MODELPARAM_VALUE.G_D PARAM_VALUE.G_D } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_D}] ${MODELPARAM_VALUE.G_D}
}

proc update_MODELPARAM_VALUE.G_F { MODELPARAM_VALUE.G_F PARAM_VALUE.G_F } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_F}] ${MODELPARAM_VALUE.G_F}
}

proc update_MODELPARAM_VALUE.G_B { MODELPARAM_VALUE.G_B PARAM_VALUE.G_B } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_B}] ${MODELPARAM_VALUE.G_B}
}

proc update_MODELPARAM_VALUE.DATA_WIDTH { MODELPARAM_VALUE.DATA_WIDTH PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DATA_WIDTH}] ${MODELPARAM_VALUE.DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.G_LOW_LATENCY { MODELPARAM_VALUE.G_LOW_LATENCY PARAM_VALUE.G_LOW_LATENCY } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_LOW_LATENCY}] ${MODELPARAM_VALUE.G_LOW_LATENCY}
}

