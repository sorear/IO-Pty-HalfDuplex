#!/usr/bin/env perl
package IO::Pty::HalfDuplex;
use strict;
use warnings;
use POSIX qw(:unistd_h :sys_wait_h :signal_h);
use IO::Pty::Easy;

our @ISA = ('IO::Pty::Easy');
our $VERSION = '0.01';

sub new {
    my $self = IO::Pty::HalfDuplex->SUPER::new();

    $self->{from} = $self->{to} = $self->{just_started} = undef;
    return $self;
}

# Differences from the superclass spawn:
#
# - An extra pair of pipes are passed in.
# - Failure to sync (EBADF, EFAULT; always code error) doesn't
#   kill the child (How would we know which one?)
# - Obtains PID from child

sub spawn {
    my $self = shift;
    my $slave = $self->{pty}->slave;

    croak "Attempt to spawn a subprocess when one is already running"
        if $self->is_active;

    # set up a pipe to use for keeping track of the child process during exec
    pipe my ($readp, $writep) || croak "Failed to create a pipe";
    pipe my ($fromr, $fromw) || croak "Failed to create a pipe";
    pipe my ($tor, $tow) || croak "Failed to create a pipe";

    # fork a child process
    # if the exec fails, signal the parent by sending the errno across the pipe
    # if the exec succeeds, perl will close the pipe, and the sysread will
    # return due to EOF
    sub sigchld { wait; $SIG{CHLD} = \&sigchld; }
    $SIG{CHLD} = \&sigchld;
    my $cpid = fork;
    unless ($cpid) {
        close $readp, $fromr, $tow;
        $self->{pty}->make_slave_controlling_terminal;
        close $self->{pty};
        $slave->clone_winsize_from(\*STDIN) if $self->{handle_pty_size};
        $slave->set_raw;
        # reopen the standard file descriptors in the child to point to the
        # pty rather than wherever they have been pointing during the script's
        # execution
        open(STDIN,  "<&" . $slave->fileno)
            or carp "Couldn't reopen STDIN for reading";
        open(STDOUT, ">&" . $slave->fileno)
            or carp "Couldn't reopen STDOUT for writing";
        open(STDERR, ">&" . $slave->fileno)
            or carp "Couldn't reopen STDERR for writing";
        close $slave;

        _slave $writep, $tor, $fromw, @_;
    }

    close $writep, $tor, $fromw;
    $self->{pty}->close_slave;
    $self->{pty}->set_raw;
    # this sysread will block until either we get an EOF from the other end of
    # the pipe being closed due to the exec, or until the child process sends
    # us the errno of the exec call after it fails
    my $errno, $rcpid;
    my $syncd = defined (sysread($readp, $rcpid, 4)) &&
                defined (sysread($readp, $errno, 4));

    $self->{pid} = unpack "l", $rcpid;
    $errno = unpack "l", ($errno || "\0\0\0\0");

    unless ($syncd) {
        croak "Cannot sync with child: $!";
    }
    close $readp;
    if ($errno) {
        $self->_wait_for_inactive;
        $! = $errno + 0;
        croak "Cannot exec(@_): $!";
    }

    my $winch;
    $winch = sub {
        $self->{pty}->slave->clone_winsize_from(\*STDIN);
        kill WINCH => $self->{pid} if $self->is_active;
        $SIG{WINCH} = $winch;
    };
    $SIG{WINCH} = $winch if $self->{handle_pty_size};

    $self->{to} = $tow;
    $self->{from} = $fromr;
    $self->{just_started} = 1;
}

sub _slave {
    my ($statpipe, $inpipe, $outpipe, @args) = @_;

    $SIG{'CHLD'} = sub { };
    $SIG{'TTOU'} = $SIG{'TTIN'} = $SIG{'TSTP'} = 'IGNORE';

    setpgrp $$, $$;

    POSIX::tcsetpgrp(0, $$)
        or die "cannot tcsetpgrp: $!\n";

    my $cpid;

    if (!defined ($cpid = fork)) {
        die "Cannot fork: $!\n";
    }

    syswrite $statpipe, pack('l', $cpid);

    if (!$cpid) {
        # Child

        $SIG{'CHLD'} = $SIG{'TTOU'} = $SIG{'TTIN'} = $SIG{'TSTP'} = 'DEFAULT';

        setpgrp;

        exec @args;
        syswrite $statpipe, pack('l', $!);
    }

    close $statpipe;

    while (1) {
        # Wait until the slave blocks (or dies) {{{

        my $stat;
        do {
            waitpid($cpid, WUNTRACED) || die "wait failed: $!\n";
            $stat = ${^CHILD_ERROR_NATIVE};
        } while (WIFSTOPPED($stat) && WSTOPSIG($stat) != SIGTTIN
            && WSTOPSIG($stat) != SIGTTOU);

        if (!WIFSTOPPED($stat)) {
            # Oh, it's dead.

            syswrite $outfh, "\0";
            exit WEXITSTATUS($stat);
        }

        # }}}
        # Slave is blocked.  Is there any unread input? {{{
        my $more;
        {
            my $ivec = "\1";

            ($more = select $ivec, undef, undef, 0) >= 0 or
                die "select failed: $!\n";
        }

        # }}}
        # None?  OK, tell our user and get the next block of input {{{

        if (!$more && WSTOPSIG($stat) == SIGTTIN) {
            my $null;
            syswrite $outfh, "\0";
            sysread $infh, $null, 1;
        }

        # }}}
        # Step the slave {{{

        POSIX::tcsetpgrp 0, $cpid;
        kill SIGCONT, $cpid;

        # Yuk.  We need the slave to actually be scheduled and read data...
        select undef, undef, undef, 0.005;

        kill SIGSTOP, $cpid;
        POSIX::tcsetpgrp 0, $$;
        kill SIGCONT, $cpid;

        # }}}
    }
}

sub read {
    my $self = shift;

    return undef unless $self->is_active;

    if ($self->{just_started}) {
        $self->{just_started} = 0;
    } else {
        syswrite $self->{to}, "\0";
    }

    my $buf = '';

    while (1) { 
        my $vin = '';
        vec($vin, fileno($self->{from}), 1) = 1;
        vec($vin, fileno($self->{pty}), 1) = 1;

        select($vin, undef, undef, undef) >= 0 or
            croak "select failed: $!";

        if (vec($vin, fileno($self->{pty}), 1)) {
            sysread $self->{pty}, $buf, 8192, length $buf;
        } else {
            # select returned, but no output.  Must be the end-of-output flag
            my $null;
            my $more = sysread $self->{from}, $null, 1;

            croak "sysread on pipe failed: $!" if $more < 0;

            if ($more == 0) {
                # EOF - the slave must be dead.  Mark that now.
                $self->{from} = $self->{to} = $self->{pid} = undef;
            }

            last;
        }
    }

    return $buf;
}

sub write {
    my ($self, $text) = @_;

    if (! $self->is_active) {
        carp "Writing to dead slave";
        return;
    }

    syswrite $self->{pty}, $text;
}

sub is_active {
    my $self = shift;

    return defined $self->{pid};
}

sub _wait_for_inactive {
    my $self = shift;

    $self->read while $self->is_active;
}

=head1 NAME

ristub - the remote interactive stub

=head1 SYNOPSIS

ristub INFD OUTFD CMD [ARGS...]

=head1 DESCRIPTION

C<ristub> is a program designed to perform impedence matching between driving
programs which expect commands and responses, and driven programs which
use a terminal in full-duplex mode.  In this vein it is somewhat like
I<expect>, but less general and more robust.

C<ristub> is not suitible for interactive use.  To use C<ristub>, you need to
create two pipes and pass file descriptors as the first and second arguments.
When the child program is finished sending data, a single 0 byte will be sent
to the pipe OUTFD.  When you are finished sending input, you should send a
single byte on the pipe INFD.

=head1 CAVEATS

C<ristub> is implemented using POSIX job control, and as such it requires
foreground access to a controlling terminal.  Programs which interfere with
process hierarchies, such as B<strace -f>, will break C<ristub>.

Certain ioctls used by terminal-aware programs are treated as reads by POSIX
job control.  If this is done while the input buffer is empty, it may cause
a spurious stop by C<ristub>.  Under normal circumstances this manifests as
a need to transmit at least one character before the starting screen is
displayed.

Most of the design and implementation of C<ristub> was executed between
midnight and 2:00 AM.  You have been warned.

=cut


1;

__END__

=head1 NAME

IO::HalfDuplex - ??

=head1 SYNOPSIS

    use IO::HalfDuplex;

=head1 DESCRIPTION



=head1 AUTHOR

Stefan O'Rear, C<< <stefanor@cox.net> >>

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-io-halfduplex at rt.cpan.org>, or browse
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=IO-HalfDuplex>.

=head1 COPYRIGHT AND LICENSE

Copyright 2008 Stefan O'Rear.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

