######################################################################
# HTTP Connection from a reverse proxy client
######################################################################

package Perlbal::ClientHTTP;
use strict;
use base "Perlbal::Socket";
use HTTP::Date ();
use fields ('service',             # Perlbal::Service object

	    # reproxy support
	    'reproxy_file',        # filename the backend told us to start opening
	    'reproxy_file_size',   # size of file, once we stat() it
	    'reproxy_fd',          # integer fd of reproxying file, once we open() it
	    'reproxy_file_offset', # how much we've sent from the file.
	    );

use constant READ_SIZE         => 4086;    # 4k, arbitrary
use constant READ_AHEAD_SIZE   => 8192;    # 8k, arbitrary
use Errno qw( EPIPE );
use POSIX ();

# ghetto hard-coding.  should let siteadmin define or something.
# maybe console/config command:  AddMime <ext> <mime-type>  (apache-style?)
our $MimeType = {qw(
		    css  text/css
		    doc  application/msword
		    gif  image/gif
		    htm  text/html
		    html text/html
		    jpg  image/jpeg
		    js   application/x-javascript
		    mp3  audio/mpeg
		    mpg  video/mpeg
		    png  image/png
		    tif   image/tiff
		    tiff  image/tiff
		    torrent  application/x-bittorrent
		    txt   text/plain
		    zip   application/zip
)};

# ClientHTTP
sub new {
    my ($class, $service, $sock) = @_;

    my $self = fields::new($class);
    $self->SUPER::new($sock);       # init base fields

    $self->{service} = $service;
    $self->{headers_string} = '';

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}


sub headers {
    my Perlbal::ClientHTTP $self = shift;
    return $self->{headers} unless @_;
    return $self->{headers} = shift;
}

sub close {
    my Perlbal::ClientHTTP $self = shift;
    my $reason = shift;

    # close the file we were reproxying, if any
    POSIX::close($self->{reproxy_fd}) if $self->{reproxy_fd};

    $self->SUPER::close($reason);
}

sub reproxy_fd {
    my Perlbal::ClientHTTP $self = shift;
    return $self->{reproxy_fd} unless @_;

    my ($fd, $size) = @_;
    $self->{reproxy_file_offset} = 0;
    $self->{reproxy_file_size} = $size;
    return $self->{reproxy_fd} = $fd;
}

sub event_write { 
    my Perlbal::ClientHTTP $self = shift;

    if ($self->{reproxy_fd}) {
	my $to_send = $self->{reproxy_file_size} - $self->{reproxy_file_offset};
	$self->tcp_cork(1) if $self->{reproxy_file_offset} == 0;
	my $sent = IO::SendFile::sendfile($self->{fd}, 
					  $self->{reproxy_fd},
					  0, # NULL offset means kernel moves filepos (apparently)
					  $to_send);
	print "REPROXY Sent: $sent\n" if Perlbal::DEBUG >= 2;
	if ($sent < 0) { 
	    if ($! == EPIPE) {
		$self->close("epipe");
		return;
	    }
	    print STDERR "Error w/ sendfile: $!\n"; 
	    $self->close;
	    return;
	}
	$self->{reproxy_file_offset} += $sent;

	if ($sent >= $to_send) {
	    # close the sendfile fd
	    my $rv = POSIX::close($self->{reproxy_fd});

	    $self->{reproxy_fd} = undef;
	    $self->close("sendfile_done");
	}
	return;
    }

    if ($self->write(undef)) {
	print "All writing done to $self\n" if Perlbal::DEBUG >= 2;

	# we've written all data in the queue, so stop waiting for write
	# notifications:
	$self->watch_write(0);
    }

}

sub _simple_response {
    my Perlbal::ClientHTTP $self = shift;
    my ($code, $msg) = @_;  # or bodyref
    
    my $res = Perlbal::HTTPHeaders->new_response($code);
    $res->header("Content-Type", "text/html");

    my $en = $res->http_code_english;
    my $body = "<h1>$code" . ($en ? " - $en" : "") . "</h1>\n";
    $body .= $msg;

    $self->tcp_cork(1);  # cork writes to self
    $self->write($res->to_string_ref);
    $self->write(\$body);
    $self->write(sub { $self->close; });
    return 1;
}

sub event_read {
    my Perlbal::ClientHTTP $self = shift;

    if ($self->{headers}) {
	$self->watch_read(0);
	return;
    }


    my $hd = $self->read_request_headers;
    return unless $hd;

    my $rm = $hd->request_method;
    unless ($rm eq "HEAD" || $rm eq "GET") {
	return $self->_simple_response(403, "Unimplemented method");
    }

    my $uri = _durl($hd->request_uri);

    # don't allow directory traversal
    if ($uri =~ /\.\./ || $uri !~ m!^/!) {
	return $self->_simple_response(403, "Bogus URL");
    }

    my Perlbal::Service $svc = $self->{service};
    my $file = $svc->{docroot} . $uri;

    Linux::AIO::aio_stat($file, sub {
	# client's gone anyway
	return if $self->{closed};
	return $self->_simple_response(404) unless -e _;

	my $res = Perlbal::HTTPHeaders->new_response(200);
	$res->header("Connection", "close");
	$res->header("Date", HTTP::Date::time2str());
	$res->header("Server", "Perlbal");
	$res->header("Last-Modified", HTTP::Date::time2str((stat(_))[9]));

	if (-f _) {
	    my $size = -s _;
	    my ($ext) = ($file =~ /\.(\w+)$/);
	    $res->header("Content-Type",
			 (defined $ext && exists $MimeType->{$ext}) ? $MimeType->{$ext} : "text/plain");
	    $res->header("Content-Length", $size);

	    if ($rm eq "HEAD") {
		# we can return already, since we know the size
		$self->tcp_cork(1);
                $self->write($res->to_string_ref);
		$self->write(sub { $self->close; });		
		return;
	    }

	    Linux::AIO::aio_open($file, 0, 0, sub {
		my $rp_fd = shift;

		# if client's gone, just close filehandle and abort
		if ($self->{closed}) {
		    POSIX::close($rp_fd) if $rp_fd >= 0;
		    return;
		}

		# handle errors
		if ($rp_fd < 0) {
		    # couldn't open the file we had already successfully stat'ed.
		    # FIXME: do 500 vs. 404 vs whatever based on $!
		    return $self->close();
		}

		$self->tcp_cork(1);  # cork writes to self
		$self->write($res->to_string_ref);
		$self->reproxy_fd($rp_fd, $size);
		$self->watch_write(1);
	    });

	} elsif (-d _) {
	    my $body;

	    if ($svc->{dirindexing}) {
		$res->header("Content-Type", "text/html");
		opendir(D, $file);
		foreach my $de (sort readdir(D)) {
		    if (-d "$file/$de") {
			$body .= "<b><a href='$de/'>$de</a></b><br />\n";
		    } else {
			$body .= "<a href='$de'>$de</a><br />\n";
		    }
		}
		closedir(D);
	    } else {
		$res->header("Content-Type", "text/html");
		$body = "Directory listing disabled";
	    }

	    $res->header("Content-Length", length($body));

	    $self->tcp_cork(1);  # cork writes to self
	    $self->write($res->to_string_ref);
	    $self->write(\$body);
	    $self->write(sub { $self->close; });
	}
    });

    $self->watch_read(0);
}

sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

sub _durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

1;
