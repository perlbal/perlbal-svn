######################################################################
# HTTP Connection from a reverse proxy client.  GET/HEAD only.
#  most functionality is implemented in the base class.
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.
#

package Perlbal::ClientHTTP;
use strict;
use warnings;
no  warnings qw(deprecated);

use base "Perlbal::ClientHTTPBase";

use fields ('put_in_progress', # 1 when we're currently waiting for an async job to return
            'put_fh',          # file handle to use for writing data
            'put_pos',         # file offset to write next data at

            'content_length',  # length of document being transferred
            'content_length_remain', # bytes remaining to be read
            );

use HTTP::Date ();
use File::Path;

use Errno qw( EPIPE );
use POSIX qw( O_CREAT O_TRUNC O_WRONLY O_RDONLY ENOENT );

# class list of directories we know exist
our (%VerifiedDirs);

sub new {
    my $class = shift;

    my $self = fields::new($class);
    $self->SUPER::new(@_);
    $self->init;
    return $self;
}

# upcasting a generic ClientHTTPBase (from a service selector) to a
# "full-fledged" ClientHTTP.
sub new_from_base {
    my $class = shift;
    my Perlbal::ClientHTTPBase $cb = shift;
    bless $cb, $class;
    $cb->init;
    $cb->handle_request;
    return $cb;
}

sub init {
    my Perlbal::ClientHTTP $self = shift;
    $self->{put_in_progress} = 0;
    $self->{put_fh} = undef;
    $self->{put_pos} = 0;
}

sub close {
    my Perlbal::ClientHTTP $self = shift;

    # don't close twice
    return if $self->{closed};

    $self->{put_fh} = undef;
    $self->SUPER::close(@_);
}

sub event_read {
    my Perlbal::ClientHTTP $self = shift;

    # see if we have headers?
    if ($self->{req_headers}) {
        if ($self->{req_headers}->request_method eq 'PUT') {
            $self->event_read_put;
        } else {
            # since we have headers and we're not doing any special
            # handling above, let's just disable read notification, because
            # we won't do anything with the data
            $self->watch_read(0);
        }
        return;
    }

    # try and get the headers, if they're all here
    my $hd = $self->read_request_headers
        or return;

    $self->handle_request;
}

# one-time routing of new request to the right handlers
sub handle_request {
    my Perlbal::ClientHTTP $self = shift;
    my $hd = $self->{req_headers};

    # fully formed request received
    $self->{requests}++;

    # notify that we're about to serve
    return if $self->{service}->run_hook('start_web_request',  $self);
    return if $self->{service}->run_hook('start_http_request', $self);

    # GET/HEAD requests (local, from disk)
    if ($hd->request_method eq 'GET' || $hd->request_method eq 'HEAD') {
        # and once we have it, start serving
        $self->watch_read(0);
        return $self->_serve_request($hd);
    }

    # PUT requests
    return $self->handle_put    if $hd->request_method eq 'PUT';

    # DELETE requests
    return $self->handle_delete if $hd->request_method eq 'DELETE';

    # else, bad request
    return $self->send_response(400);
}

sub handle_put {
    my Perlbal::ClientHTTP $self = shift;
    my $hd = $self->{req_headers};

    return $self->send_response(403) unless $self->{service}->{enable_put};

    # they want to put something, so let's setup and wait for more reads
    my $clen = $hd->header('Content-length') + 0;

    # return a 400 (bad request) if we got no content length or if it's
    # bigger than any specified max put size
    return $self->send_response(400, "Content-length of $clen is invalid.")
        if !$clen ||
        ($self->{service}->{max_put_size} &&
         $clen > $self->{service}->{max_put_size});

    # if we have some data already from a header over-read, handle it by
    # flattening it down to a single string as opposed to an array of stuff
    if (defined $self->{read_size} && $self->{read_size} > 0) {
        my $data = '';
        foreach my $rdata (@{$self->{read_buf}}) {
            $data .= ref $rdata ? $$rdata : $rdata;
        }
        $self->{read_buf} = $data;
        $self->{content_length} = $clen;
        $self->{content_length_remain} = $clen - $self->{read_size};
    } else {
        # setup to read the file
        $self->{read_buf} = '';
        $self->{content_length} = $self->{content_length_remain} = $clen;
    }

    # setup the directory asynchronously
    return if $self->{put_fh};

    # error in filename?  (any .. is an error)
    my $uri = $self->{req_headers}->request_uri;
    return $self->send_response(400, 'Invalid filename')
        if $uri =~ /\.\./;

    # now we want to get the URI
    if ($uri =~ m!^((?:/[\w\-\.]+)*)/([\w\-\.]+)$!) {
        # sanitize uri into path and file into a disk path and filename
        my ($path, $filename) = ($1 || '', $2);

        # verify minput if necessary
        if ($self->{service}->{min_put_directory}) {
            my @elems = grep { defined $_ && length $_ } split '/', $path;
            return $self->send_response(400, 'Does not meet minimum directory requirement')
                unless scalar(@elems) >= $self->{service}->{min_put_directory};
            my $minput = '/' . join('/', splice(@elems, 0, $self->{service}->{min_put_directory}));
            my $path = '/' . join('/', @elems);
            return unless $self->verify_put($minput, $path, $filename);
        }

        # now we want to open this directory
        my $lpath = $self->{service}->{docroot} . '/' . $path;
        return $self->attempt_open($lpath, $filename);
    } else {
        # bad URI, don't accept the put
        return $self->send_response(400, 'Invalid filename');
    }

    return;
}

# called when we're requested to do a delete
sub handle_delete {
    my Perlbal::ClientHTTP $self = shift;

    return $self->send_response(403) unless $self->{service}->{enable_delete};

    $self->watch_read(0);

    # error in filename?  (any .. is an error)
    my $uri = $self->{req_headers}->request_uri;
    return $self->send_response(400, 'Invalid filename')
        if $uri =~ /\.\./;

    # now we want to get the URI
    if ($uri =~ m!^(?:/[\w\-\.]+)+$!) {
        # now attempt the unlink
        Perlbal::AIO::aio_unlink($self->{service}->{docroot} . '/' . $uri, sub {
            my $err = shift;
            if ($err == 0 && !$!) {
                # delete was successful
                return $self->send_response(204);
            } elsif ($! == ENOENT) {
                # no such file
                return $self->send_response(404);
            } else {
                # failure...
                return $self->send_response(400, "$!");
            }
        });
    } else {
        # bad URI, don't accept the delete
        return $self->send_response(400, 'Invalid filename');
    }
}

sub event_read_put {
    my Perlbal::ClientHTTP $self = shift;

    # read in data and shove it on the read buffer
    my $dataref = $self->read($self->{content_length_remain});

    # unless they disconnected prematurely
    unless (defined $dataref) {
        $self->close('remote_closure');
        return;
    }

    # got some data
    $self->{read_buf} .= $$dataref;
    my $clen = length($$dataref);
    $self->{read_size} += $clen;
    $self->{content_length_remain} -= $clen;

    # handle put if we should
    $self->put_writeout if $self->{read_size} >= 8192; # arbitrary

    # now, if we've filled the content of this put, we're done
    unless ($self->{content_length_remain}) {
        $self->watch_read(0);
        $self->put_writeout;
    }
}

# verify that a minimum put directory exists
# return value: 1 means the directory is okay, continue
#               0 means we must verify the directory, stop processing
sub verify_put {
    my Perlbal::ClientHTTP $self = shift;
    my ($minput, $extrapath, $filename) = @_;

    my $mindir = $self->{service}->{docroot} . '/' . $minput;
    return 1 if $VerifiedDirs{$mindir};
    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_open($mindir, O_RDONLY, 0755, sub {
        my $fh = shift;
        $self->{put_in_progress} = 0;

        # if error return failure
        return $self->send_response(404, "Base directory does not exist") unless $fh;
        CORE::close($fh);

        # mindir existed, mark it as so and start the open for the rest of the path
        $VerifiedDirs{$mindir} = 1;
        return $self->attempt_open($mindir . $extrapath, $filename);
    });
    return 0;
}

# attempt to open a file
sub attempt_open {
    my Perlbal::ClientHTTP $self = shift;
    my ($path, $file) = @_;

    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_open("$path/$file", O_CREAT | O_TRUNC | O_WRONLY, 0644, sub {
        # get the fd
        my $fh = shift;

        # verify file was opened
        $self->{put_in_progress} = 0;

        if (! $fh) {
            if ($! == ENOENT) {
                # directory doesn't exist, so let's manually create it
                eval { File::Path::mkpath($path, 0, 0755); };
                return $self->system_error("Unable to create directory", "path = $path, file = $file") if $@;

                # should be created, call self recursively to try
                return $self->attempt_open($path, $file);
            } else {
                return $self->system_error("Internal error", "error = $!, path = $path, file = $file");
            }
        }

        $self->{put_fh} = $fh;
        $self->{put_pos} = 0;
        $self->put_writeout;
    });
}

# called when we've got some put data to write out
sub put_writeout {
    my Perlbal::ClientHTTP $self = shift;

    return if $self->{service}->run_hook('put_writeout', $self);
    return if $self->{put_in_progress};
    return unless $self->{put_fh};
    return unless $self->{read_size};

    # dig out data to write
    my ($data, $count) = ($self->{read_buf}, $self->{read_size});
    ($self->{read_buf}, $self->{read_size}) = ('', 0);

    # okay, file is open, write some data
    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_write($self->{put_fh}, $self->{put_pos}, $count, $data, sub {
        return if $self->{closed};

        # see how many bytes written
        my $bytes = shift() + 0;

        $self->{put_pos} += $bytes;
        $self->{put_in_progress} = 0;

        # now recursively call ourselves?
        if ($self->{read_size}) {
            $self->put_writeout;
            return;
        }

        return if $self->{content_length_remain};

        # we're done putting this file, so close it.
        # FIXME this should be done through AIO
        if ($self->{put_fh} && CORE::close($self->{put_fh})) {
            $self->{put_fh} = undef;
            return $self->send_response(200);
        } else {
            return $self->system_error("Error saving file", "error in close: $!");
        }
    });
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
