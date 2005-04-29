######################################################################
# Management connection from a client
######################################################################

package Perlbal::ClientManage;
use strict;
use warnings;
use base "Perlbal::Socket";
use fields ('service',
            'buf',
            'is_http',  # bool: is an HTTP request?
            'verbose',  # bool: on/off if we should be verbose for management commands
            );

# ClientManage
sub new {
    my ($class, $service, $sock) = @_;
    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{buf} = "";   # what we've read so far, not forming a complete line
    $self->{verbose} = 1;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# ClientManage
sub event_read {
    my Perlbal::ClientManage $self = shift;

    my $bref;
    unless ($self->{is_http}) {
        $bref = $self->read(1024);
        return $self->close() unless defined $bref;
        $self->{buf} .= $$bref;

        if ($self->{buf} =~ /^(?:HEAD|GET|POST) /) {
            $self->{is_http} = 1;
            $self->{headers_string} .= $$bref;
        }
    }

    if ($self->{is_http}) {
        my $hd = $self->read_request_headers;
        return unless $hd;
        $self->handle_http();
        return;
    }

    while ($self->{buf} =~ s/^(.+?)\r?\n//) {
        my $line = $1;

        # enable user to turn verbose on and off for our connection
        if ($line =~ /^verbose (on|off)$/i) {
            $self->{verbose} = (lc $1 eq 'on' ? 1 : 0);
            $self->write("OK\r\n") if $self->{verbose};
            next;
        }

        if ($line =~ /^quit/) {
            $self->close('user_requested_quit');
            return;
        }

        Perlbal::run_manage_command($line, sub {
            $self->write(join("\r\n", map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_) . "\r\n");
        }, $self->{verbose});
    }
}

# ClientManage
sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

# HTTP management support
sub handle_http {
    my Perlbal::ClientManage $self = shift;

    my $uri = $self->{req_headers}->request_uri;

    my $body;
    my $code = "200 OK";

    my $prebox = sub {
        my $cmd = shift;
        my $alt = shift;
        $body .= "<pre><div style='margin-bottom: 5px; background: #ddd'><b>$cmd</b></div>";
        Perlbal::run_manage_command($cmd, sub {
            my $line = $_[0] || "";
            $alt->(\$line) if $alt;
            $body .= "$line\n"; 
        });
        $body .= "</pre>\n";

    };

    if ($uri eq "/") {
        $body .= "<h1>perlbal management interface</h1><ul>";
        $body .= "<li><a href='/socks'>Sockets</a></li>";
        $body .= "<li><a href='/obj'>Perl Objects in use</a></li>";
        $body .= "<li>Service Details<ul>";
        foreach my $sname (Perlbal->service_names) {
            my Perlbal::Service $svc = Perlbal->service($sname);
            next unless $svc;
            $body .= "<li><a href='/service?$sname'>$sname</a> - $svc->{role} ($svc->{listen})</li>\n";
        }
        $body .= "</ul></li>";
        $body .= "</ul>";
    } elsif ($uri eq "/socks") {
        $prebox->('socks summary');

        $prebox->('socks', sub {
            ${$_[0]} =~ s!service \'(\w+)\'!<a href=\"/service?$1\">$1</a>!;
        });
    } elsif ($uri eq "/obj") {
        $prebox->('obj');
    } elsif ($uri =~ m!^/service\?(\w+)$!) {
        my $service = $1;
        $prebox->("show service $service");
    } else {
        $code = "404 Not found";
        $body .= "<h1>$code</h1>";
    }

    $body .= "<hr style='margin-top: 10px' /><a href='/'>Perlbal management</a>.\n";
    $self->write("HTTP/1.0 $code\r\nContent-type: text/html\r\nContent-Length: " . length($body) . 
                 "\r\n\r\n$body");
    $self->write(sub { $self->close; });
    return;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
