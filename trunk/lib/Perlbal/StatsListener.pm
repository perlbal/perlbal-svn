######################################################################
# UDP listener for Apache free/busy stats
######################################################################

package Perlbal::StatsListener;
use strict;
use warnings;
use base "Perlbal::Socket";
use fields ('service',  # Perlbal::Service,
            'pos',           # index in ring.  this index has an empty value in it
                             # entries before it are good
            'message_ring',  # arrayref of UDP messages, unparsed
            'from_ring',     # arrayref of from addresses
            'hostinfo',      # hashref of ip (4 bytes) -> [ $free, $active ] (or undef)
            'total_free',    # int scalar: free listeners
            'need_parse',    # hashref:  ip -> pos
            'use_count',     # hashref:  ip -> times_used (ip can also be '' for empty case)
            'use_total',     # int scalar: count of uses we've had total
            'dead',          # int; if 1 then we're dead (don't give out any more info)
            );

use constant RING_SIZE => 30;

sub new {
    my $class = shift;

    my ($hostport, $service) = @_;

    my $sock = IO::Socket::INET->new(
                                     LocalAddr => $hostport,
                                     Proto => 'udp',
                                     ReuseAddr => 1,
                                     Blocking => 0,
                                     );

    return Perlbal::error("Error creating listening socket: $!")
        unless $sock;
    $sock->sockopt(Socket::SO_BROADCAST, 1);
    $sock->blocking(0);

    my $self = fields::new($class);
    $self->SUPER::new($sock);       # init base fields

    $self->{dead} = 0;
    $self->{service} = $service;
    $self->reset_state;

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

sub reset_state {
    my Perlbal::StatsListener $self = shift;
    $self->{pos} = 0;
    $self->{message_ring} = [];
    $self->{from_ring} = [];
    $self->{total_free} = 0;
    $self->{need_parse} = {};
    $self->{hostinfo} = {};
    $self->{use_count} = {};
}

sub event_read {
    my Perlbal::StatsListener $self = shift;
    my $sock = $self->{sock};

    my ($port, $iaddr);

    while (my $from = $sock->recv($self->{message_ring}[$self->{pos}], 1024)) {
        # set the from just to the 4 byte IP address
        ($port, $from) = Socket::sockaddr_in($from);

        $self->{from_ring}[$self->{pos}] = $from;

        # new message from host $from, so clear its cached data
        if (exists $self->{hostinfo}{$from}) {
            if (my $hi = $self->{hostinfo}{$from}) {
                $self->{total_free} -= $hi->[0];
            }
            $self->{hostinfo}{$from} = undef;
            $self->{need_parse}{$from} = $self->{pos};
        }

        $self->{pos} = 0 if ++$self->{pos} == RING_SIZE;
    }
}

sub get_endpoint {
    my Perlbal::StatsListener $self = shift;
    return () if $self->{dead};

    # catch up on our parsing
    while (my ($from, $pos) = each %{$self->{need_parse}}) {
        # make sure this position still corresponds to that host
        next unless $from eq $self->{from_ring}[$pos];
        next unless $self->{message_ring}[$pos] =~
            m!^bcast_ver=1\nfree=(\d+)\nactive=(\d+)\n$!;
        $self->{hostinfo}{$from} = [ $1, $2 ];
        $self->{total_free} += $1;
    }
    $self->{need_parse} = {};

    # mode 1 (normal) is on advertised free, mode 2 is when nothing's
    # free, so we make a weighted random guess on past performance
    my $mode = 1;
    my $upper_bound = $self->{total_free};

    unless ($upper_bound) {
        $mode = 2;
        $upper_bound = $self->{use_total};
    }

    # pick what position we'll return
    my $winner = rand($upper_bound);

    # find the winner
    my $count = 0;

    # two passes, since the inner while is doing 'each'
    # which we intrerupt when we find the winner.  so later,
    # coming back into this, the each doesn't necessarily
    # start in the beginning so we have to let it loop around
    foreach my $pass (1..2) {
        while (my ($from, $hi) = each %{$self->{hostinfo}}) {
            if ($mode == 1) {
                # must have data
                next unless $hi;
                $count += $hi->[0];
            } elsif ($mode == 2) {
                # increment count by uses this one's received for weighting
                $count += $self->{use_count}{$from};
            }

            if ($count >= $winner) {
                my $ip = Socket::inet_ntoa($from);
                if ($mode == 1) {
                    $hi->[0]--;
                    $self->{total_free}--;
                    $self->{use_total}++;
                    $self->{use_count}{$from}++;
                }
                return ($ip, 80);
            }
        }
    }

    # guess we couldn't find anything
    $self->{use_count}{'winner_too_high'}++;
    return ();
}

sub set_hosts {
    my Perlbal::StatsListener $self = shift;
    my @hosts = @_;

    # clear the known hosts
    $self->reset_state;

    # make each provided host known, but undef (meaning
    # its ring data hasn't been parsed)
    foreach my $dq (@hosts) {
        # converted dotted quad to packed format
        my $pd = Socket::inet_aton($dq);
        $self->{hostinfo}{$pd} = undef;
    }
}

sub debug_dump {
    my Perlbal::StatsListener $self = shift;
    my $out = shift;
    no warnings;

    $out->("Stats listener dump:");
    $out->("  pos = $self->{pos}");
    $out->("  message_ring = ");

    for (my $i=0; $i<RING_SIZE; $i++) {
        my $ip = eval { Socket::inet_ntoa($self->{'from_ring'}[$i]); };
        $out->("  \#$i: [$ip] " . $self->{'message_ring'}[$i]);
    }

    my $count_free = 0;
    foreach my $host (sort keys %{$self->{hostinfo}}) {
        my $ip = eval { Socket::inet_ntoa($host); };
        my $hi = $self->{hostinfo}{$host};
        my $need_parse = $self->{need_parse}{$host};
        my $uses = $self->{use_count}{$host};
        if ($hi) {
            $count_free += $hi->[0];
            $out->(" host $ip = $uses: [ $hi->[0] free, $hi->[1] act ] needparse=$need_parse");
        } else {
            $out->(" host $ip = $uses: needparse=$need_parse");
        }
    }

    $out->(" total free: $self->{total_free} (calculated: $count_free)");
    $out->("Uses with no total: $self->{use_count}{'no_free'}, winner too high: $self->{use_count}{'winner_too_high'}");

}

sub event_err { }
sub event_hup { }

sub die_gracefully {
    # okay, let's actually die now
    my $self = shift;
    $self->{dead} = 1;
    $self->close;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
