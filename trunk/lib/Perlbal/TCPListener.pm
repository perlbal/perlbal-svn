######################################################################
# TCP listener on a given port
######################################################################

package Perlbal::TCPListener;
use strict;
use base "Perlbal::Socket";
use fields qw(service);
use Socket qw(IPPROTO_TCP);

# TCPListener
sub new {
    my ($class, $hostport, $service) = @_;

    my $sock = IO::Socket::INET->new(
                                     LocalAddr => $hostport,
                                     Proto => IPPROTO_TCP,
                                     Listen => 1024,
                                     ReuseAddr => 1,
                                     Blocking => 0,
                                     );

    return Perlbal::error("Error creating listening socket: $!")
	unless $sock;

    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    # accept as many connections as we can
    while (my ($psock, $peeraddr) = $self->{sock}->accept) {
	my $service_role = $self->{service}->role;

	if (Perlbal::DEBUG >= 1) {
	    my ($pport, $pipr) = Socket::sockaddr_in($peeraddr);
	    my $pip = Socket::inet_ntoa($pipr);
	    print "Got new conn: $psock ($pip:$pport) for $service_role\n";
	}

	IO::Handle::blocking($psock, 0);

	if ($service_role eq "reverse_proxy") {
	    Perlbal::ClientProxy->new($self->{service}, $psock);
	} elsif ($service_role eq "management") {
	    Perlbal::ClientManage->new($self->{service}, $psock);
	}
    }

}

1;
