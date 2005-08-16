# Author: Chris "BinGOs" Williams
# Derived from some code by Dennis Taylor
#
# This module may be used, modified, and distributed under the same
# terms as Perl itself. Please see the license that came with your Perl
# distribution for details.
#

package POE::Component::Client::NNTP;

use strict;
use warnings;
use POE qw( Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW
            Filter::Line Filter::Stream );
use Carp;
use Socket;
use Sys::Hostname;
use vars qw($VERSION);

$VERSION = '0.5';

sub spawn {
  my ($package,$alias,$hash) = splice @_, 0, 3;
  my ($package_events) = {};

  foreach ( qw(article body head stat group help ihave last list newgroups newnews next post quit slave authinfo) ) {
    $package_events->{$_} = 'accept_input';
  }

  unless ( $alias ) {
        croak "Not enough parameters to $package::spawn()";
  }

  unless (ref $hash eq 'HASH') {
        croak "Second argument to $package::spawn() must be a hash reference";
  }
  
  $hash->{'NNTPServer'} = "news" unless ( defined ( $hash->{'NNTPServer'} ) or defined ( $ENV{'NNTPSERVER'} ) );
  $hash->{'NNTPServer'} = $ENV{'NNTPSERVER'} unless defined ( $hash->{'NNTPServer'} );
  $hash->{'Port'} = 119 unless defined ( $hash->{'Port'} );
  
  my $self = bless { }, $package;
  
  $self->{remoteserver} = $hash->{'NNTPServer'};
  $self->{serverport} = $hash->{'Port'};
  $self->{localaddr} = $hash->{'LocalAddr'};

  $self->{session_id} = POE::Session->create(
			object_states => [
                          $self => [ qw(_start _stop _sock_up _sock_down _sock_failed _parseline register unregister shutdown send_cmd connect send_post) ],
			  $self => $package_events,
			],
                     	args => [ $alias, @_ ],
  )->ID();
  return $self;
}

# Register and unregister to receive events

sub register {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL, OBJECT, SESSION, SENDER, ARG0 .. $#_];

  die "Not enough arguments" unless @events;

  foreach (@events) {
    $_ = "nntp_" . $_ unless /^_/;
    $self->{events}->{$_}->{$sender} = $sender;
    $self->{sessions}->{$sender}->{'ref'} = $sender;
    unless ($self->{sessions}->{$sender}->{refcnt}++ or $session == $sender) {
      $kernel->refcount_increment($sender->ID(), __PACKAGE__ );
    }
  }
  undef;
}

sub unregister {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL,  OBJECT, SESSION,  SENDER,  ARG0 .. $#_];

  die "Not enough arguments" unless @events;

  foreach (@events) {
    delete $self->{events}->{$_}->{$sender};
    if (--$self->{sessions}->{$sender}->{refcnt} <= 0) {
      delete $self->{sessions}->{$sender};
      unless ($session == $sender) {
        $kernel->refcount_decrement($sender->ID(), __PACKAGE__ );
      }
    }
  }
  undef;
}

# Session starts or stops

sub _start {
  my ($kernel, $session, $self, $alias) = @_[KERNEL, SESSION, OBJECT, ARG0];
  my @options = @_[ARG1 .. $#_];
  $self->{session_id} = $session->ID();
  $session->option( @options ) if @options;
  $kernel->alias_set($alias);
  undef;
}

sub _stop {
  my ($kernel, $self, $quitmsg) = @_[KERNEL, OBJECT, ARG0];

  if ($self->{connected}) {
    $kernel->call( $_[SESSION], 'shutdown', $quitmsg );
  }
  undef;
}

sub connect {
  my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];

  if ($self->{'socket'}) {
        $kernel->call ($session, 'squit');
  }

  $self->{socketfactory} = POE::Wheel::SocketFactory->new(
                                        SocketDomain => AF_INET,
                                        SocketType => SOCK_STREAM,
                                        SocketProtocol => 'tcp',
                                        RemoteAddress => $self->{'remoteserver'},
                                        RemotePort => $self->{'serverport'},
                                        SuccessEvent => '_sock_up',
                                        FailureEvent => '_sock_failed',
                                        ( $self->{localaddr} ? (BindAddress => $self->{localaddr}) : () ),
  );
  undef;
}

# Internal function called when a socket is closed.
sub _sock_down {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  # Destroy the RW wheel for the socket.
  delete $self->{'socket'};
  $self->{connected} = 0;

  foreach (keys %{$self->{sessions}}) {
    $kernel->post( $self->{sessions}->{$_}->{'ref'},
                   'nntp_disconnected', $self->{'remoteserver'} );
  }
  undef;
}

sub _sock_up {
  my ($kernel,$self,$session,$socket) = @_[KERNEL,OBJECT,SESSION,ARG0];

  delete $self->{socketfactory};

  $self->{localaddr} = (unpack_sockaddr_in( getsockname $socket))[1];

  $self->{'socket'} = new POE::Wheel::ReadWrite
  (
        Handle => $socket,
        Driver => POE::Driver::SysRW->new(),
        Filter => POE::Filter::Line->new(),
        InputEvent => '_parseline',
        ErrorEvent => '_sock_down',
   );

  if ($self->{'socket'}) {
        $self->{connected} = 1;
  } else {
        $self->_send_event ( 'nntp_socketerr', "Couldn't create ReadWrite wheel for NNTP socket" );
  }

  foreach (keys %{$self->{sessions}}) {
        $kernel->post( $self->{sessions}->{$_}->{'ref'}, 'nntp_connected', $self->{remoteserver} );
  }
  undef;
}

sub _sock_failed {
  my ($kernel, $self, $op, $errno, $errstr) = @_[KERNEL, OBJECT, ARG0..ARG2];

  $self->_send_event( 'nntp_socketerr', "$op error $errno: $errstr" );
  undef;
}

# Parse each line from received at the socket

sub _parseline {
  my ($kernel, $session, $self, $line) = @_[KERNEL, SESSION, OBJECT, ARG0];

  SWITCH: {
    if ( $line =~ /^\.$/ and defined ( $self->{current_event} ) ) {
      $self->_send_event( 'nntp_' . shift( @{ $self->{current_event} } ), @{ $self->{current_event} }, $self->{current_text} );
      delete ( $self->{current_event} );
      delete ( $self->{current_text} );
      last SWITCH;
    }
    if ( $line =~ /^([0-9]{3}) +(.+)$/ and not defined ( $self->{current_event} ) ) {
      my ($current_event) = [ $1, $2 ];
      if ( $1 =~ /(220|221|222|100|215|231|230)/ ) {
        $self->{current_event} = $current_event;
        $self->{current_text} = [ ];
      } else {
	$self->_send_event( 'nntp_' . $1, $2 );
      }
      last SWITCH;
    }
    if ( defined ( $self->{current_event} ) ) {
      push ( @{ $self->{current_text} }, $line );
      last SWITCH;
    }
  }
  undef;
}

# Sends an event to all interested sessions. This is a separate sub
# because I do it so much, but it's not an actual POE event because it
# doesn't need to be one and I don't need the overhead.

sub _send_event  {
  my ($self, $event, @args) = @_;
  my %sessions;

  foreach (values %{$self->{events}->{'nntp_all'}},
           values %{$self->{events}->{$event}}) {
    $sessions{$_} = $_;
  }
  foreach (values %sessions) {
    $poe_kernel->post( $_, $event, @args );
  }
}

sub shutdown {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  foreach ($kernel->alias_list( $_[SESSION] )) {
    $kernel->alias_remove( $_ );
  }

  foreach (qw(socket sock socketfactory dcc wheelmap)) {
    delete $self->{$_};
  }
  undef;
}

sub send_cmd {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $arg = join ' ', @_[ARG0 .. $#_];

  $self->{socket}->put($arg) if ( defined ( $self->{socket} ) );
  undef;
}

sub accept_input {
  my ($kernel,$self,$state) = @_[KERNEL,OBJECT,STATE];
  my $arg = join ' ', @_[ARG0 .. $#_];

  $self->{socket}->put("$state $arg") if ( defined ( $self->{socket} ) );
  undef;
}

sub send_post {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  unless ( ref $_[ARG0] eq 'ARRAY' ) {
	croak "Argument to send_post must be an array ref";
  }

  foreach ( @{ $_[ARG0] } ) {
    $kernel->yield( 'send_cmd' => $_ );
  }
}

1;
__END__

=head1 NAME

POE::Component::Client::NNTP - A component that provides access to NNTP.

=head1 SYNOPSIS

   use POE::Component::Client::NNTP;

   POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'news.host' } );

   $kernel->post ( 'NNTP-Client' => register => 'all' );

   $kernel->post ( 'NNTP-Client' => article => '51' );

=head1 DESCRIPTION

POE::Component::Client::NNTP is a POE component that provides non-blocking NNTP access to other
components and sessions. NNTP is described in RFC 977 L<http://www.faqs.org/rfcs/rfc977.html>, 
please read it before doing anything else.

In your component or session, you spawn a NNTP client component, assign it an alias, and then 
send it a 'register' event to start receiving responses from the component.

The component takes commands in the form of events and returns the salient responses from the NNTP
server.

=head1 CONSTRUCTOR

=over

=item spawn

Takes two arguments, a kernel alias to christen the new component with and a hashref. Possible values
for the hashref are: NNTPServer, the DNS name or IP address of the NNTP host to connect to; Port, the 
IP port on that host; LocalAddr, an IP address on the client to connect from. If NNTPServer is not specified, 
the default is 'news', unless the environment variable 'NNTPServer' is set. If Port is not specified the default
is 119.

=back

=head1 INPUT

The component accepts the following events:

=over

=item register

Takes N arguments: a list of event names that your session wants to listen for, minus the 'nntp_' prefix, ( this is 
similar to L<POE::Component::IRC|POE::Component::IRC> ). 

Registering for 'all' will cause it to send all NNTP-related events to you; this is the easiest way to handle it.

=item unregister

Takes N arguments: a list of event names which you don't want to receive. If you've previously done a 'register' for a particular event which you no longer care about, this event will tell the NNTP connection to stop sending them to you. (If you haven't, it just ignores you. No big deal).

=item connect

Takes no arguments. Tells the NNTP component to start up a connection to the previously specified NNTP server. You will 
receive a 'nntp_connected' event.

=item shutdown

Takes no arguments. Terminates the component.

=back

The following are implemented NNTP commands, check RFC 977 for the arguments accepted by each. Arguments can be passed as a single scalar or a list of arguments:

=over

=item article

Takes either a valid message-ID or a numeric-ID.

=item body

Takes either a valid message-ID or a numeric-ID.

=item head

Takes either a valid message-ID or a numeric-ID.

=item stat

Takes either a valid message-ID or a numeric-ID.

=item group

Takes the name of a newsgroup to select.

=item help

Takes no arguments.

=item ihave

Takes one argument, a message-ID.

=item last

Takes no arguments.

=item list

Takes no arguments.

=item newgroups

Can take up to four arguments: a date, a time, optionally you can specify GMT and an optional list of distributions.

=item newnews

Can take up to five arguments: a newsgroup, a date, a time, optionally you can specify GMT and an optional list of distributions.

=item next

Takes no arguments.

=item post

Takes no arguments. Once you have sent this expect to receive an 'nntp_340' event. When you receive this send the component a 'send_post' event, see below.

=item send_post

Takes one argument, an array ref containing the message to be posted, one line of the message to each array element.

=item quit

Takes no arguments.

=item slave

Takes no arguments.

=item authinfo

Takes two arguments: first argument is either 'user' or 'pass', second argument is the user or password, respectively. 
Not technically part of RFC 977, but covered in RFC 2980 L<http://www.faqs.org/rfcs/rfc2980.html>.

=item send_cmd

The catch-all event :) Anything sent to this is passed directly to the NNTP server. Use this to implement any non-RFC 
commands that you want, or to completely bypass all the above if you so desire.

=back

=head1 OUTPUT

The following events are generated by the component:

=over

=item nntp_connected

Generated when the component successfully makes a connection to the NNTP server. Please note, that this is only the
underlying network connection. Wait for either an 'nntp_200' or 'nntp_201' before sending any commands to the server.

=item nntp_disconnected

Generated when the link to the NNTP server is dropped for whatever reason.

=item nntp_socketerr

Generated when the component fails to establish a connection to the NNTP server.

=item Numeric responses ( See RFC 977 )

Messages generated by NNTP servers consist of a numeric code and a text response. These will be sent to you as 
events with the numeric code prefixed with 'nntp_'. ARG0 is the text response.

Certain responses return following text, such as the ARTICLE command, which returns the specified article. These responses
are returned in an array ref contained in ARG1.

Eg. 

  $kernel->post( 'NNTP-Client' => article => $article_num );

  sub nntp_220 {
    my ($kernel,$heap,$text,$article) = @_[KERNEL,HEAP,ARG0,ARG1];

    print "$text\n";
    if ( scalar @{ $article } > 0 ) {
	foreach my $line ( @{ $article } ) {
	   print STDOUT $line;
	}
    }
    undef;
  }

=back

=head1 CAVEATS

The group event sets the current working group on the server end. If you want to use group and numeric form of article|head|etc then you will have to spawn multiple instances of the component for each group you want to access concurrently.

=head1 AUTHOR

Chris Williams, E<lt>chris@bingosnet.co.uk<gt>

With code derived from L<POE::Component::IRC|POE::Component::IRC> by Dennis Taylor.

=head1 SEE ALSO

RFC 977  L<http://www.faqs.org/rfcs/rfc977.html>

RFC 2980 L<http://www.faqs.org/rfcs/rfc2980.html>

=cut
