# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

#use Test::More tests => 5;
#BEGIN { use_ok('POE::Component::Client::NNTP') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);
use POE::Component::Client::NNTP;

# Start the component
# Start our session
# Register with component
# Start a listener and get the port it is bound to
# Ask the component to connect to the 'NNTP Server'
# Quit
# Shutdown component

$|=1;
print "1..5\n";
print "ok 1\n";

my (@tests) = ( "not ok 2", "not ok 3", "not ok 4", "not ok 5" );

POE::Session->create
  ( inline_states =>
      { _start => \&server_start,
	_stop  => \&server_stop,
        server_accepted => \&server_accepted,
        server_error    => \&server_error,
        client_input    => \&client_input,
        client_error    => \&client_error,
	client_flush    => \&client_flushed,
	close_all	=> \&server_shutdown,
	nntp_200	=> \&nntp_200,
	nntp_215	=> \&nntp_215,
	#nntp_205	=> \&server_shutdown,
	nntp_disconnected	=> \&server_shutdown,
      },
  );

POE::Kernel->run();
exit 0;

sub server_start {
    my ($our_port);

    $_[HEAP]->{server} = POE::Wheel::SocketFactory->new
      ( 
	BindAddress => '127.0.0.1',
        SuccessEvent => "server_accepted",
        FailureEvent => "server_error",
      );

    ($our_port, undef) = unpack_sockaddr_in( $_[HEAP]->{server}->getsockname );

    POE::Component::Client::NNTP->spawn ( 'NNTP-Client' => { NNTPServer => 'localhost', Port => $our_port } );

    $_[KERNEL]->post ( 'NNTP-Client' => 'register' => 'all' );

    $_[KERNEL]->post ( 'NNTP-Client' => 'connect' );

    $_[KERNEL]->delay ( 'close_all' => 60 );
}

sub server_stop {

  foreach ( @tests ) {
	print "$_\n";
  }

}

sub server_accepted {
    my $client_socket = $_[ARG0];

    my $wheel = POE::Wheel::ReadWrite->new
      ( Handle => $client_socket,
        InputEvent => "client_input",
        ErrorEvent => "client_error",
	FlushedEvent => "client_flush",
	Filter => POE::Filter::Line->new( Literal => "\x0D\x0A" ),
      );
    $_[HEAP]->{client}->{ $wheel->ID() } = $wheel;

    $wheel->put("200 server ready - posting allowed");
}

sub server_error {
    delete $_[HEAP]->{server};
}

sub server_shutdown {

    $_[KERNEL]->delay ( 'close_all' => undef );
    delete $_[HEAP]->{server};
    
    $_[KERNEL]->post ( 'NNTP-Client' => 'unregister' => 'all' );
    $_[KERNEL]->post ( 'NNTP-Client' => 'shutdown' );
}

sub client_input {
    my ( $heap, $input, $wheel_id ) = @_[ HEAP, ARG0, ARG1 ];
     
    # Quick and dirty parsing as we know it is our component connecting
    SWITCH: {
      if ( $input =~ /^LIST/i ) {
	$heap->{client}->{$wheel_id}->put("215 list of newsgroups follows");
	$heap->{client}->{$wheel_id}->put("perl.poe 0 1 y");
	$heap->{client}->{$wheel_id}->put(".");
	$tests[0] = "ok 2";
	last SWITCH;
      }
      if ( $input =~ /^QUIT/i ) {
	$heap->{client}->{$wheel_id}->put("205 closing connection - goodbye!");
	$heap->{quiting}->{$wheel_id} = 1;
	$tests[2] = "ok 4";
	last SWITCH;
      }
    }
}

sub client_error {
    my ( $heap, $wheel_id ) = @_[ HEAP, ARG3 ];
    delete $heap->{client}->{$wheel_id};
}

sub client_flushed {
    my ( $heap, $wheel_id ) = @_[ HEAP, ARG0 ];

    if ( $heap->{quiting}->{$wheel_id} ) {
	delete $heap->{quiting}->{$wheel_id};
    	delete $heap->{client}->{$wheel_id};
    }
}

sub nntp_200 {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  $kernel->post ( 'NNTP-Client' => 'list' );
  $tests[1] = "ok 3";
}

sub nntp_215 {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  $kernel->post ( 'NNTP-Client' => 'quit' );
  $tests[3] = "ok 5";
}
