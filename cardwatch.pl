#!/usr/bin/perl -w
################################################################################
BEGIN {
        # figure out where we are and include our relative lib directory
        use Cwd;
        my $script=$0;
        my $pwd = getcwd();
        my $libdir = $pwd;
        if($0=~s/(.*)\/([^\/]*)//){
            $script = $2;
            my $oldpwd = $pwd;
            chdir($1);
            $pwd = getcwd();
            if($libdir=~m/\/bin$/){
                $libdir=$pwd; $libdir=~s/\/bin$/\/lib/;
            }else{
                $libdir="$pwd/lib";
            }
        }
        unshift(@INC,"$libdir") if ( -d "$libdir");
      }
################################################################################
package Log::Tail::Reporter;
use POE qw(Wheel::FollowTail);
use YAML;
use Template::Regex;
use POE::Filter::Stream;
use POE::Wheel::Run;
use POE qw(Component::IRC);
use LWP::Simple;
use JSON;
use Net::LDAP;


# Net::Infrastructure is what we use to match 
# use Net::Infrastructure; 

sub new {
    my $class = shift;
    my $self = {};
    my $cnstr = shift if @_;
    bless($self,$class);
    foreach my $argument ('server', 'port', 'channel', 'nick', 'ircname'){
        $self->{$argument} = $cnstr->{$argument} if($cnstr->{$argument});
    }
    foreach my $arg ('file', 'template'){
        if(! defined($cnstr->{$arg})){
            print STDERR "Necessary parameter [ $arg ] not defined. Aborting object.\n";
            return undef;
        }
    }
    $self->{'file'} = $cnstr->{'file'} if($cnstr->{'file'});
    $self->{'max_lines'}=$cnstr->{'max_lines'}||undef;
    $self->{'TR'} = new Template::Regex;
    $self->{'TR'}->load_template_file($cnstr->{'template'});
    $self->{'irc'} = POE::Component::IRC->spawn(
                                                 nick => $self->{'nick'},
                                                 ircname => $self->{'ircname'},
                                                 server  => $self->{'server'},
                                               ) or die "Oh noooo! $!";
    POE::Session->create(
                          object_states => [
                                             $self => [ 
                                                        '_start',
                                                        'help', 
                                                        'got_log_line', 
                                                        'got_log_rollover',
                                                        'sketch_connection',
                                                        'send_sketch',
                                                        '_default',
                                                        'irc_001',
                                                        'irc_public',
                                                        'start_log',
                                                        'event_timeout',
                                                        'printer_lookup',
                                                        'location_lookup',
                                                        'spawn',
                                                        'on_child_stdout',
                                                        'on_child_stderr',
                                                        'on_child_close',
                                                        'on_child_signal',
                                                        'watch',
                                                        'watchlist',
                                                        'run_watchlist',
                                                        'unwatch',
                                                        'say',
                                                        'state_change',
                                                      ],
                                           ],
    );
    return $self;
}

sub _start {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    $_[HEAP]{linecount}=0;
    $heap->{'watchlist'} = [];
    $self->{'irc'}->yield( register => 'all' );
    $self->{'irc'}->yield( connect => { } );
    $kernel->delay('start_log',5);
    $kernel->delay('run_watchlist',5);
    return;
}

sub start_log {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    print STDERR "Loading Log.\n";
    $heap->{'tailor'} = POE::Wheel::FollowTail->new(
                                                     Filename   => $self->{'file'},
                                                     InputEvent => "got_log_line",
                                                     ResetEvent => "got_log_rollover",
                                                     #Seek   => 0,
                                                   );
    return;
}

sub ip2n{
    my $self=shift;
    return unpack N => pack CCCC => split /\./ => shift;
}

sub n2ip{
    my $self=shift;
    return join('.',map { ($_[0] >> 8*(3-$_)) % 256 } 0 .. 3);
}

sub got_log_line {
   my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   my $line = $args[0];
   my $result = $self->{'TR'}->parse_line($line);
   my $last = $#{ $result->{'patterns'} } - 1;
   my $output = $result->{'name'};
   if( $output =~ m/remainder$/ ){
       $output =~ s/remainder$/\[$result->{'patterns'}->[ $last ]\]/;
   }else{
       $heap->{'last'}='' unless( defined($heap->{'last'}) );
       # remove line-after-line of repeated output
       if($heap->{'last'} ne $result->{'name'}){
           $kernel->yield("sketch_connection",$result->{'name'}, $result->{'patterns'}, $line);
           $heap->{'last'} = $result->{'name'};
       }
   }
} 

sub watch{
   my ($self, $kernel, $heap, $sender, $device, $replyto, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   push(@{ $heap->{'watchlist'} }, $device) unless(grep /$device/, @{ $heap->{'watchlist'} });
   $self->{'irc'}->yield( privmsg => $replyto => "watching $device");
}

sub unwatch{
   my ($self, $kernel, $heap, $sender, $device, $replyto, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   my $new_watchlist;
   while (my $inspect = shift(@{ $heap->{'watchlist'} })){
       push(@{ $new_watchlist }, $inspect ) unless($inspect eq $device);
   }
   $heap->{'watchlist'} = $new_watchlist;
   $self->{'irc'}->yield( privmsg => $replyto => "$device unwatched");
}

sub watchlist{
   my ($self, $kernel, $heap, $sender, $replyto, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   if($#{ $heap->{'watchlist'} } > -1){
       $self->{'irc'}->yield( privmsg => $replyto => "currently watching: [".join(", ", @{ $heap->{'watchlist'} })."]");
   }else{
       $self->{'irc'}->yield( privmsg => $replyto => "not currently watching any devices.");
   }
}

sub run_watchlist{
   my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   foreach my $device (@{ $heap->{'watchlist'} }){
        $kernel->yield('spawn', ["rtatiem_curt",$self->sanitize($device)],"state_change");
   }
   # run the watch list in 10 
   $kernel->delay('run_watchlist',30);
}

sub state_change{
   my ($self, $kernel, $heap, $sender, $devicestate, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
   my ($device, $state) = $devicestate =~ /\s*(\S+)\s*=>\s*(.*)\s*/;
   $state=~s/\s+$//; $state=~s/^\s+//;
   $device=~s/\s+$//; $device=~s/^\s+//;
   if($state){
       unless($state =~/^\s*$/){
           if ($heap->{'watched'}->{$device} ne $state){
               $kernel->yield('say', "$device changed state to => $state");
               $heap->{'watched'}->{$device} = $state;
           }
       }
   }
}

sub event_timeout{
    my ($self, $kernel, $heap, $sender, $id, $message, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    if($heap->{'pending'}->{$id}){
        # $kernel->yield('send_sketch', "$id: $message"); 
        my $job = $id;
        $job=~tr/A-Z/a-z/;
        if($job=~m/[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+/){
            my $json = JSON->new->allow_nonref;
            my $struct = '';
            eval {
              $struct = $json->decode( get("http://quark.$domainname:9090/caoPrinterStatus/job/$job") );
            };
            if($@){
                $self->{'irc'}->yield( privmsg => $channel => "$@");
                $self->{'irc'}->yield( privmsg => $channel => "(while fetching http://quark.$domainname:9090/caoPrinterStatus/job/$job)");
                $self->{'irc'}->yield( privmsg => $channel => "^^^^^^^^^^^^^^^^^^^^ aleclanter?");
                return;
            }
            $struct=~tr/A-Z/a-z/;
            $self->{'irc'}->yield( privmsg => $channel => "Job: $id: $struct");
        }
        delete ($heap->{'pending'}->{$id});
    }
}

sub send_sketch {
    my ($self, $kernel, $heap, $sender, $sketch, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    print "SKETCH: $sketch\n";
    $self->{'irc'}->yield( privmsg => $self->{'channel'} => "$sketch");
}

sub sketch_connection {
    my ($self, $kernel, $heap, $sender, $match, $args, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my @ignore = ( );
    my $ignore=0;
    foreach my $i (@ignore){ if($match =~m/$i/){ $ignore=1; } }
    if($ignore == 1){
        # do nothing, we dont' care about these right now.
        print "";
    }elsif ($match eq 'windows_event.printer_jobstatus'){
        $args->[3]=~s/\..*//g; $args->[3]=~tr/A-Z/a-z/;
        $args->[7]=~s/\..*//g; $args->[7]=~tr/A-Z/a-z/;
        $args->[10]=~s/\..*//g; $args->[10]=~tr/A-Z/a-z/;
        $args->[11]=~s/\..*//g; $args->[11]=~tr/A-Z/a-z/;
        next if ( $args->[3] =~ m/^arctic/) ; # ignore the lab
        next if ( $args->[7] =~ m/^prnt0024/) ; # ignore the qa printer
        next if ( $args->[7] =~ m/^fermion/) ; # ignore the qa printer
        $kernel->yield('send_sketch', "Job: $args->[10]: $args->[7] ($args->[11])");
    }elsif ($match eq 'windows_event.printer_jobid'){
        $args->[3]=~s/\..*//g; $args->[3]=~tr/A-Z/a-z/;
        $args->[7]=~s/\..*//g; $args->[7]=~tr/A-Z/a-z/;
        next if ( $args->[3] =~ m/^arctic/) ; # ignore the lab
        next if ( $args->[7] =~ m/^prnt0024/) ; # ignore the qa printer
        $kernel->yield('send_sketch', "Job: $args->[10]: $args->[7]");
        $heap->{'pending'}->{ $args->[10] }->{'host'} = $args->[7];
        $kernel->delay('event_timeout', 180, $args->[10],"job timed out");
    }elsif ($match eq 'windows_event.dualsys_work_thread_msg'){
        $args->[3]=~s/\..*//g; $args->[3]=~tr/A-Z/a-z/;
        $args->[7]=~s/\..*//g; $args->[7]=~tr/A-Z/a-z/;
        $args->[9]=~s/\..*//g; $args->[9]=~tr/A-Z/a-z/;
        next if ( $args->[3] =~ m/^arctic/) ; # ignore the lab
        next if ( $args->[7] =~ m/^prnt0024/) ; # ignore the qa printer
        $kernel->yield('send_sketch',"$args->[7]: $args->[9]") unless(( $args->[9]=~m/^ok$/i) || ( $args->[9]=~m/^5,00 volts$/i));
    }elsif ($match eq 'windows_event.print_end'){
        $args->[8]=~tr/A-Z/a-z/; $args->[9]=~tr/A-Z/a-z/;
        # ignore things we're not waiting for:
        if($heap->{'pending'}->{$args->[8]}){
                delete($heap->{'pending'}->{$args->[8]});
                $kernel->yield('send_sketch', "Job: $args->[8]: $args->[9]");
        }
    }
}

sub got_log_rollover {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    print STDERR "Log rolled over.\n"; 
}

sub lookup_printer{
    my $self = shift;
    my $soekris = shift||undef;
    return undef unless defined($soekris);
    my $fqdn = `hostname -f`;
    chomp($fqdn);
    my @parts = split(/\./,$fqdn);
    my $hostname = shift(@parts);
    my $domainname = join('.',@parts);
    my $basedn = "dc=".join(',dc=',@parts);
    my $ldap = Net::LDAP->new( "ldap.$domainname" ) or warn "$@\n";
    $mesg = $ldap->bind;
    print STDERR $mesg->error."\n" if $mesg->code;
    $mesg = $ldap->search( base   => "ou=Card\@Once,$basedn", filter => "(uniqueMember=cn=$soekris,ou=Hosts,$basedn)", scope=> 'sub');
    print STDERR $mesg->error."\n" if $mesg->code;
    my $found = 0;
    foreach $entry ($mesg->entries) {
        $found ++;
        my $distname = $entry->dn;
        $distname=~s/,\s+/,/g;
        my ($city, $branch);
        if($distname =~m/cn=(.*),\s*ou=Systems,ou=(.*),*ou=Card\@Once,$basedn/){
            ($city,$branch) = ($1, $2);
            $city=~s/,$//;
        }
        return "$branch ($city)";
    }
    unless ($found > 0){
        return undef;
    }
}

sub printer_lookup{
    my ($self, $kernel, $heap, $sender, $soekris, $replyto, $who, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $description = $self->lookup_printer($soekris);
    if($description){
        $self->{'irc'}->yield( privmsg => $replyto => "$soekris => $description");
    }else{
        $self->{'irc'}->yield( privmsg => $replyto => "$soekris not found. (did you forget to put it in LDAP ou=Card\@Once?)");
    }
}

sub lookup_location{
    my $self = shift;
    my $location = shift if @_;
    return undef unless defined($location);
    my $fqdn = `hostname -f`;
    chomp($fqdn);
    my @parts = split(/\./,$fqdn);
    my $hostname = shift(@parts);
    my $domainname = join('.',@parts);
    my $basedn = "dc=".join(',dc=',@parts);
    my $ldap = Net::LDAP->new( "ldap.$domainname" ) or warn "$@\n";
    my $mesg = $ldap->bind;
    print STDERR $mesg->error."\n" if $mesg->code;
    $mesg = $ldap->search( base   => "ou=Card\@Once,$basedn", filter => "(&(uniqueMember=cn=skrs*)(cn=*$location*))", scope=> 'sub');
    print STDERR $mesg->error."\n" if $mesg->code;
    my $found = 0;
    my $printers = [];
    foreach $entry ($mesg->entries) {
        my $distname = $entry->dn;
        $distname=~s/,\s+/,/g;
        my ($city, $branch);
        if($distname =~m/cn=(.*),\s*ou=Systems,ou=(.*),*ou=Card\@Once,$basedn/){
            ($city,$branch) = ($1, $2);
            $city=~s/,$//;
        }
        foreach my $member ( $entry->get_value( 'uniqueMember' ) ){
            $member=~s/^cn=//; # just the printer
            $member=~s/,.*//;
            push (@{ $printers },"$city, $branch => $member");
        }
        $found ++;
    }
    unless ($found > 0){
        return undef;
    }
    return $printers;
}

sub help {
    my ($self, $kernel, $heap, $sender, $topic, $channel, $nick, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $helpreply = undef;
    my $helpdata = { 
                     'address'   => [ 
                                      "Request the address of a bank branch",
                                      "Usage: address <bank branch>",
                                      "Example: address Old Fort",
                                    ],
                     'cgi'       => [
                                      "Test the cgi on a soekris",
                                      "Usage: cgi <[skrs]nnnn>",
                                      "Example: cgi skrs0088"
                                    ],
                     'firmware'  => [
                                      "check the firmware on a printer",
                                      "Usage: firmware <[prnt]nnnn>",
                                      "Example: firmware skrs0088"
                                    ],
                     'isup'      => [
                                      "check if a soekris is up",
                                      "Usage: is <[skrs]nnnn> up",
                                      "Example: is skrs0088 up?"
                                    ],
                     'jobstatus' => [
                                      "check the status of a job",
                                      "Usage: jobstatus <job_id>",
                                      "Example: jobstatus be52c1f6-1841-481b-9d61-982a5f2606ec",
                                      
                                    ],
                     'ping'      => [
                                      "check if a soekris is up",
                                      "Usage: ping <[skrs]nnnn>",
                                      "Example: ping skrs0088",
                                    ],
                     'report'    => [
                                      "report on todays prints",
                                      "Usage: report"
                                    ],
                     'status'    => [
                                      "check if a soekris is up, and check it's cgi",
                                      "Usage: status <[skrs]nnnn>",
                                      "Example: status skrs0088",
                                    ],
                     'watch'     => [
                                      "watch a soekris for up/down changes",
                                      "Usage: watch <[skrs]nnnn>",
                                      "Example: watch skrs0088",
                                    ],
                     'where'     => [
                                      "find where a soekris is located",
                                      "Usage: where is <[skrs]nnnn>",
                                      "Example: where is skrs0088",
                                    ],
                     'which'     => [
                                      "find which a soekris is at a branch",
                                      "Usage: which is <bank branch>",
                                      "Example: which is Cecilian",
                                    ],
                     'unwatch'   => [
                                      "stop watching a soekris for up/down changes",
                                      "Usage: unwatch <[skrs]nnnn>",
                                      "Example: unwatch skrs0088",
                                    ],
                     'watchlist' => [
                                      "display which soekris boxes are currently being watched",
                                      "Usage: watchlist",
                                    ],

                   };
    
    if(!defined($topic) || ($topic eq '')){
        print STDERR "help 1\n";
        $helpreply = [
                       "help topics: [ address, cgi, firmware, isup, jobstatus, ping, report, status, unwatch, watch, watchlist ]",
                       "use 'help <topic>' for specifics (e.g. 'help ping')",
                     ];
    }elsif(grep( /^$topic$/, keys(%{ $helpdata }) )){ 
        print STDERR "help 2\n";
        $helpreply = $helpdata->{$topic}; 
    }else{
        print STDERR "help 3\n";
       return;
    }
    foreach $reply (@{ $helpreply }){
        $self->{'irc'}->yield( privmsg => $channel => "$reply") if(defined($helpreply));
    }
}


sub location_lookup{
    my ($self, $kernel, $heap, $sender, $location, $replyto, $who, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $devices = $self->lookup_location($location);
    if($devices){
        foreach my $skrs (@{ $devices }){
            $self->{'irc'}->yield( privmsg => $replyto => "$skrs");
        }
    }else{
        $self->{'irc'}->yield( privmsg => $replyto => "$location not found. (did you forget to put it in LDAP ou=Card\@Once?)");
    }
}

sub irc_001 {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];

     # Since this is an irc_* event, we can get the component's object by
     # accessing the heap of the sender. Then we register and connect to the
     # specified server.
     my $irc = $sender->get_heap();

     print "Connected to ", $irc->server_name(), "\n";

     # we join our channels
     $irc->yield( join => $_ ) for ($self->{'channel'});
     return;
}

sub sanitize {
    my $self = shift;
    my $device = shift if @_;
    return "" unless $device;
    $device=~s/\..*//; 
    $device=~s/\s*//; 
    $device=~tr/A-Z/a-z/; 
    $device=~s/^[Ss][Kk][Rr][Ss]//;
    $device=~s/^[Pp][Rr][Nn][Tt]//;
    $device=~s/^0*//;
    if($device=~m/[0-9]+/){
        if($device < 10){ $soekris="skrs000$device"; }
        elsif($device < 100){ $soekris="skrs00$device"; }
        elsif($device < 1000){ $soekris="skrs0$device"; }
        elsif($device < 10000){ $soekris="skrs$device"; }
        return $soekris;
    }
    return "";
}

sub irc_public {
    my ($self, $kernel, $heap, $sender, $who, $where, $what, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];
    my $soekris=undef;
    my $fqdn = `hostname -f`;
    chomp($fqdn);
    my @parts = split(/\./,$fqdn);
    my $hostname = shift(@parts);
    my $domainname = join('.',@parts);

    print "$what\n";
    if ( my ($device) = $what =~ /^\s*[Hh][Ee][Ll][Pp]\s*(.*)$/ ){ 
        $kernel->yield('help',$1,$channel,$nick);
    }elsif ( my ($device) = $what =~ /^\s*[Ww]here\s*is\s*(\S*[0-9]+)\s*\?*$/ ){ 
        $kernel->yield('printer_lookup',$self->sanitize($device),$channel,$nick);
    }elsif ( my ($device) = $what =~ /^\s*[Ii]s\s*(\S*[0-9]+)\s*up\s*\?*$/ ){ 
        $self->{'irc'}->yield( privmsg => $where => "I'll check...");
        $kernel->yield('spawn', ["rtatiem",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*ping\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "pinging...");
        $kernel->yield('spawn', ["rtatiem",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*cgi\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "querying the cgi...");
        $kernel->yield('spawn', ["prnthealth",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*status\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "checking the status...");
        $kernel->yield('spawn', ["rtatiem",$self->sanitize($device)]);
        $kernel->yield('spawn', ["prnthealth",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*firmware\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "looking...");
        $kernel->yield('spawn', ["firmware",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*firmware\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "looking...");
        $kernel->yield('spawn', ["firmware",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*cert\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "fetching certificate...");
        $kernel->yield('spawn', ["certificate_check",$self->sanitize($device)],"say");
    }elsif ( $what =~ /^\s*[Ww]hich\s*(skrs|prnt|soekris|device|printer)*\s*(is)*\s*(.*)\s*\?*$/ ){
        my $search = $3;
        $search=~s/\s*\?\s*$//; # remove trailing question marks
        print "Initiate search for: $search\n";
        $kernel->yield('location_lookup',$search,$channel,$nick);
    }elsif ( my ($device) = $what =~ /^\s*recycle\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "recycling...");
        $kernel->yield('spawn', ["recycle",$self->sanitize($device)],"say");
    }elsif ( my ($device) = $what =~ /^\s*unlock\s*(\S*[0-9]+)\s*$/ ){
        $self->{'irc'}->yield( privmsg => $where => "attempting to remove lock...");
        $kernel->yield('spawn', ["unlock",$self->sanitize($device)],"say");
    }elsif ( $what =~ /^\s*!*report/ ){
        my $json = JSON->new->allow_nonref;
        my $struct;
        eval {
               $struct = $json->decode( get("http://quark.$domainname:9090/caoPrinterStatus/") );
        };
        if($@){
            $self->{'irc'}->yield( privmsg => $channel => "$@");
            $self->{'irc'}->yield( privmsg => $channel => "(while fetching http://quark.$domainname:9090/caoPrinterStatus/)");
            $self->{'irc'}->yield( privmsg => $channel => "^^^^^^^^^^^^^^^^^^^^ aleclanter?");
            return;
        }
        $self->{'irc'}->yield( privmsg => $channel => "[Success/Total] Summary");
        $self->{'irc'}->yield( privmsg => $channel => "------------------------------");
        foreach my $item (@{ $struct }){
            my $soekris=$self->sanitize($item->{'PrinterName'});
            my $location=$self->lookup_printer($soekris);
            my $total = ($item->{'GoodJobs'} + $item->{'BadJobs'});
            my $percentage = int(10000*($item->{'GoodJobs'}/$total))/100;
            $self->{'irc'}->yield( privmsg => $channel => "[$item->{'GoodJobs'}/$total] $location ($percentage%)\n") if(defined($location));
        }
        $self->{'irc'}->yield( privmsg => $channel => "------------------------------");
    }elsif ( $what =~ /^\s*!*job\s*(status)\s+(\S+)/ || $what =~ /[Ww]hat\s*(wa|i|')s\s+the\s+status\s+of\s+job\s+(\S+)\s*\?*\s*/ ){
        my $job = $2;
        $job=~tr/A-Z/a-z/;
        if($job=~m/[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+/){
            my $json = JSON->new->allow_nonref;
            my $struct = $json->decode( get("http://quark.$domainname:9090/caoPrinterStatus/job/$job") );
            $self->{'irc'}->yield( privmsg => $channel => "$struct");
        }
    }elsif ( $what =~ /^\s*\!*address\s+(.*)/){
        my $site_name=$1;
        my $json = JSON->new->allow_nonref;
        my $addressdata;
        eval {
            $addressdata = $json->decode( get("http://quark.$domainname:9090/caoPrinterStatus/sites"));
        };

        if($@){
            print STDERR "caoPrinterStatus ERROR: $@\n";
            $self->{'irc'}->yield( privmsg => $channel => "Address Lookup Failed.");
        }else{
            my @names = ();
            foreach my $struct (@{ $addressdata }){
                if($struct->{'AddressName'} =~m/$site_name/i){
                    push(@names,$struct->{'AddressName'});
                }
            }
            if($#names > 3){
                my $namecount=$#names + 1;
                $self->{'irc'}->yield( privmsg => $channel => "Could you be more specific? That matches $namecount names... ".join(',',@names)."");
                return;
            }
            foreach my $struct (@{ $addressdata }){
                if($struct->{'AddressName'} =~m/$site_name/i){
                    my $address = $struct->{'Address1'};
                    my $geolookup = $struct->{'Address1'};
    
                    $address .= " ".$struct->{'Address2'} if(defined($struct->{'Address2'}));
                    $geolookup .= "+".$struct->{'Address2'} if(defined($struct->{'Address2'}));
        
                    $address .= " ".$struct->{'City'};
                    $geolookup .= "+".$struct->{'City'};
        
                    $address .= ", ".$struct->{'State'};
                    $geolookup .= "+".$struct->{'State'};
        
                    $address .= " ".$struct->{'Zip'};
                    $geolookup .= "+".$struct->{'Zip'};
                    my $geodata;
                    eval {
                        $geodata = $json->decode( get("http://maps.googleapis.com/maps/api/geocode/json?address=$geolookup&sensor=false"));
                    };
                    my $latlong;
                    if($geodata->{'status'} eq 'OK'){
                        $latlong = "($geodata->{'results'}->[0]->{'geometry'}->{'location'}->{'lat'}, $geodata->{'results'}->[0]->{'geometry'}->{'location'}->{'lng'})";
                    }else{
                        $latlong = "[ $geodata->{'status'} ]";
                    }
                    $self->{'irc'}->yield( privmsg => $channel => "$struct->{'AddressName'} =>  $address => $latlong");
                }
           }
        }
    }elsif ( my ($device) = $what =~ /^\s*watch\s*(\S*[0-9]+)\s*$/ ){
        $kernel->yield('watch', $self->sanitize($device),$where);
    }elsif ( my ($device) = $what =~ /^\s*unwatch\s*(\S*[0-9]+)\s*$/ ){
        $kernel->yield('unwatch', $self->sanitize($device),$where);
    }elsif ( my ($device) = $what =~ /^\s*watchlist\s*$/ ){
        $kernel->yield('watchlist',$where);
    }else{
        print STDERR "Unrecognized line\n";
    }
    return;
}

# We registered for all events, this will produce some debug info.
sub _default {
     my ($self, $kernel, $heap, $sender, $event, $args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
     my @output = ( "$event: " );

     for my $arg (@$args) {
         if ( ref $arg eq 'ARRAY' ) {
             push( @output, '[' . join(', ', @$arg ) . ']' );
         }
         else {
             push ( @output, "'$arg'" );
         }
     }
     print join ' ', @output, "\n";
     return;
}

sub spawn{
    my ($self, $kernel, $heap, $sender, $program, $reply_event) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    #print STDERR Data::Dumper->Dump([$program,$reply_event]);
    my $child = POE::Wheel::Run->new(
                                      Program      => $program,
                                      StdoutEvent  => "on_child_stdout",
                                      StderrEvent  => "on_child_stderr",
                                      CloseEvent   => "on_child_close",
                                    );

    $_[KERNEL]->sig_child($child->PID, "on_child_signal");

    # Wheel events include the wheel's ID.
    $_[HEAP]{children_by_wid}{$child->ID} = $child;

    # Signal events include the process ID.
    $_[HEAP]{children_by_pid}{$child->PID} = $child;

    # Save what device we're talking about
    $_[HEAP]{device}{$child->ID} = $program->[1];

    # Save what event will get the reply
    $_[HEAP]{reply_to}{$child->ID} = $reply_event;

    print("Child pid ", $child->PID, " started as wheel ", $child->ID, ".\n");
}

sub say{
    my ($self, $kernel, $heap, $sender, $say_this) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    $self->{'irc'}->yield( privmsg => $self->{'channel'} => $say_this );
}

sub on_child_stdout {
    my ($self, $kernel, $heap, $sender, $stdout_line, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = $_[HEAP]{children_by_wid}{$wheel_id};
    #print "pid ", $child->PID, " STDOUT: $stdout_line\n";

    my $device =  $_[HEAP]{device}{$wheel_id};
    $kernel->yield( $_[HEAP]{reply_to}{$wheel_id} , $self->sanitize($device)." => $stdout_line");
    #$self->{'irc'}->yield( privmsg => $self->{'channel'} => "$device => $stdout_line") unless( $stdout_line =~m/^\s*$/ ) ;
}

# Wheel event, including the wheel's ID.
sub on_child_stderr {
    my ($self, $kernel, $heap, $sender, $stderr_line, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = $_[HEAP]{children_by_wid}{$wheel_id};
    print "pid ", $child->PID, " STDERR: $stderr_line\n";
}

# Wheel event, including the wheel's ID.
sub on_child_close {
    my ($self, $kernel, $heap, $sender, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = delete $_[HEAP]{children_by_wid}{$wheel_id};
    delete $_[HEAP]{device}{$wheel_id};

    # May have been reaped by on_child_signal().
    unless (defined $child) {
      #print "wid $wheel_id closed all pipes.\n";
      return;
    }

    print "pid ", $child->PID, " closed all pipes.\n";
    delete $_[HEAP]{children_by_pid}{$child->PID};
}

sub on_child_signal {
    my ($self, $kernel, $heap, $sender, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    #print "pid $_[ARG1] exited with status $_[ARG2].\n";
    my $child = delete $_[HEAP]{children_by_pid}{$_[ARG1]};

    # May have been reaped by on_child_close().
    return unless defined $child;

    delete $_[HEAP]{children_by_wid}{$child->ID};
    delete $_[HEAP]{device}{$wheel_id};
}

1;

$|=1;
my $cisco  = Log::Tail::Reporter->new({ 
                                         'file'     => '/var/log/windows/applications.log',
                                         'template' => 'windows.yml',
                                         'server'   => 'irc',
                                         'ircname'  => 'Card@Once Watcher',
                                         'nick'     => 'cardwatch',
#                                         'nick'     => 'caobot',
                                         'channel'  => '#cao',
#                                         'channel'  => '#bottest',
                                       });
POE::Kernel->run();
exit;
