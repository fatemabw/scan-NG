#redef exit_only_after_terminate=T ;

@ifndef(zeek_init)
#Running on old bro that doesn't know about zeek events
global zeek_init: event();
event bro_init()
{
    event zeek_init();
}
@endif

module Scan;

export {

	 redef enum Notice::Type += {
		SkipPort, 	
		RemoveSkipPort, 
	}; 

	global portexclude_file = "" &redef ;
	redef portexclude_file = "/YURT/feeds/BRO-feeds/scan-portexclude" ; 

        type Idx: record {
                skip_port : port &type_column="t";
        } ;

        type portexclude_Val: record {
                skip_port : port &type_column="t";
		comment: string &optional ; 
        } ;

	global port_exclude_table: table[port] of portexclude_Val=table(); 
} 

event port_exclude(description: Input::TableDescription, tpe: Input::Event, left: Idx, right: portexclude_Val)
{
	local _msg = "" ; 

	print fmt ("%s", left$skip_port); 
	if ( tpe == Input::EVENT_NEW )
        {
		_msg = fmt ("Port %s added to skip_services", left$skip_port); 
		add skip_services[left$skip_port] ; 
		NOTICE([$note=SkipPort, $msg=fmt("%s", _msg)]);
	} 
	
	if ( tpe == Input::EVENT_REMOVED)
        {
		_msg = fmt ("Port %s removed from skip_services", left$skip_port); 
		delete skip_services[left$skip_port] ; 
		NOTICE([$note=RemoveSkipPort, $msg=fmt("%s", _msg)]);
	} 
}

event zeek_init() {
	Input::add_table([$source=portexclude_file, $mode=Input::REREAD, $name="port_exclude", $destination=port_exclude_table, $idx=Idx, $val=portexclude_Val, $ev=port_exclude]);
}

@ifndef(zeek_done)
#Running on old bro that doesn't know about zeek events
global zeek_done: event();
event bro_done()
{
    event zeek_done();
}
@endif

event zeek_done()
{

	for (p in skip_services) 
	print fmt ("%s", p); 
 } 
