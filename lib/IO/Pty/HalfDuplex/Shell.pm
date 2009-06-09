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
I<command> as its only child, and sends its pid in 4 bytes on I<info_pipe>.

Each time an 's' is received on I<ctl_pipe>, the child process is allowed
to continue; a 'r' will be transmitted on I<info_pipe> if the process blocks
on input, or a 'd' followed by signal and exit status (as bytes) if the
process dies.

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
use POSIX qw(:signal_h :sys_wait_h :termios_h :unistd_h);
my $need_bsd_hack = ($^O =~ /bsd|darwin/i);

# }}}
# do_wait {{{
# Properly wait for the child; does not return (and emits d-code) on exit
sub do_wait {
    my $self = shift;

    waitpid($self->{slave_pid}, WUNTRACED) == $self->{slave_pid}
        or die "waitpid: $!";

    # Older Perls (<= 5.8.8) put all status codes into $?.  Newer ones
    # will only put exits there, and signals go elsewhere.  Argh.
    my $stat = ${^CHILD_ERROR_NATIVE} || $?;

    if (WIFEXITED($stat) || WIFSIGNALED($stat)) {
        syswrite $self->{info_pipe}, "d" .
            chr(WIFSIGNALED($stat) ? WTERMSIG($stat) : 0) .
            chr(WIFEXITED($stat) ? WEXITSTATUS($stat) : 0);
        
        # We got here by a fork, so we certainly have stale buffers
        _exit 0;
    }

    die "POSIX.1 says this can't happen" if !WIFSTOPPED($stat);
}
# }}}
# try_step {{{
# Try once to get the slave to process input.  Returns true if successful.
# The slave _will_ be stopped(TTIN) on entry to this function.
sub try_step {
    my ($self, $lag) = @_;

    # Put the process into the foreground so it can read input
    tcsetpgrp(0, $self->{slave_pid});
    kill -(SIGCONT), $self->{slave_pid};

    # Force a context switch
    select undef, undef, undef, $lag;

    # Stop it so it can be put in the background
    kill -(SIGSTOP), $self->{slave_pid};
    $self->do_wait;

    # Now put it there
    tcsetpgrp(0, $self->{pid});
    kill -(SIGCONT), $self->{slave_pid};

    # If the process was not in the tty driver, it's now on its way to
    # stopping.  If it was, and you're on Linux, it will transition to T
    # automatically.  On BSDs it needs a bit of an extra kick, because
    # even tcsetpgrp, sigstop, and sigcont won't interrupt a tty wait.
    #
    # Insidiously, this doesn't manifest in the shell because typing "bg"
    # kicks all processes waiting on the tty wchan.
    #
    # This is the best non-destructive way I could find.  Requires three
    # system calls, grr.
    if ($need_bsd_hack) {
        my $attr = POSIX::Termios->new;
        $attr->getattr(0);
        $attr->setcc(&POSIX::VMIN, $attr->getcc(&POSIX::VMIN) + 1);
        $attr->setattr(0, &POSIX::TCSANOW);
        $attr->setcc(&POSIX::VMIN, $attr->getcc(&POSIX::VMIN) - 1);
        $attr->setattr(0, &POSIX::TCSANOW);
    }
    
    # Wait until it blocks on input
    $self->do_wait;

    # Slave has stopped on tty input.  Hopefully, it's read and processed
    # everything and we can send the over; but it could also just have taken a
    # long time to read and outwaited out feeding sleep.
    #
    # We can tell the difference by seeing if there is readable data.  Note
    # that in ICANON mode, it is possible for there to be unreadable data.
    # That's OK, since it's equally unreadable to both of us.
    my $rin = '';
    vec($rin, 0, 1) = 1;
    return select($rin, undef, undef, 0) ? 0 : 1;
}
# }}}
# control loop and startup {{{
# Wait for, and process, commands
sub loop {
    my $self = shift;

    while(1) {
        my $buf = '';
        sysread($self->{ctl_pipe}, $buf, 1) > 0 or die "read(ctl): $!";

        # BSD adds a 0.5 second delay to every time a process reads while
        # in the background.  This is a real problem for us, so minimize
        # needed read attempts.
        for (my $lag = ($need_bsd_hack ? 0.15 : 0.02);
             !$self->try_step($lag); $lag *= 1.5) {}
        syswrite($self->{info_pipe}, "r");
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
        # Make sure the important job control signals aren't ignored
        $SIG{CHLD} = $SIG{TTIN} = $SIG{TSTP} = $SIG{CONT} = 'DEFAULT';
        kill SIGSTOP, $self->{slave_pid};

        exec(@{$self->{command}});
        die "exec: $!";
    }

    syswrite($self->{info_pipe}, pack('N', $self->{slave_pid}));

    setpgrp($self->{slave_pid}, $self->{slave_pid});

    # It simplifies the API if the child can be assumed to start stopped
    $self->do_wait;
}

sub new {
    my $class = shift;
    my $self = bless {
        pid => $$,
        @_
    }, $class;

    # disable tostop, also allows tcsetpgrp stealing
    $SIG{TTOU} = 'IGNORE';

    $self->spawn();
    $self->loop();
}
1;
# }}}
