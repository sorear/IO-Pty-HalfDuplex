#!/usr/bin/env perl
# vim: fdm=marker sw=4 et
# Documentation head {{{

=head1 NAME

IO::Pty::HalfDuplex::Shell - Internal module used by IO::Pty::HalfDuplex

=head1 SYNOPSIS

    IO::Pty::HalfDuplex::Shell->new(ctl_pipe => $r1, info_pipe => $r2,
        command => [@_]);

=head1 DESCRIPTION

This module implements the fake shell used by L<IO::Pty::HalfDuplex>, and is
not intended to be used directly.  The new function runs the shell with
I<command> as its only child; the following commands are accepted on the
I<ctl_pipe>:

=over

=item C<+> Runs the slave in the foreground.

=item C<-> Runs the slave in the background.

=item C<w> Waits for the slave.

C<w> accepts a single argument, a native-format double (C<"d"> pack format),
which is a timeout time.  It replies with C<r>, if the slave has blocked on
STDIN (and is thus done writing), C<d> if the slave has died (followed by
the death signal and exit code as bytes), or C<t> if the timeout was reached.

=back

=BUGS

See L<IO::Pty::HalfDuplex>.

=head1 COPYRIGHT AND LICENSE

Copyright 2008-2009 Stefan O'Rear.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# }}}
# header {{{
# This code pretends to be a shell to the operating system, and as such needs
# to run in a separate process, inside the pty.  The stub code doesn't have
# to manipulate the pty at all, luckily.

# XXX Running this in a forked process holds all cloexec file descriptors open.

package IO::Pty::HalfDuplex::Shell;

use strict;
use warnings;
use POSIX qw(:signal_h :sys_wait_h);
use Time::HiRes qw(time alarm);

# }}}
# wait {{{
# Handle something interesting happening to the slave.
sub handle_wait {
    my $self = shift;

    my $timeout;
    sysread($self->{ctl_pipe}, $timeout, length(pack "d", 0));
    $timeout = unpack "d", $timeout;

again:
    # If protocol is followed, when we get to wait the process is in
    # ACTIVE state and cannot stop more than once
    eval {
        $SIG{ALRM} = sub {die "alarm\n"};
        my $t = $timeout - time;
        die "alarm\n" if $t < 0;

        alarm($timeout - time);

        waitpid($self->{slave_pid}, WUNTRACED) or die "waitpid: $!";

        alarm(0);
        $SIG{ALRM} = 'IGNORE';
    };

    if ($@) {
        die $@ if ($@ ne "alarm\n");
        syswrite($self->{info_pipe}, "t");
        return;
    }

    # Older Perls (<= 5.8.8) put all status codes into $?.  Newer ones
    # will only put exits there, and signals go elsewhere.  Argh.
    my $stat = ${^CHILD_ERROR_NATIVE} || $?;

    if (WIFSTOPPED($stat) && WSTOPSIG($stat) == SIGTTIN) {
        # Slave has stopped on tty input.  Hopefully, it's read and
        # processed everything and we can send the over; but it could
        # also just have taken a long time to read and outwaited out
        # feeding sleep.
        #
        # We can tell the difference by seeing if there is readable data.
        # Note that in ICANON mode, it is possible for there to be
        # unreadable data.  That's OK, since it's equally unreadable to
        # both of us.
        my $rin = '';
        vec($rin, 0, 1) = 1;
        if (select($rin, undef, undef, 0)) {
            # Oh, well.  Bump the wait time and try again.
            $self->{wait_time} *= 1.5;
            $self->handle_start();
            $self->handle_end();
            goto again;
        } else {
            # There's no readable data, so the slave must be blocking
            # for actual input (unless it used a blocking input ioctl,
            # which is a really ugly special case).
            $self->{wait_time} = 0.01;
            syswrite($self->{data_pipe}, "r", 1);
        }
    } elsif (WIFSTOPPED($stat)) {
        # Stopped, but not tty input.  Probably a user intervention;
        # ignore and wait until they restart it (and something else happens).
        #
        # Possible future direction: note this fact, so we don't attempt to
        # restart in _cont.
        goto again;
    } elsif (WIFSIGNALED($stat) || WIFEXITED($stat)) {
        # Oops.  Slave died.
        syswrite($self->{data_pipe}, "d" .
            chr(WIFSIGNALED($stat) ? WTERMSIG($stat) : 0) .
            chr(WIFSIGNALED($stat) ? 0 : WEXITSTATUS($stat)), 3);
        exit;
    } else {
        # Wait, _what_ happened?
        goto again;
    }
}
# }}}
# stops and starts {{{
# Set terminal bits to enable or disable terminal access to the slave
sub grab_tty {
    my $self = shift;
    tcsetpgrp(0, shift() ? $self->{pid} : $self->{slave_pid})
        or die "tcsetpgrp: $!";
}

# We've just been asked to let the slave continue for a bit.  This will only
# be called (barring protocol errors) with the tty grabbed and the child
# stopped; it could either be the result of SIGUSR1, or the child stopped
# with input in the buffer.
sub handle_start {
    my $self = shift;

    # Allow the slave to read data
    $self->grab_tty(0);
    kill(-$self->{slave_pid}, SIGCONT);
}

sub handle_stop {
    my $self = shift;
    # Force a context switch, allow some time
    select undef, undef, undef, $self->{wait_time};

    # Force the slave into the background; it should get a SIGTTIN if and when
    # it is reading
    kill(-$self->{slave_pid}, SIGSTOP);
    $self->grab_tty(1);
    kill(-$self->{slave_pid}, SIGCONT);
}
# }}}
# control loop and startup {{{
# Wait for, and process, commands
sub loop {
    my $self = shift;

    while(1) {
        my $buf = '';
        sysread($self->{ctl_pipe}, $buf, 1) > 0 or die "read(ctl): $!";

        $self->handle_wait() if $buf eq 'w';
        $self->handle_start() if $buf eq '+';
        $self->handle_stop() if $buf eq '-';
    }
}

# This routine is responsible for creating the proper environment for the
# slave to run in.
sub spawn {
    my $self = shift;

    die "fork: $!" unless defined ($self->{slave_pid} = fork);

    unless($self->{slave_pid}) {
        # The child process to be.  Force it to start as a process leader
        # in the background.
        $self->{slave_pid} = $$;
        setpgrp($self->{slave_pid}, $self->{slave_pid});
        tcsetpgrp(0, $self->{pid});

        exec(@{$self->{command}});
        die "exec: $!";
    }

    syswrite($self->{data_pipe}, pack('N', $self->{slave_pid}));

    setpgrp($self->{slave_pid}, $self->{slave_pid});
    tcsetpgrp(0, $self->{pid});
}

sub new {
    my $class = shift;
    my $self = bless $class, {
        pid => $$,
        wait_time => 0.01,
        @_
    };

    $self->setup_signals();
    $self->spawn();
    $self->loop();
}
1;
# }}}
