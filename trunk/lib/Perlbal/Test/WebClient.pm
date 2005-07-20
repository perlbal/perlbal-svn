#!/usr/bin/perl

package Perlbal::Test::WebClient;

use strict;
use IO::Socket::INET;
use HTTP::Response;
use Socket qw(MSG_NOSIGNAL IPPROTO_TCP TCP_NODELAY SOL_SOCKET);

require Exporter;
use vars qw(@ISA @EXPORT $FLAG_NOSIGNAL);
@ISA = qw(Exporter);
@EXPORT = qw(new);

eval { $FLAG_NOSIGNAL = MSG_NOSIGNAL; };

# create a blank object
sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

# get/set what server we should be testing; "ip:port" generally
sub server {
    my $self = shift;
    if (@_) {
        return $self->{server} = shift;
    } else {
        return $self->{server};
    }
}

# set which HTTP version to emulate; specify '1.0' or '1.1'
sub http_version {
    my $self = shift;
    if (@_) {
        return $self->{http_version} = shift;
    } else {
        return $self->{http_version};
    }
}

# set on or off to enable or disable persistent connection
sub keepalive {
    my $self = shift;
    if (@_) {
        $self->{keepalive} = shift() ? 1 : 0;
    }
    return $self->{keepalive};
}

# construct and send a request
sub request {
    my $self = shift;
    return undef unless $self->{server};

    my $opts = ref $_[0] eq "HASH" ? shift : {};

    my $cmds = join(',', map { eurl($_) } @_);
    return undef unless $cmds;

    # keep-alive header if 1.0, also means add content-length header
    my $headers = '';
    if ($self->{keepalive}) {
        $headers .= "Connection: keep-alive\r\n";
    } else {
        $headers .= "Connection: close\r\n";
    }

    my $send = "GET /$cmds HTTP/$self->{http_version}\r\n$headers\r\n";
    my $len = length $send;

    # send setup
    my $rv;
    my $sock = delete $self->{_sock};
    local $SIG{'PIPE'} = "IGNORE" unless $FLAG_NOSIGNAL;

    ### send it cached
    if ($sock) {
        $rv = send($sock, $send, $FLAG_NOSIGNAL);
        if ($! || ! defined $rv) {
            undef $self->{_sock};
        } elsif ($rv != $len) {
            return undef;
        }
    }

    # failing that, send it through a new socket
    unless ($rv) {
        $self->{_reqdone} = 0;

        $sock = IO::Socket::INET->new(
                PeerAddr => $self->{server},
                Timeout => 3,
            ) or return undef;
        setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;

        $rv = send($sock, $send, $FLAG_NOSIGNAL);
        if ($! || $rv != $len) {
            return undef;
        }
    }

    my $parse_it = sub {
        my $res = '';
        my $firstline = undef;
        while (<$sock>) {
            $res .= $_;
            $firstline = $_ unless defined $firstline;
            last if ! $_ || /^\r?\n/;
        }

        unless ($firstline) {
            print STDERR "Didn't get a firstline in HTTP response.\n";
            return undef;
        }

        my $resp = HTTP::Response->parse($res);
        return undef unless $resp;

        my $cl = $resp->header('Content-Length');
        if (defined $cl && $cl > 0) {
            my $content = '';
            while (($cl -= read($sock, $content, $cl)) > 0) {
                # don't do anything, the loop is it
            }
            $resp->content($content);
        }

        my $conhdr = $resp->header("Connection") || "";
        if (($firstline =~ m!\bHTTP/1\.1\b! && $conhdr !~ m!\bclose\b!i) ||
            ($firstline =~ m!\bHTTP/1\.0\b! && $conhdr =~ m!\bkeep-alive\b!i)) {
            $self->{_sock} = $sock;
            $self->{_reqdone}++;
        } else {
            $self->{_reqdone} = 0;
        }

        return $resp;
    };

    if ($opts->{return_reader}) {
        return $parse_it;
    } else {
        return $parse_it->();
    }
}

sub reqdone {
    my $self = shift;
    return $self->{_reqdone};
}

# general purpose URL escaping function
sub eurl {
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

1;
