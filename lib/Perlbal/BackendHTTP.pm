######################################################################
# HTTP connection to backend node
# possible states: connecting, bored, sending_req, wait_res, xfer_res
######################################################################

package Perlbal::BackendHTTP;
use strict;
use base "Perlbal::Socket";
use fields ('client',  # Perlbal::ClientProxy connection, or undef
            'service', # Perlbal::Service
            'ip',      # IP scalar
            'port',    # port scalar
            'ipport',  # "$ip:$port"

            'has_attention', # has been accepted by a webserver and
                             # we know for sure we're not just talking
                             # to the TCP stack

            'waiting_options', # if true, we're waiting for an OPTIONS *
                               # response to determine when we have attention

            'disconnect_at', # time this connection will be disconnected,
                             # if it's kept-alive and backend told us.
                             # otherwise undef for unknown.

            # The following only apply when the backend server sends
            # a content-length header
            'content_length',  # length of document being transferred
            'content_length_remain',    # bytes remaining to be read

            'use_count',  # number of requests this backend's been used for

            );
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);

use Perlbal::ClientProxy;

# if this is made too big, (say, 128k), then perl does malloc instead
# of using its slab cache.
use constant BACKEND_READ_SIZE => 61449;  # 60k, to fit in a 64k slab

# keys set here when an endpoint is found to not support persistent
# connections and/or the OPTIONS method
our (%NoVerify); # { "ip:port" => next-verify-time }

# constructor for a backend connection takes a service (pool) that it's
# for, and uses that service to get its backend IP/port, as well as the
# client that will be using this backend connection.
sub new {
    my ($class, $svc, $ip, $port) = @_;

    my $sock;
    socket $sock, PF_INET, SOCK_STREAM, IPPROTO_TCP;

    unless ($sock && defined fileno($sock)) {
        print STDERR "Error creating socket: $!\n";
        return undef;
    }

    IO::Handle::blocking($sock, 0);
    connect $sock, Socket::sockaddr_in($port, Socket::inet_aton($ip));

    my $self = fields::new($class);
    $self->SUPER::new($sock);

    Perlbal::objctor();

    $self->{ip}      = $ip;       # backend IP
    $self->{port}    = $port;     # backend port
    $self->{ipport}  = "$ip:$port";  # often used as key
    $self->{service} = $svc;      # the service we're serving for
    $self->state("connecting");

    # for header reading:
    $self->{req_headers} = undef;
    $self->{res_headers} = undef;  # defined w/ headers object once all headers in
    $self->{headers_string} = "";  # blank to start
    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    $self->{client}   = undef;     # Perlbal::ClientProxy object, initially empty 
                                   #    until we ask our service for one

    $self->{has_attention} = 0;
    $self->{use_count}     = 0;

    bless $self, ref $class || $class;
    $self->watch_write(1);
    return $self;
}

sub close {
    my Perlbal::BackendHTTP $self = shift;
    my $reason = shift;
    $self->state("closed");

    # tell our client that we're gone
    if (my $client = $self->{client}) {
        $client->backend(undef);
    }

    $self->SUPER::close($reason);
}

# called by service when it's got a client for us, or by ourselves
# when we asked for a client.
# returns true if client assignment was accepted.
sub assign_client {
    my Perlbal::BackendHTTP $self = shift;
    my Perlbal::ClientProxy $client = shift;
    return 0 if $self->{client};

    # set our client, and the client's backend to us
    $self->{service}->mark_node_used($self->{ipport});
    $self->{client} = $client;
    $self->state("sending_req");
    $self->{client}->backend($self);

    my Perlbal::HTTPHeaders $hds = $client->{req_headers}->clone;
    $self->{req_headers} = $hds;

    # Use HTTP/1.0 to backend (FIXME: use 1.1 and support chunking)
    $hds->set_version("1.0");

    my $persist = $self->{service}{persist_backend};

    $hds->header("Connection", $persist ? "keep-alive" : "close");

    # FIXME: make this conditional
    $hds->header("X-Proxy-Capabilities", "reproxy-file");
    $hds->header("X-Forwarded-For", $client->peer_ip_string);
    $hds->header("X-Host", undef);
    $hds->header("X-Forwarded-Host", undef);

    $self->tcp_cork(1);
    $client->state('backend_req_sent');

    $self->{content_length} = undef;
    $self->{content_length_remain} = undef;

    # run hooks
    return 1 if $self->{service}->run_hook('backend_client_assigned', $self);

    $self->write($hds->to_string_ref);
    $self->write(sub {
        $self->tcp_cork(0);
        if (my $client = $self->{client}) {
            # start waiting on a reply
            $self->watch_read(1);
            $self->state("wait_res");
            $client->state('wait_res');
            # make the client push its overflow reads (request body)
            # to the backend
            $client->drain_read_buf_to($self);
            # and start watching for more reads
            $client->watch_read(1);
        }
    });

    return 1;
}

# Backend
sub event_write {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is writeable!\n" if Perlbal::DEBUG >= 2;

    delete $NoVerify{$self->{ipport}} if
        defined $NoVerify{$self->{ipport}} &&
        $NoVerify{$self->{ipport}} < time();

    if (! $self->{client} && $self->{state} eq "connecting") {
        # not interested in writes again until something else is
        $self->watch_write(0);

        if ($self->{service}->{verify_backend} && !$self->{has_attention} &&
            !defined $NoVerify{$self->{ipport}}) {

            # the backend should be able to answer this incredibly quickly.
            $self->write("OPTIONS * HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
            $self->watch_read(1);
            $self->{waiting_options} = 1;
            $self->{content_length_remain} = undef;
            $self->state("verifying_backend");
        } else {
            # register our boredom (readiness for a client/request)
            $self->state("bored");
            $self->{service}->register_boredom($self);
        }
        return;
    }

    my $done = $self->write(undef);
    $self->watch_write(0) if $done;
}

sub verify_failure {
    my Perlbal::BackendHTTP $self = shift;
    $NoVerify{$self->{ipport}} = time() + 60;
    $self->{service}->note_bad_backend_connect($self->{ip}, $self->{port});
    $self->close('no_keep_alive');
    return;
}

# Backend
sub event_read {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is readable!\n" if Perlbal::DEBUG >= 2;

    if ($self->{waiting_options}) {
        if ($self->{content_length_remain}) {
            # the HTTP/1.1 spec says OPTIONS responses can have content-lengths,
            # but the meaning of the response is reserved for a future spec.
            # this just gobbles it up for.
            my $bref = $self->read(BACKEND_READ_SIZE);
            return $self->verify_failure unless defined $bref;
            $self->{content_length_remain} -= length($$bref);
        } elsif (my $hd = $self->read_response_headers) {
            # see if we have keep alive support
            return $self->verify_failure unless $hd->keep_alive("n/a");
            $self->{content_length_remain} = $hd->header("Content-Length");
        }

        # if we've got the option response and read any response data
        # if present:
        if ($self->{res_headers} && ! $self->{content_length_remain}) {
            # other setup to mark being done with options checking
            $self->{waiting_options} = 0;
            $self->{has_attention} = 1;
            $self->watch_read(0);
            $self->state("bored");
            $self->{req_headers} = undef;
            $self->{res_headers} = undef;
            $self->{headers_string} = '';
            $self->{content_length_remain} = undef;
            $self->{service}->register_boredom($self);
        }
        return;
    }

    my Perlbal::ClientProxy $client = $self->{client};

    # with persistent connections, sometimes we have a backend and
    # no client, and backend becomes readable, either to signal
    # to use the end of the stream, or because a bad request error,
    # which I can't totally understand.  in any case, we have
    # no client so all we can do is close this backend.
    return $self->close unless $client;

    unless ($self->{res_headers}) {
        if (my $hd = $self->read_response_headers) {
            # call hook
            return if $self->{service}->run_hook('backend_response_received', $self);

            # standard handling
            $self->state("xfer_res");
            $client->state("xfer_res");
            $self->{has_attention} = 1;

            # RFC 2616, Sec 4.4: Messages MUST NOT include both a
            # Content-Length header field and a non-identity
            # transfer-coding. If the message does include a non-
            # identity transfer-coding, the Content-Length MUST be
            # ignored.
            my $te = $hd->header("Transfer-Encoding");
            if ($te && $te !~ /\bidentity\b/i) {
                $hd->header("Content-Length", undef);
            }

            my Perlbal::HTTPHeaders $rqhd = $self->{req_headers};

            if ($rqhd->{method} eq "HEAD") {
                # content-lengths coming back from HEAD requests aren't
                # real.  there never is a message body.  just pass it
                # back to the client and don't actually read what's not there
                $self->{content_length} = 0;
                $self->{content_length_remain} = 0;
            } elsif (defined($self->{content_length} = $hd->header("Content-Length"))) {
                # the normal case for a GET/POST, etc.  real data coming back
                # also, an OPTIONS requests generally has a defined but 0 content-length
                $self->{content_length_remain} = $self->{content_length};
            } elsif ($hd->{code} == 304 || $hd->{code} == 204 || ($hd >= 100 && $hd <= 199)) {
                # cases that will have no content-length
                $self->{content_length} = 0;
                $self->{content_length_remain} = 0;
            }

            if (my $rep = $hd->header('X-REPROXY-FILE')) {
                # make the client begin the async IO while we move on
                $client->start_reproxy_file($rep, $hd);
                $self->next_request;
                return;
            } else {
                my $thd = $client->{res_headers} = $hd->clone;

                # for now, we don't support keep-alive and we force HTTP 1.0
                $thd->set_version('1.0');
                $thd->header('Connection', 'close');
                $thd->header('Keep-Alive', undef);
                $client->write($thd->to_string_ref);

                # if we over-read anything from backend (most likely)
                # then decrement it from our count of bytes we need to read
                if (defined $self->{content_length}) {
                    $self->{content_length_remain} -= $self->{read_ahead};
                }
                $self->drain_read_buf_to($client);

                if (defined $self->{content_length} && ! $self->{content_length_remain}) {
                    # order important:  next_request detaches us from client, so
                    # $client->close can't kill us
                    $self->next_request;
                    $client->write(sub { $client->close; });
                }
            }
        }
        return;
    }

    # if our client's 250k behind, stop buffering
    # FIXME: constant
    if ($client->{write_buf_size} > 256_000) {
        $self->watch_read(0);
        return;
    }

    my $bref = $self->read(BACKEND_READ_SIZE);

    if (defined $bref) {
        $client->write($bref);

        # HTTP/1.0 keep-alive support to backend.  we just count bytes
        # until we hit the end, then we know we can send another
        # request on this connection
        if ($self->{content_length}) {
            $self->{content_length_remain} -= length($$bref);
            if (! $self->{content_length_remain}) {
                # order important:  next_request detaches us from client, so
                # $client->close can't kill us
                $self->next_request;
                $client->write(sub { $client->close; });
            }
        }
        return;
    } else {
        # backend closed
        print "Backend $self is done; closing...\n" if Perlbal::DEBUG >= 1;

        $client->backend(undef);    # disconnect ourselves from it
        $self->{client} = undef;    # .. and it from us
        $self->close;               # close ourselves

        $client->write(sub { $client->close; });
        return;
    }
}

sub next_request {
    my Perlbal::BackendHTTP $self = shift;

    my $hd = $self->{res_headers};  # response headers
    unless ($self->{service}{persist_backend} &&
            $hd->header("Connection") =~ /\bkeep-alive\b/i) {
        return $self->close;
    }

    my Perlbal::Service $svc = $self->{service};

    # keep track of how many times we've been used, and don't
    # keep using this connection more times than the service
    # is configured for.
    if (++$self->{use_count} > $svc->{max_backend_uses} &&
        $svc->{max_backend_uses}) {
        return $self->close;
    }

    # if backend told us, keep track of when the backend
    # says it's going to boot us, so we don't use it within
    # a few seconds of that time
    if ($hd->header("Keep-Alive") =~ /\btimeout=(\d+)/i) {
        $self->{disconnect_at} = time() + $1;
    } else {
        $self->{disconnect_at} = undef;
    }

    my Perlbal::ClientProxy $client = $self->{client};
    $client->backend(undef) if $client;
    $self->{client} = undef;

    $self->state("bored");
    $self->watch_write(0);

    $self->{req_headers} = undef;
    $self->{res_headers} = undef;
    $self->{headers_string} = "";
    $self->{req_headers} = undef;

    $svc->register_boredom($self);
    return;
}

# Backend: bad connection to backend
sub event_err {
    my Perlbal::BackendHTTP $self = shift;

    # FIXME: we get this after backend is done reading and we disconnect,
    # hence the misc checks below for $self->{client}.

    print "BACKEND event_err\n" if
        Perlbal::DEBUG >= 2;

    if ($self->{client}) {
        # request already sent to backend, then an error occurred.
        # we don't want to duplicate POST requests, so for now
        # just fail
        # TODO: if just a GET request, retry?
        $self->{client}->close;
        $self->close;
        return;
    }

    if ($self->{state} eq "connecting" ||
        $self->{state} eq "verifying_backend") {
        # then tell the service manager that this connection
        # failed, so it can spawn a new one and note the dead host
        $self->{service}->note_bad_backend_connect($self->{ip}, $self->{port});
    }

    # close ourselves first
    $self->close("error");
}

# Backend
sub event_hup {
    my Perlbal::BackendHTTP $self = shift;
    print "HANGUP for $self\n" if Perlbal::DEBUG;
    $self->close("after_hup");
}

sub as_string {
    my Perlbal::BackendHTTP $self = shift;

    my $name = getsockname($self->{sock});
    my $lport = $name ? (Socket::sockaddr_in($name))[0] : undef;
    my $ret = $self->SUPER::as_string . ": localport=$lport";
    if (my Perlbal::ClientProxy $cp = $self->{client}) {
        $ret .= "; client=$cp->{fd}";
    }
    $ret .= "; uses=$self->{use_count}; $self->{state}";
    if ($self->{service}->{verify_backend}) {
        $ret .= "; has_attention=";
        $ret .= $self->{has_attention} ? 'yes' : 'no';
    }

    return $ret;
}

sub die_gracefully {
    # see if we need to die
    my Perlbal::BackendHTTP $self = shift;
    $self->close if $self->state eq 'bored';
}

sub DESTROY {
    Perlbal::objdtor();
    $_[0]->SUPER::DESTROY;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End: