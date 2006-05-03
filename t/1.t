use Test::More tests => 6;
BEGIN { use_ok('POE::Component::Client::NNTP') };

use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);

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

    my $nntp = POE::Component::Client::NNTP->spawn ( 'NNTP-Client' => { NNTPServer => 'localhost', Port => $our_port } );

    isa_ok( $nntp, 'POE::Component::Client::NNTP' );

    $_[KERNEL]->post ( 'NNTP-Client' => 'register' => 'all' );

    $_[KERNEL]->post ( 'NNTP-Client' => 'connect' );

    $_[KERNEL]->delay ( 'close_all' => 60 );
    undef;
}

sub server_stop {
   undef;
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
    undef;
}

sub server_error {
    delete $_[HEAP]->{server};
}

sub server_shutdown {
    $_[KERNEL]->delay ( 'close_all' => undef );
    delete $_[HEAP]->{server};
    $_[KERNEL]->post ( 'NNTP-Client' => 'shutdown' );
    undef;
}

sub client_input {
    my ( $heap, $input, $wheel_id ) = @_[ HEAP, ARG0, ARG1 ];
     
    # Quick and dirty parsing as we know it is our component connecting
    SWITCH: {
      if ( $input =~ /^LIST/i ) {
	$heap->{client}->{$wheel_id}->put("215 list of newsgroups follows");
	$heap->{client}->{$wheel_id}->put("perl.poe 0 1 y");
	$heap->{client}->{$wheel_id}->put(".");
	pass("LIST cmd");
	last SWITCH;
      }
      if ( $input =~ /^QUIT/i ) {
	$heap->{client}->{$wheel_id}->put("205 closing connection - goodbye!");
	$heap->{quiting}->{$wheel_id} = 1;
	pass("QUIT cmd");
	last SWITCH;
      }
    }
    undef;
}

sub client_error {
    my ( $heap, $wheel_id ) = @_[ HEAP, ARG3 ];
    delete $heap->{client}->{$wheel_id};
    undef;
}

sub client_flushed {
    my ( $heap, $wheel_id ) = @_[ HEAP, ARG0 ];

    if ( $heap->{quiting}->{$wheel_id} ) {
	delete $heap->{quiting}->{$wheel_id};
    	delete $heap->{client}->{$wheel_id};
    }
    undef;
}

sub nntp_200 {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $kernel->post ( 'NNTP-Client' => 'list' );
  pass("Connected");
  undef;
}

sub nntp_215 {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $kernel->post ( 'NNTP-Client' => 'quit' );
  pass("Got a list back");
  undef;
}
