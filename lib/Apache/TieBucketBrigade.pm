package Apache::TieBucketBrigade;

use 5.006001;

use strict;
use warnings;

use Apache::Connection ();
use APR::Bucket ();
use APR::Brigade ();
use APR::Util ();
use APR::Const -compile => qw(SUCCESS EOF);
use Apache::Const -compile => qw(OK MODE_GETLINE);
use IO::WrapTie;

our @ISA = qw(IO::WrapTie::Slave);

our $VERSION = '0.02';

sub TIEHANDLE {
    my $invocant = shift;
    my $connection = shift;
    my $class = ref($invocant) || $invocant;
    my $self = {                            
        @_,
    };
    bless $self, $class;
    $self->{bbin} = APR::Brigade->new($connection->pool,
                                      $connection->bucket_alloc);
    $self->{bbout} = APR::Brigade->new($connection->pool,
                                       $connection->bucket_alloc);
    $self->{connection} = $connection;
    return $self;
}

sub PRINT {
    my $self = shift;
    my $bucket;
    foreach my $line (@_) {
        $bucket = APR::Bucket->new($line);
        $self->{bbout}->insert_tail($bucket);
    }
    my $bkt = APR::Bucket::flush_create($self->{connection}->bucket_alloc);
    $self->{bbout}->insert_tail($bkt);
    $self->{connection}->output_filters->pass_brigade($self->{bbout});
}

sub WRITE {
    my $self = shift;
    my ($buf, $len, $offset) = @_;
    return undef unless $self->PRINT(substr($buf, $offset, $len));
    return length substr($buf, $offset, $len);
}

sub PRINTF {
    my $self = shift;
    my $fmt = shift;
    $self->PRINT(sprintf($fmt, @_));
}

sub READLINE {
    my $self = shift;
    my $out;
    my $last = 0;
    while (1) {
        my $rv = $self->{connection}->input_filters->get_brigade(
            $self->{bbin}, Apache::MODE_GETLINE);
        if ($rv != APR::SUCCESS && $rv != APR::EOF) {
            my $error = APR::strerror($rv);
            warn __PACKAGE__ . ": get_brigade: $error\n";
            last;
        }
        last if $self->{bbin}->empty;
        while (!$self->{bbin}->empty) {
            my $bucket = $self->{bbin}->first;
            $bucket->remove;
            last if ($bucket->is_eos);
            my $data;
            my $status = $bucket->read($data);
            $out .= $data;
            last unless $status == APR::SUCCESS;
            if (defined $data) {
                $last++ if $data =~ /[\r\n]+$/;
                last if $last;
            }
        }
        last if $last;
    }
    $self->{bbin}->destroy;
    return undef unless defined $out;
    return undef if $out =~ /^[\r\n]+$/;
    return $out if $out =~ /[\r\n]+$/;
    return $out;
}

sub GETC {
    my $self = shift;
    my $char;
    $self->READ($char, 1, 0);
    return undef unless $char;
    return $char;
}

sub READ {
#this buffers however man unused bytes are read from the bucket
#brigade into $self->{'_buffer'}.  Repeated calls should retreive anything
#left in the buffer before more stuff is received
    my $self = shift;
    my $bufref = \$_[0];
    my (undef, $len, $offset) = @_;
    my $out = $self->{'_buffer'} if defined $self->{buffer};
    my $last = 0;
    while (1) {
        my $rv = $self->{connection}->input_filters->get_brigade(
            $self->{bbin}, Apache::MODE_GETLINE);
        if ($rv != APR::SUCCESS && $rv != APR::EOF) {
            my $error = APR::strerror($rv);
            warn __PACKAGE__ . ": get_brigade: $error\n";
            last;
        }
        last if $self->{bbin}->empty;
        while (!$self->{bbin}->empty) {
            my $bucket = $self->{bbin}->first;
            $bucket->remove;
            $last++ and last if ($bucket->is_eos);
            my $data;
            my $status = $bucket->read($data);
            $out .= $data;
            $last++ and last unless $status == APR::SUCCESS;
            $last++ and last unless defined $data;
            if (defined $out) {
                $last++ if length $out >= $len;
                last if $last;
            }
        }
        last if $last;
    }
    $self->{bbin}->destroy;
    if (length $out > $len) {
        $self->{'_buffer'} = substr $out, $len + $offset;
        $out = substr $out, $offset, $len;
    }
    $$bufref .= $out;
    return length $out
}

sub CLOSE {
    my $self = shift;
    $self->{socket}->close;
}

sub OPEN {
   return shift;
}

sub FILENO {
#pretends to be STDIN so that IO::Select will work
    shift;
    return 0;
}

1;

package IO::WrapTie::Master;

sub autoflush {
    shift;
    return !$_[0];
}

sub blocking {
#why of course I'm non blocking
   shift;
   return !$_[0];
}


1;
__END__

=head1 NAME

Apache::TieBucketBrigade - Perl extension which ties an IO::Handle to Apache's
Bucket Brigade so you can use standard filehandle type operations on the 
brigade.

=head1 SYNOPSIS

  use Apache::Connection ();
  use Apache::Const -compile => 'OK';
  use Apache::TieBucketBrigade;
  
  sub handler { 
      my $FH = Apache::TieBucketBrigade->new_tie($c);
      my @stuff = <$FH>;
      print $FH "stuff goes out too";
      $FH->print("it's and IO::Handle too!!!");
      Apache::OK;
  }

=head1 DESCRIPTION

This module has one usefull method "new_tie" which takes an Apache connection
object and returns a tied IO::Handle object.  It should be used inside a 
mod_perl protocol handler to make dealing with the bucket brigade bitz 
easier.  For reasons of my own, FILENO will pretend to be STDIN so you may
need to keep this in mind.  Also IO::Handle::autoflush and IO::Handle::blocking
are essentially noops.

=head2 EXPORT

None


=head1 SEE ALSO

IO::Stringy
mod_perl
IO::Handle

=head1 AUTHOR

mock E<lt>mock@obscurity.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004 by Will Whittaker and Ken Simpson

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.2 or,
at your option, any later version of Perl 5 you may have available.


=cut
